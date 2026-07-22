import Darwin
import Foundation

enum LsofQueryError: LocalizedError, Equatable {
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

struct LsofProcessResult: Sendable {
    let output: Data
    let status: Int32
}

protocol LsofRunning: Sendable {
    func run(executableURL: URL, timeout: Duration) async throws -> LsofProcessResult
}

struct LsofProcessRunner: LsofRunning {
    func run(executableURL: URL, timeout: Duration) async throws -> LsofProcessResult {
        let session = LsofProcessSession(executableURL: executableURL)
        return try await session.run(timeout: timeout)
    }
}

/// Owns one Foundation `Process` and translates its callback-based lifecycle into
/// a cancellable async operation. The output callback continuously drains its pipe
/// so the child cannot block; stderr is intentionally discarded because the public
/// error model only exposes stable exit-status messages.
private actor LsofProcessSession {
    private enum StopReason {
        case timedOut
        case cancelled
    }

    private struct Completion {
        let result: LsofProcessResult
        let stopReason: StopReason?
    }

    private let process = Process()
    private let standardOutput = Pipe()
    private var output = Data()
    private var outputReachedEOF = false
    private var terminationStatus: Int32?
    private var stopReason: StopReason?
    private var completion: Completion?
    private var completionContinuation: CheckedContinuation<Completion, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var forceKillTask: Task<Void, Never>?

    init(executableURL: URL) {
        process.executableURL = executableURL
        process.arguments = ["-nP", "-iTCP", "-iUDP", "-F0pcuLRftnPT"]
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
    }

    func run(timeout: Duration) async throws -> LsofProcessResult {
        try Task.checkCancellation()
        installHandlers()

        do {
            try process.run()
        } catch {
            tearDownHandlers()
            closePipes()
            throw LsofQueryError.launchFailed(error.localizedDescription)
        }

        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.requestStop(.timedOut)
        }

        let completion = await withTaskCancellationHandler {
            await waitForCompletion()
        } onCancel: { [weak self] in
            Task { await self?.requestStop(.cancelled) }
        }

        switch completion.stopReason {
        case .timedOut:
            throw LsofQueryError.timedOut
        case .cancelled:
            throw CancellationError()
        case nil:
            return completion.result
        }
    }

    private func installHandlers() {
        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receive(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { await self?.didTerminate(status: status) }
        }
    }

    private func receive(_ data: Data) {
        if data.isEmpty {
            outputReachedEOF = true
            standardOutput.fileHandleForReading.readabilityHandler = nil
        } else {
            output.append(data)
        }
        finishIfPossible()
    }

    private func didTerminate(status: Int32) {
        terminationStatus = status
        finishIfPossible()
    }

    private func requestStop(_ reason: StopReason) {
        guard completion == nil, stopReason == nil else { return }
        stopReason = reason

        if process.isRunning {
            process.terminate()
            forceKillTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
                await self?.forceKillIfNeeded()
            }
        } else {
            finishIfPossible()
        }
    }

    private func forceKillIfNeeded() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    private func waitForCompletion() async -> Completion {
        if let completion { return completion }
        return await withCheckedContinuation { continuation in
            completionContinuation = continuation
        }
    }

    private func finishIfPossible() {
        guard completion == nil,
              let terminationStatus,
              outputReachedEOF else { return }

        timeoutTask?.cancel()
        forceKillTask?.cancel()
        tearDownHandlers()
        closePipes()

        let value = Completion(
            result: LsofProcessResult(output: output, status: terminationStatus),
            stopReason: stopReason
        )
        completion = value
        completionContinuation?.resume(returning: value)
        completionContinuation = nil
    }

    private func tearDownHandlers() {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
    }

    private func closePipes() {
        try? standardOutput.fileHandleForReading.close()
        try? standardOutput.fileHandleForWriting.close()
    }
}

actor LsofService: PortQuerying {
    private struct InFlightQuery {
        let id: UInt64
        let task: Task<PortSnapshot, Error>
    }

    private let parser: LsofParser
    private let executableURL: URL
    private let timeout: Duration
    private let runner: any LsofRunning
    private let metadataCache: ProcessMetadataCache
    private var nextQueryID: UInt64 = 0
    private var inFlight: InFlightQuery?

    init(
        parser: LsofParser = LsofParser(),
        executableURL: URL = URL(fileURLWithPath: "/usr/sbin/lsof"),
        timeout: Duration = .seconds(5),
        runner: any LsofRunning = LsofProcessRunner(),
        metadataCache: ProcessMetadataCache = ProcessMetadataCache()
    ) {
        self.parser = parser
        self.executableURL = executableURL
        self.timeout = timeout
        self.runner = runner
        self.metadataCache = metadataCache
    }

    func query(policy: PortQueryPolicy = .reuseInFlight) async throws -> PortSnapshot {
        switch policy {
        case .reuseInFlight:
            if let inFlight {
                return try await result(of: inFlight)
            }
            try Task.checkCancellation()
        case .fresh:
            while let current = inFlight {
                _ = try? await result(of: current)
            }
            try Task.checkCancellation()
        }

        let query = makeQuery(forceMetadataRefresh: policy == .fresh)
        inFlight = query
        return try await result(of: query)
    }

    func cancelCurrentQuery() async {
        guard let current = inFlight else { return }
        current.task.cancel()
        _ = try? await result(of: current)
    }

    private func makeQuery(forceMetadataRefresh: Bool) -> InFlightQuery {
        nextQueryID &+= 1
        let id = nextQueryID
        let parser = parser
        let executableURL = executableURL
        let timeout = timeout
        let runner = runner
        let metadataCache = metadataCache

        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw LsofQueryError.unavailable
            }

            let startedAt = ContinuousClock.now
            let processResult = try await runner.run(executableURL: executableURL, timeout: timeout)
            let records = parser.parse(processResult.output)
            let status = processResult.status
            let duration = startedAt.duration(to: .now).timeInterval

            // lsof uses status 1 when no files match; that is a valid empty snapshot.
            if processResult.output.isEmpty, status == 0 || status == 1 {
                return PortSnapshot(
                    records: [],
                    capturedAt: Date(),
                    duration: duration,
                    isPartial: false
                )
            }

            guard !records.isEmpty else {
                if status != 0 { throw LsofQueryError.executionFailed(status) }
                throw LsofQueryError.unparseableOutput
            }

            let paths = await metadataCache.executablePaths(
                for: records,
                forceRefresh: forceMetadataRefresh
            )
            let enrichedRecords = records.map { $0.withExecutablePath(paths[$0.pid]) }

            return PortSnapshot(
                records: enrichedRecords,
                capturedAt: Date(),
                duration: duration,
                isPartial: status != 0
            )
        }
        return InFlightQuery(id: id, task: task)
    }

    private func result(of query: InFlightQuery) async throws -> PortSnapshot {
        do {
            let value = try await query.task.value
            clearIfCurrent(query.id)
            return value
        } catch {
            clearIfCurrent(query.id)
            throw error
        }
    }

    private func clearIfCurrent(_ id: UInt64) {
        guard inFlight?.id == id else { return }
        inFlight = nil
    }
}

actor ProcessMetadataCache {
    private struct ProcessIdentity: Hashable {
        let pid: Int32
        let command: String
    }

    private struct Entry {
        let path: String?
        let resolvedAt: Date
    }

    private let timeToLive: TimeInterval
    private var entries: [ProcessIdentity: Entry] = [:]

    init(timeToLive: TimeInterval = 30) {
        self.timeToLive = timeToLive
    }

    func executablePaths(
        for records: [PortRecord],
        forceRefresh: Bool,
        now: Date = Date()
    ) -> [Int32: String] {
        var commandsByPID: [Int32: String] = [:]
        for record in records {
            commandsByPID[record.pid] = record.processName
        }

        let activeIdentities = Set(commandsByPID.map {
            ProcessIdentity(pid: $0.key, command: $0.value)
        })
        entries = entries.filter { activeIdentities.contains($0.key) }

        var result: [Int32: String] = [:]
        result.reserveCapacity(commandsByPID.count)
        for (pid, command) in commandsByPID {
            let identity = ProcessIdentity(pid: pid, command: command)
            let path: String?
            if !forceRefresh,
               let cached = entries[identity],
               now.timeIntervalSince(cached.resolvedAt) < timeToLive {
                path = cached.path
            } else {
                path = ProcessMetadataResolver.executablePath(for: pid)
                entries[identity] = Entry(path: path, resolvedAt: now)
            }
            if let path {
                result[pid] = path
            }
        }
        return result
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

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
