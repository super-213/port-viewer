import Darwin
import Foundation

protocol ServiceContextProviding: Sendable {
    func enrich(_ records: [PortRecord], forceRefresh: Bool) async -> [PortRecord]
    func stop(_ service: ManagedService, for record: PortRecord) async throws
}

protocol LocalCommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: Duration) async throws -> Data
}

struct LocalCommandRunner: LocalCommandRunning {
    func run(executable: String, arguments: [String], timeout: Duration) async throws -> Data {
        // No shell and no inherited Docker context/host. Disable Homebrew update/analytics.
        let environment = ["HOME": NSHomeDirectory(), "USER": NSUserName(),
                           "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                           "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1",
                           "HOMEBREW_NO_ENV_HINTS": "1"]
        let session = LsofProcessSession(executableURL: URL(fileURLWithPath: executable),
                                        outputByteLimit: 4 * 1_024 * 1_024,
                                        arguments: arguments, environment: environment)
        let result: LsofProcessResult
        do { result = try await session.run(timeout: timeout) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ManagedServiceError.commandFailed }
        guard result.status == 0 else { throw ManagedServiceError.commandFailed }
        return result.output
    }
}

enum ManagedServiceError: LocalizedError, Equatable {
    case changed, commandFailed, stillRunning
    var errorDescription: String? {
        switch self {
        case .changed: return L10n.string("服务归属或启动身份已变化，已取消停止操作。请刷新后重试。")
        case .commandFailed: return L10n.string("服务管理命令失败。请检查 Docker 或 Homebrew 的运行状态并刷新确认。")
        case .stillRunning: return L10n.string("停止命令已执行，但服务仍在运行。请刷新后检查。")
        }
    }
}

protocol ServiceProcessInspecting: Sendable {
    func identity(for pid: Int32) -> ProcessIdentity?
    func executablePath(for pid: Int32) -> String?
    func ancestry(for pid: Int32) -> [ProcessIdentity]
}

struct ServiceProcessInspector: ServiceProcessInspecting {
    func identity(for pid: Int32) -> ProcessIdentity? { ProcessMetadataResolver.identity(for: pid) }
    func executablePath(for pid: Int32) -> String? { ProcessMetadataResolver.executablePath(for: pid) }
    func ancestry(for pid: Int32) -> [ProcessIdentity] { ProcessMetadataResolver.ancestry(for: pid) }
}

actor ManagedServiceController: ServiceContextProviding {
    struct Tools: Sendable {
        var docker: String?
        var dockerSocket: String?
        var brew: [String] = []

        static func installed() -> Tools {
            let files = FileManager.default
            let docker = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                          "/Applications/Docker.app/Contents/Resources/bin/docker"]
                .first { files.isExecutableFile(atPath: $0) }
            let socket = [NSHomeDirectory() + "/.docker/run/docker.sock", "/var/run/docker.sock",
                          NSHomeDirectory() + "/.colima/default/docker.sock"]
                .first { files.fileExists(atPath: $0) }
            return Tools(docker: docker, dockerSocket: socket,
                         brew: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].filter { files.isExecutableFile(atPath: $0) })
        }
    }

    struct Binding: Hashable, Sendable {
        let address: String
        let port: Int
        let transport: TransportProtocol
    }
    struct Container: Sendable {
        let service: ManagedService
        let bindings: [Binding]
    }
    struct BrewJob: Sendable {
        let service: ManagedService
        let identity: ProcessIdentity
    }

    private let runner: any LocalCommandRunning
    private let configuredTools: Tools?
    private let processes: any ServiceProcessInspecting
    private var cachedAt = Date.distantPast
    private var containers: [Container] = []
    private var jobs: [BrewJob] = []

    init(runner: any LocalCommandRunning = LocalCommandRunner(), tools: Tools? = nil,
         processes: any ServiceProcessInspecting = ServiceProcessInspector()) {
        self.runner = runner
        configuredTools = tools
        self.processes = processes
    }

    func enrich(_ records: [PortRecord], forceRefresh: Bool) async -> [PortRecord] {
        if forceRefresh || Date().timeIntervalSince(cachedAt) >= 15 {
            let tools = configuredTools ?? Tools.installed()
            // An unavailable integration never discards the local port snapshot or retains stale ownership.
            do { containers = try await discoverContainers(tools: tools) } catch { containers = [] }
            do { jobs = try await discoverBrewJobs(tools: tools) } catch { jobs = [] }
            cachedAt = Date()
        }
        return records.map { record in
            var context = record.context
            context.managedService = nil
            guard record.belongsToCurrentUser else { return record.withContext(context) }
            let dockerMatches = containers.filter { Self.matches(record, container: $0) }
            if dockerMatches.count == 1 {
                context.managedService = dockerMatches[0].service
            } else if dockerMatches.isEmpty {
                let candidates = jobs.filter { Self.isBrewExecutable(record.executablePath, service: $0.service) }
                if !candidates.isEmpty {
                    let ancestry = processes.ancestry(for: record.pid)
                    let matches = candidates.filter { ancestry.contains($0.identity) }
                    if matches.count == 1 { context.managedService = matches[0].service }
                }
            }
            return record.withContext(context)
        }
    }

    func stop(_ service: ManagedService, for record: PortRecord) async throws {
        guard record.belongsToCurrentUser, let identity = record.context.identity,
              processes.identity(for: record.pid) == identity else { throw ManagedServiceError.changed }
        let tools = configuredTools ?? Tools.installed()
        switch service.kind {
        case .docker:
            guard tools.docker == service.executable,
                  tools.dockerSocket == service.endpoint else { throw ManagedServiceError.changed }
            let current = try await discoverContainers(tools: tools)
            guard current.contains(where: { $0.service == service && Self.matches(record, container: $0) }) else {
                throw ManagedServiceError.changed
            }
            try Task.checkCancellation()
            guard processes.identity(for: record.pid) == identity else { throw ManagedServiceError.changed }
            _ = try await runner.run(executable: service.executable,
                                     arguments: ["--host", "unix://" + service.endpoint, "stop", "--timeout", "10", service.target],
                                     timeout: .seconds(15))
            // Query the running set again; auto-removed containers are also correctly absent.
            let remaining = try await discoverContainers(tools: tools)
            guard !remaining.contains(where: { $0.service.target == service.target }) else { throw ManagedServiceError.stillRunning }
        case .homebrew:
            guard tools.brew.contains(service.executable), Self.validFormula(service.target) else { throw ManagedServiceError.changed }
            let current = try await discoverBrewJobs(tools: tools)
            let ancestry = processes.ancestry(for: record.pid)
            guard let job = current.first(where: { $0.service == service && ancestry.contains($0.identity) }),
                  Self.isBrewExecutable(record.executablePath, service: service) else { throw ManagedServiceError.changed }
            try Task.checkCancellation()
            guard processes.identity(for: record.pid) == identity,
                  processes.identity(for: job.identity.pid) == job.identity else { throw ManagedServiceError.changed }
            _ = try await runner.run(executable: service.executable,
                                     arguments: ["services", "stop", service.target, "--max-wait=10"], timeout: .seconds(20))
            let output = try await runner.run(executable: "/bin/launchctl", arguments: ["list"], timeout: .seconds(3))
            guard !Self.launchdJobs(output).contains(where: { $0.formula == service.target }) else { throw ManagedServiceError.stillRunning }
        }
        cachedAt = .distantPast
    }

    private func discoverContainers(tools: Tools) async throws -> [Container] {
        guard let docker = tools.docker, let socket = tools.dockerSocket else { return [] }
        let prefix = ["--host", "unix://" + socket]
        let output = try await runner.run(executable: docker,
                                         arguments: prefix + ["ps", "--quiet", "--no-trunc"], timeout: .seconds(3))
        let ids = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
        guard ids.allSatisfy(Self.validContainerID), ids.count <= 256 else { throw ManagedServiceError.commandFailed }
        guard !ids.isEmpty else { return [] }
        let data = try await runner.run(executable: docker,
                                       arguments: prefix + ["inspect", "--type", "container"] + ids, timeout: .seconds(4))
        return try Self.parseContainers(data, executable: docker, socket: socket)
    }

    private func discoverBrewJobs(tools: Tools) async throws -> [BrewJob] {
        guard !tools.brew.isEmpty else { return [] }
        let data = try await runner.run(executable: "/bin/launchctl", arguments: ["list"], timeout: .seconds(3))
        return Self.launchdJobs(data).compactMap { job in
            guard let identity = processes.identity(for: job.pid), identity.userID == getuid(),
                  let path = processes.executablePath(for: job.pid) else { return nil }
            for brew in tools.brew {
                let prefix = URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent().path
                let service = ManagedService(kind: .homebrew, target: job.formula, name: job.formula,
                                             executable: brew, endpoint: prefix,
                                             generation: "\(identity.pid):\(identity.startSeconds):\(identity.startMicroseconds)")
                if Self.isBrewExecutable(path, service: service) { return BrewJob(service: service, identity: identity) }
            }
            return nil
        }
    }

    static func launchdJobs(_ data: Data) -> [(pid: Int32, formula: String)] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count == 3, let pid = Int32(columns[0]), pid > 1,
                  columns[2].hasPrefix("homebrew.mxcl.") else { return nil }
            let formula = String(columns[2].dropFirst("homebrew.mxcl.".count))
            guard validFormula(formula) else { return nil }
            return (pid, formula)
        }
    }

    static func validFormula(_ name: String) -> Bool {
        name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9@+_.-]{0,127}$", options: .regularExpression) != nil
    }
    static func validContainerID(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    static func isBrewExecutable(_ path: String?, service: ManagedService) -> Bool {
        guard let path else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasPrefix(service.endpoint + "/Cellar/" + service.target + "/")
            || resolved.hasPrefix(service.endpoint + "/opt/" + service.target + "/")
    }

    static func matches(_ record: PortRecord, container: Container) -> Bool {
        let name = record.processName.lowercased()
        let executable = record.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() } ?? ""
        // macOS Docker publishes ports via a shared forwarding process, not the container's PID.
        guard ["com.docker.backend", "com.docker.vpnkit", "vpnkit", "docker-proxy"].contains(executable)
                || ["com.docker", "com.docker.backend", "vpnkit", "docker-proxy"].contains(name),
              record.isListening || record.transport == .udp else { return false }
        return container.bindings.contains { binding in
            guard binding.port == record.localPort, binding.transport == record.transport else { return false }
            let local = record.localAddress
            let host = binding.address
            if record.ipVersion == .v4 && host.contains(":") { return false }
            if record.ipVersion == .v6 && host.contains(".") { return false }
            if local == host { return true }
            if local == "*" { return host == "0.0.0.0" || host == "::" || host.isEmpty }
            return host.isEmpty && (local == "0.0.0.0" || local == "::")
        }
    }

    static func parseContainers(_ data: Data, executable: String, socket: String) throws -> [Container] {
        struct Inspection: Decodable {
            let Id: String
            let Name: String
            let State: StateInfo
            let NetworkSettings: NetworkInfo
            struct StateInfo: Decodable { let Running: Bool; let StartedAt: String }
            struct NetworkInfo: Decodable { let Ports: [String: [PortBinding]?]? }
            struct PortBinding: Decodable { let HostIp: String; let HostPort: String }
        }
        return try JSONDecoder().decode([Inspection].self, from: data).compactMap { value in
            guard validContainerID(value.Id), value.State.Running, !value.State.StartedAt.isEmpty else { return nil }
            let bindings = (value.NetworkSettings.Ports ?? [:]).flatMap { key, values -> [Binding] in
                let parts = key.split(separator: "/")
                guard parts.count == 2, let transport = TransportProtocol(rawValue: parts[1].uppercased()) else { return [] }
                return (values ?? []).compactMap { value in
                    guard let port = Int(value.HostPort), (1...65535).contains(port) else { return nil }
                    return Binding(address: value.HostIp, port: port, transport: transport)
                }
            }
            return Container(service: ManagedService(kind: .docker, target: value.Id,
                                                     name: String(value.Name.drop(while: { $0 == "/" })),
                                                     executable: executable, endpoint: socket, generation: value.State.StartedAt),
                             bindings: bindings)
        }
    }
}

extension ProcessMetadataResolver {
    static func ancestry(for pid: Int32) -> [ProcessIdentity] {
        var result: [ProcessIdentity] = []
        var current = pid
        for _ in 0..<16 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard current > 1, proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == getuid() else { break }
            let identity = ProcessIdentity(pid: current, userID: info.pbi_uid,
                                           startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
            guard !result.contains(identity) else { break }
            result.append(identity)
            current = Int32(info.pbi_ppid)
        }
        return result
    }
}
