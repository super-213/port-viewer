import Foundation
import XCTest
@testable import PortViewer

private actor ControlledLsofRunner: LsofRunning {
    struct Metrics: Sendable {
        let calls: Int
        let maximumActive: Int
    }

    private var results: [LsofProcessResult]
    private let delay: Duration
    private var calls = 0
    private var active = 0
    private var maximumActive = 0

    init(results: [LsofProcessResult], delay: Duration = .zero) {
        self.results = results
        self.delay = delay
    }

    func run(executableURL: URL, timeout: Duration) async throws -> LsofProcessResult {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }

        if delay != .zero {
            try await Task.sleep(for: delay)
        }
        guard !results.isEmpty else {
            return LsofProcessResult(output: Data(), status: 1)
        }
        return results.removeFirst()
    }

    func metrics() -> Metrics {
        Metrics(calls: calls, maximumActive: maximumActive)
    }
}

@MainActor
final class LsofServiceTests: XCTestCase {
    private let executableURL = URL(fileURLWithPath: "/usr/bin/true")

    func testCompatibleConcurrentQueriesReuseSingleFlightAndWaiterCancellationDoesNotCancelIt() async throws {
        let runner = ControlledLsofRunner(
            results: [LsofProcessResult(output: validOutput(process: "node", pid: 123), status: 0)],
            delay: .milliseconds(200)
        )
        let service = LsofService(executableURL: executableURL, runner: runner)

        let first = Task { try await service.query(policy: .reuseInFlight) }
        try await waitForFirstCall(of: runner)
        let cancelledWaiter = Task { try await service.query(policy: .reuseInFlight) }
        try await Task.sleep(for: .milliseconds(20))
        cancelledWaiter.cancel()

        let firstSnapshot = try await first.value
        let waiterSnapshot = try await cancelledWaiter.value
        let metrics = await runner.metrics()

        XCTAssertEqual(firstSnapshot.records.first?.processName, "node")
        XCTAssertEqual(waiterSnapshot.records.first?.processName, "node")
        XCTAssertEqual(metrics.calls, 1)
        XCTAssertEqual(metrics.maximumActive, 1)
    }

    func testFreshQueryWaitsForCurrentFlightThenStartsNewProcess() async throws {
        let runner = ControlledLsofRunner(
            results: [
                LsofProcessResult(output: validOutput(process: "old", pid: 100), status: 0),
                LsofProcessResult(output: validOutput(process: "fresh", pid: 200), status: 0)
            ],
            delay: .milliseconds(150)
        )
        let service = LsofService(executableURL: executableURL, runner: runner)

        let existing = Task { try await service.query(policy: .reuseInFlight) }
        try await waitForFirstCall(of: runner)
        let fresh = Task { try await service.query(policy: .fresh) }

        let existingSnapshot = try await existing.value
        let freshSnapshot = try await fresh.value
        XCTAssertEqual(existingSnapshot.records.first?.processName, "old")
        XCTAssertEqual(freshSnapshot.records.first?.processName, "fresh")
        let metrics = await runner.metrics()
        XCTAssertEqual(metrics.calls, 2)
        XCTAssertEqual(metrics.maximumActive, 1)
    }

    func testCancelledFreshWaiterDoesNotStartAQueryAfterCurrentFlight() async throws {
        let runner = ControlledLsofRunner(
            results: [
                LsofProcessResult(output: validOutput(process: "current", pid: 100), status: 0),
                LsofProcessResult(output: validOutput(process: "must-not-start", pid: 200), status: 0)
            ],
            delay: .milliseconds(300)
        )
        let service = LsofService(executableURL: executableURL, runner: runner)

        let current = Task { try await service.query(policy: .reuseInFlight) }
        try await waitForFirstCall(of: runner)
        let fresh = Task { try await service.query(policy: .fresh) }
        fresh.cancel()

        _ = try await current.value
        await XCTAssertThrowsErrorAsync(try await fresh.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let metrics = await runner.metrics()
        XCTAssertEqual(metrics.calls, 1)
        XCTAssertEqual(metrics.maximumActive, 1)
    }

    func testOutputSemanticsForEmptyPartialNonzeroAndUnparseableResults() async throws {
        let emptyService = LsofService(
            executableURL: executableURL,
            runner: ControlledLsofRunner(results: [LsofProcessResult(output: Data(), status: 1)])
        )
        let empty = try await emptyService.query()
        XCTAssertTrue(empty.records.isEmpty)
        XCTAssertFalse(empty.isPartial)

        let partialService = LsofService(
            executableURL: executableURL,
            runner: ControlledLsofRunner(results: [LsofProcessResult(output: validOutput(process: "partial", pid: 1), status: 1)])
        )
        let partial = try await partialService.query()
        XCTAssertEqual(partial.records.first?.processName, "partial")
        XCTAssertTrue(partial.isPartial)

        let nonzeroService = LsofService(
            executableURL: executableURL,
            runner: ControlledLsofRunner(results: [LsofProcessResult(output: Data("invalid".utf8), status: 2)])
        )
        await XCTAssertThrowsErrorAsync(try await nonzeroService.query()) { error in
            XCTAssertEqual(error as? LsofQueryError, .executionFailed(2))
        }

        let invalidService = LsofService(
            executableURL: executableURL,
            runner: ControlledLsofRunner(results: [LsofProcessResult(output: Data("invalid".utf8), status: 0)])
        )
        await XCTAssertThrowsErrorAsync(try await invalidService.query()) { error in
            XCTAssertEqual(error as? LsofQueryError, .unparseableOutput)
        }
    }

    func testRealProcessBridgeTimesOutAndCancelsOnlyAfterProcessAndPipesClose() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hanging-lsof.sh")

        let timedService = LsofService(executableURL: fixture, timeout: .milliseconds(100))
        await XCTAssertThrowsErrorAsync(try await timedService.query()) { error in
            XCTAssertEqual(error as? LsofQueryError, .timedOut)
        }

        let cancelledService = LsofService(executableURL: fixture, timeout: .seconds(5))
        let query = Task { try await cancelledService.query() }
        try await Task.sleep(for: .milliseconds(50))
        await cancelledService.cancelCurrentQuery()
        await XCTAssertThrowsErrorAsync(try await query.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRealProcessBridgeRejectsOutputAboveConfiguredLimit() async {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/oversized-lsof.sh")
        let runner = LsofProcessRunner(outputByteLimit: 32)

        await XCTAssertThrowsErrorAsync(
            try await runner.run(executableURL: fixture, timeout: .seconds(5))
        ) { error in
            XCTAssertEqual(error as? LsofQueryError, .outputTooLarge)
        }
    }

    func testTimeoutFinishesWhenDescendantKeepsStandardOutputOpen() async {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/inherited-stdout-lsof.sh")
        let service = LsofService(executableURL: fixture, timeout: .milliseconds(100))
        let startedAt = Date()

        await XCTAssertThrowsErrorAsync(try await service.query()) { error in
            XCTAssertEqual(error as? LsofQueryError, .timedOut)
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            1.5,
            "停止后的查询不应继续等待后代进程持有的管道 EOF"
        )
    }

    func testProcessServiceMapsMissingProcessAndRecognizesCurrentProcess() {
        let service = ProcessService()
        XCTAssertTrue(service.exists(pid: ProcessInfo.processInfo.processIdentifier))

        XCTAssertThrowsError(try service.send(signal: 0, to: Int32.max)) { error in
            XCTAssertEqual(error as? ProcessSignalError, .processMissing)
        }
    }

    private func validOutput(process: String, pid: Int32) -> Data {
        let fields = [
            "p\(pid)", "c\(process)", "u501", "L\(NSUserName())",
            "f10", "tIPv4", "PTCP", "n*:3000", "TST=LISTEN"
        ]
        return Data((fields.joined(separator: "\0") + "\0").utf8)
    }

    private func waitForFirstCall(of runner: ControlledLsofRunner) async throws {
        for _ in 0..<100 {
            let metrics = await runner.metrics()
            if metrics.calls > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The first query did not reach the injected runner")
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T: Sendable>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
