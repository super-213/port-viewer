import Darwin
import Foundation

extension ProcessMetadataResolver {
    static func identity(for pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(pid: pid, userID: info.pbi_uid,
                               startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    static func context(for identity: ProcessIdentity, processName: String) -> ProcessContext {
        var context = ProcessContext(identity: identity)
        // Other users' command lines and project files are not needed for display.
        guard identity.userID == getuid() else { return context }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(identity.pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size {
            context.workingDirectory = withUnsafeBytes(of: info.pvi_cdir.vip_path) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        let arguments = arguments(for: identity.pid)
        context.arguments = redacted(arguments)
        let project = ProjectResolver.resolve(workingDirectory: context.workingDirectory)
        context.projectRoot = project?.root
        context.projectName = project?.name
        context.framework = ProjectResolver.framework(arguments: arguments, processName: processName)
        return context
    }

    static func arguments(for pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > 4, size <= 1_048_576 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        return parseArguments(Data(buffer.prefix(size)))
    }

    static func parseArguments(_ data: Data) -> [String] {
        guard data.count > MemoryLayout<Int32>.size else { return [] }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return [] }
        let bytes = [UInt8](data)
        var cursor = MemoryLayout<Int32>.size
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 } // executable
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 } // padding
        var result: [String] = []
        for _ in 0..<argc {
            guard cursor < bytes.count else { return [] }
            let start = cursor
            while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
            guard cursor < bytes.count else { return [] }
            result.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
            cursor += 1
        }
        return result // Never read the following environment block.
    }

    static func redacted(_ arguments: [String]) -> [String] {
        var hideNext = false
        return arguments.map { argument in
            if hideNext { hideNext = false; return "••••" }
            let lower = argument.lowercased()
            let sensitive = ["password", "passwd", "token", "secret", "api-key", "api_key", "authorization"]
            if sensitive.contains(where: lower.contains) {
                if let separator = argument.firstIndex(of: "=") {
                    return String(argument[...separator]) + "••••"
                }
                hideNext = true
                return argument.hasPrefix("-") ? argument : "••••"
            }
            return argument
        }
    }
}

enum ProjectResolver {
    struct Project: Equatable { let root: String; let name: String }

    static func resolve(workingDirectory: String?) -> Project? {
        guard let workingDirectory, workingDirectory.hasPrefix("/"), workingDirectory != "/" else { return nil }
        var directory = URL(fileURLWithPath: workingDirectory).standardizedFileURL
        for _ in 0..<16 {
            let markers = ["package.json", "Cargo.toml", "pyproject.toml", "go.mod", "Package.swift", ".git"]
            if markers.contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                var name = directory.lastPathComponent
                let manifest = directory.appendingPathComponent("package.json")
                if let values = try? manifest.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                   values.isRegularFile == true, let size = values.fileSize, size <= 262_144,
                   let data = try? Data(contentsOf: manifest),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let packageName = json["name"] as? String, !packageName.isEmpty {
                    name = String(packageName.prefix(120))
                }
                return Project(root: directory.path, name: name)
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path, parent.path != "/" else { break }
            directory = parent
        }
        return nil
    }

    static func framework(arguments: [String], processName: String) -> String? {
        let tokens = arguments.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
        let name = processName.lowercased()
        if tokens.contains("vite") || tokens.contains("vite.js") { return "Vite" }
        if tokens.contains("next") || tokens.contains("next-server") || name.hasPrefix("next-server") { return "Next.js" }
        if tokens.contains("nuxt") || tokens.contains("nuxt.mjs") { return "Nuxt" }
        if tokens.contains("manage.py") && tokens.contains("runserver") { return "Django" }
        if tokens.contains("flask") { return "Flask" }
        if tokens.contains("uvicorn") { return "Uvicorn" }
        if name.hasPrefix("postgres") { return "PostgreSQL" }
        if name.hasPrefix("redis-server") { return "Redis" }
        if name == "mysqld" { return "MySQL" }
        if name == "nginx" { return "Nginx" }
        return nil // A port number alone is never sufficient evidence of a framework.
    }
}
