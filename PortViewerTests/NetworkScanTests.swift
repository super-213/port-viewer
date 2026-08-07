import Foundation
import XCTest
@testable import PortViewer

final class NetworkScanParsingTests: XCTestCase {
    func testCustomPortParserSupportsListsRangesDeduplicationAndChineseComma() throws {
        XCTAssertEqual(
            try PortRangeParser.parse("443, 80,8000-8002，443"),
            [80, 443, 8_000, 8_001, 8_002]
        )
    }

    func testCustomPortParserRejectsInvalidPortsAndReversedRanges() {
        XCTAssertThrowsError(try PortRangeParser.parse("0"))
        XCTAssertThrowsError(try PortRangeParser.parse("65536"))
        XCTAssertThrowsError(try PortRangeParser.parse("90-80"))
        XCTAssertThrowsError(try PortRangeParser.parse("22,"))
    }

    func testIPv4SubnetUsesNetworkBoundaryAndExcludesNetworkAndBroadcast() throws {
        let subnet = try IPv4Subnet(cidr: "192.168.7.123/30")
        XCTAssertEqual(subnet.hosts, ["192.168.7.121", "192.168.7.122"])
        XCTAssertEqual(subnet.prefixLength, 30)
    }

    func testPlanAllowsAllPortsForOneHostButRejectsExplosiveSubnetScan() throws {
        let hostPlan = try NetworkScanPlan.make(
            scope: .host,
            target: "192.168.1.10",
            preset: .all,
            customPorts: "",
            timeout: 0.3
        )
        XCTAssertEqual(hostPlan.totalProbeCount, 65_535)

        XCTAssertThrowsError(
            try NetworkScanPlan.make(
                scope: .subnet,
                target: "192.168.1.0/24",
                preset: .all,
                customPorts: "",
                timeout: 0.3
            )
        ) { error in
            guard case NetworkScanValidationError.tooManyProbes = error else {
                return XCTFail("Expected tooManyProbes, got \(error)")
            }
        }
    }
}

private actor ControlledTCPProber: TCPPortProbing {
    struct Metrics: Sendable {
        let calls: Int
        let maximumActive: Int
    }

    private let openEndpoints: Set<String>
    private let delay: Duration
    private var calls = 0
    private var active = 0
    private var maximumActive = 0

    init(openEndpoints: Set<String>, delay: Duration = .milliseconds(10)) {
        self.openEndpoints = openEndpoints
        self.delay = delay
    }

    func probe(host: String, port: UInt16, timeout: Duration) async -> OpenPortResult? {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, openEndpoints.contains("\(host):\(port)") else { return nil }
        return OpenPortResult(host: host, port: port, latency: 0.01)
    }

    func metrics() -> Metrics {
        Metrics(calls: calls, maximumActive: maximumActive)
    }
}

final class NetworkScannerServiceTests: XCTestCase {
    func testScannerFindsOpenPortsReportsFinalProgressAndRespectsConcurrency() async throws {
        let prober = ControlledTCPProber(openEndpoints: ["10.0.0.1:80", "10.0.0.2:443"])
        let scanner = NetworkScannerService(prober: prober)
        let plan = NetworkScanPlan(
            scope: .subnet,
            targets: ["10.0.0.1", "10.0.0.2"],
            ports: [22, 80, 443],
            timeout: .milliseconds(100),
            concurrency: 2
        )
        let progressStore = ProgressStore()

        let report = try await scanner.scan(plan: plan) { progress in
            progressStore.append(progress)
        }
        let metrics = await prober.metrics()
        let progress = progressStore.snapshot()

        XCTAssertEqual(report.openPorts.map(\.endpoint), ["10.0.0.1:80", "10.0.0.2:443"])
        XCTAssertEqual(metrics.calls, 6)
        XCTAssertLessThanOrEqual(metrics.maximumActive, 2)
        XCTAssertEqual(progress.last?.completedCount, 6)
        XCTAssertEqual(progress.last?.openCount, 2)
    }

    func testScannerCancellationStopsSchedulingNewProbes() async throws {
        let prober = ControlledTCPProber(openEndpoints: [], delay: .milliseconds(100))
        let scanner = NetworkScannerService(prober: prober)
        let plan = NetworkScanPlan(
            scope: .host,
            targets: ["127.0.0.1"],
            ports: (1...100).map(UInt16.init),
            timeout: .seconds(1),
            concurrency: 4
        )

        let task = Task { try await scanner.scan(plan: plan) { _ in } }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let metrics = await prober.metrics()
        XCTAssertLessThan(metrics.calls, 100)
    }
}

private final class ProgressStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NetworkScanProgress] = []

    func append(_ progress: NetworkScanProgress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
    }

    func snapshot() -> [NetworkScanProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
