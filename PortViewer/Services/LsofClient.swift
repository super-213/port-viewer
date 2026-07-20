import Darwin
import Foundation

enum LsofQueryError: LocalizedError {
    case unavailable
    case launchFailed(String)
    case timedOut
    case executionFailed(Int32)
    case unparseableOutput

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "找不到系统工具 /usr/sbin/lsof。请确认 macOS 系统文件完整后重试。"
        case .launchFailed(let reason):
            return "无法启动端口查询：\(reason)"
        case .timedOut:
            return "端口查询超时。已保留上一次成功结果，请稍后重试。"
        case .executionFailed(let status):
            return "lsof 查询失败（退出代码 \(status)）。"
        case .unparseableOutput:
            return "无法解析 lsof 输出。已保留上一次成功结果。"
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func replace(with value: Data) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

actor LsofClient {
    private let parser = LsofParser()
    private let executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    private let timeout: TimeInterval = 5

    func query() async throws -> PortSnapshot {
        let parser = parser
        let executableURL = executableURL
        let timeout = timeout

        return try await Task.detached(priority: .utility) {
            try Self.runQuery(parser: parser, executableURL: executableURL, timeout: timeout)
        }.value
    }

    private static func runQuery(
        parser: LsofParser,
        executableURL: URL,
        timeout: TimeInterval
    ) throws -> PortSnapshot {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LsofQueryError.unavailable
        }

        let startedAt = Date()
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputData = LockedData()
        let errorData = LockedData()
        let readers = DispatchGroup()

        process.executableURL = executableURL
        process.arguments = ["-nP", "-iTCP", "-iUDP", "-F0pcuLRftnPT"]
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw LsofQueryError.launchFailed(error.localizedDescription)
        }

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData.replace(with: standardOutput.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData.replace(with: standardError.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }

        let didTimeOut = process.isRunning
        if didTimeOut {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.3)
            while process.isRunning && Date() < terminationDeadline {
                usleep(10_000)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()
        readers.wait()
        _ = errorData.value // Drain stderr without exposing potentially sensitive details.

        if didTimeOut {
            throw LsofQueryError.timedOut
        }

        let output = outputData.value
        let records = parser.parse(output)
        let status = process.terminationStatus

        // lsof uses status 1 when no files match; that is a valid empty snapshot.
        if output.isEmpty, status == 0 || status == 1 {
            return PortSnapshot(
                records: [],
                capturedAt: Date(),
                duration: Date().timeIntervalSince(startedAt),
                isPartial: false
            )
        }

        guard !records.isEmpty else {
            if status != 0 { throw LsofQueryError.executionFailed(status) }
            throw LsofQueryError.unparseableOutput
        }

        let paths = Dictionary(
            uniqueKeysWithValues: Set(records.map(\.pid)).map { pid in
                (pid, ProcessMetadataResolver.executablePath(for: pid))
            }
        )
        let enrichedRecords = records.map { $0.withExecutablePath(paths[$0.pid] ?? nil) }

        return PortSnapshot(
            records: enrichedRecords,
            capturedAt: Date(),
            duration: Date().timeIntervalSince(startedAt),
            isPartial: status != 0
        )
    }
}

enum ProcessMetadataResolver {
    static func executablePath(for pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro unavailable to Swift (4 * MAXPATHLEN).
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
