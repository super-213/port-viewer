import Darwin
import Foundation
@testable import PortViewer

enum StubQueryResponse: Sendable {
    case snapshot(PortSnapshot)
    case failure(LsofQueryError)
}

actor StubPortQueryService: PortQuerying {
    private var responses: [StubQueryResponse]
    private let delay: Duration?
    private var receivedPolicies: [PortQueryPolicy] = []

    init(
        responses: [StubQueryResponse],
        delay: Duration? = nil
    ) {
        self.responses = responses
        self.delay = delay
    }

    func query(policy: PortQueryPolicy) async throws -> PortSnapshot {
        receivedPolicies.append(policy)
        if let delay {
            try await Task.sleep(for: delay)
        }
        guard !responses.isEmpty else {
            throw LsofQueryError.executionFailed(-1)
        }
        switch responses.removeFirst() {
        case .snapshot(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        }
    }

    func callCount() -> Int {
        receivedPolicies.count
    }

    func policies() -> [PortQueryPolicy] {
        receivedPolicies
    }
}

struct StubProcessService: ProcessControlling {
    var processExists = false
    var signalError: ProcessSignalError?

    func send(signal: Int32, to pid: Int32) throws {
        if let signalError { throw signalError }
    }

    func exists(pid: Int32) -> Bool {
        processExists
    }
}

enum PortTestFixtures {
    static func record(
        processName: String = "node",
        pid: Int32 = 123,
        user: String = NSUserName(),
        fileDescriptor: String = "10",
        ipVersion: IPVersion = .v4,
        transport: TransportProtocol = .tcp,
        localAddress: String = "127.0.0.1",
        localPort: Int? = 3_000,
        remoteAddress: String? = nil,
        remotePort: Int? = nil,
        state: String? = "LISTEN",
        executablePath: String? = "/usr/local/bin/node",
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> PortRecord {
        PortRecord(
            processName: processName,
            pid: pid,
            user: user,
            fileDescriptor: fileDescriptor,
            ipVersion: ipVersion,
            transport: transport,
            localAddress: localAddress,
            localPort: localPort,
            remoteAddress: remoteAddress,
            remotePort: remotePort,
            state: state,
            executablePath: executablePath,
            parentPID: nil,
            updatedAt: updatedAt
        )
    }

    static func snapshot(
        records: [PortRecord],
        capturedAt: Date = Date(timeIntervalSince1970: 100),
        duration: TimeInterval = 0.05,
        isPartial: Bool = false
    ) -> PortSnapshot {
        PortSnapshot(
            records: records,
            capturedAt: capturedAt,
            duration: duration,
            isPartial: isPartial
        )
    }

    @MainActor
    static func viewModel(
        queryService: any PortQuerying,
        processService: any ProcessControlling = StubProcessService()
    ) -> PortViewModel {
        PortViewModel(queryService: queryService, processService: processService)
    }
}
