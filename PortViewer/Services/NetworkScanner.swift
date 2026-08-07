import Foundation
import Network

protocol TCPPortProbing: Sendable {
    func probe(host: String, port: UInt16, timeout: Duration) async -> OpenPortResult?
}

protocol NetworkScanning: Sendable {
    func scan(
        plan: NetworkScanPlan,
        progress: @escaping @Sendable (NetworkScanProgress) -> Void
    ) async throws -> NetworkScanReport
}

struct TCPConnectProber: TCPPortProbing {
    func probe(host: String, port: UInt16, timeout: Duration) async -> OpenPortResult? {
        let session = TCPProbeSession(host: host, port: port)
        return await withTaskCancellationHandler {
            await session.run(timeout: timeout)
        } onCancel: {
            session.cancel()
        }
    }
}

private final class TCPProbeSession: @unchecked Sendable {
    private let lock = NSLock()
    private let host: String
    private let port: UInt16
    private let connection: NWConnection
    private let startedAt = ContinuousClock.now
    private var continuation: CheckedContinuation<OpenPortResult?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var result: OpenPortResult??

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    func run(timeout: Duration) async -> OpenPortResult? {
        await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let elapsed = self.startedAt.duration(to: .now)
                    self.finish(
                        OpenPortResult(
                            host: self.host,
                            port: self.port,
                            latency: elapsed.timeInterval
                        )
                    )
                case .failed, .cancelled:
                    self.finish(nil)
                default:
                    break
                }
            }

            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()

            connection.start(queue: .global(qos: .utility))
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(nil)
            }
            lock.lock()
            if result == nil {
                self.timeoutTask = timeoutTask
                lock.unlock()
            } else {
                lock.unlock()
                timeoutTask.cancel()
            }
        }
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ value: OpenPortResult?) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = .some(value)
        let continuation = continuation
        self.continuation = nil
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(returning: value)
    }
}

actor NetworkScannerService: NetworkScanning {
    private let prober: any TCPPortProbing

    init(prober: any TCPPortProbing = TCPConnectProber()) {
        self.prober = prober
    }

    func scan(
        plan: NetworkScanPlan,
        progress: @escaping @Sendable (NetworkScanProgress) -> Void
    ) async throws -> NetworkScanReport {
        try Task.checkCancellation()
        let startedAt = Date()
        let total = plan.totalProbeCount
        let reportingStride = max(1, total / 500)
        let prober = prober

        var openPorts: [OpenPortResult] = []
        openPorts.reserveCapacity(min(total, 256))
        var completed = 0
        var nextIndex = 0

        progress(NetworkScanProgress(
            completedCount: 0,
            totalCount: total,
            openCount: 0,
            currentEndpoint: nil
        ))

        try await withThrowingTaskGroup(of: (String, UInt16, OpenPortResult?).self) { group in
            func addProbe(at index: Int) {
                let host = plan.targets[index / plan.ports.count]
                let port = plan.ports[index % plan.ports.count]
                group.addTask {
                    try Task.checkCancellation()
                    let result = await prober.probe(host: host, port: port, timeout: plan.timeout)
                    return (host, port, result)
                }
            }

            let initialCount = min(plan.concurrency, total)
            for _ in 0..<initialCount {
                addProbe(at: nextIndex)
                nextIndex += 1
            }

            while let (host, port, result) = try await group.next() {
                try Task.checkCancellation()
                completed += 1
                if let result { openPorts.append(result) }

                if completed == total || completed.isMultiple(of: reportingStride) || result != nil {
                    progress(NetworkScanProgress(
                        completedCount: completed,
                        totalCount: total,
                        openCount: openPorts.count,
                        currentEndpoint: "\(host):\(port)"
                    ))
                }

                if nextIndex < total {
                    addProbe(at: nextIndex)
                    nextIndex += 1
                }
            }
        }

        openPorts.sort {
            if $0.host != $1.host { return Self.addressAwareLessThan($0.host, $1.host) }
            return $0.port < $1.port
        }
        return NetworkScanReport(
            plan: plan,
            openPorts: openPorts,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    private static func addressAwareLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedAscending
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
