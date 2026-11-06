import Foundation
import XCTest
@testable import PortViewer

private actor GatedPortQueryService: PortQuerying {
    private let snapshot: PortSnapshot
    private var waiters: [CheckedContinuation<PortSnapshot, Error>] = []
    private var calls = 0

    init(snapshot: PortSnapshot) { self.snapshot = snapshot }

    func query(policy: PortQueryPolicy) async throws -> PortSnapshot {
        calls += 1
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func callCount() -> Int { calls }
    func cancelCurrentQuery() { release() }
    func release() {
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume(returning: snapshot) }
    }
}

private actor CleanupGatedPortQueryService: PortQuerying {
    private var cleanup: CheckedContinuation<Void, Never>?
    private var calls = 0
    func query(policy: PortQueryPolicy) async throws -> PortSnapshot {
        calls += 1
        if calls == 1 { try await Task.sleep(for: .seconds(60)) }
        return PortTestFixtures.snapshot(records: [])
    }
    func cancelCurrentQuery() async {
        await withCheckedContinuation { cleanup = $0 }
    }
    func isCleaningUp() -> Bool { cleanup != nil }
    func callCount() -> Int { calls }
    func finishCleanup() { cleanup?.resume(); cleanup = nil }
}

private actor CancellableLsofRunner: LsofRunning {
    private var active = false
    func run(executableURL: URL, timeout: Duration) async throws -> LsofProcessResult {
        active = true
        defer { active = false }
        try await Task.sleep(for: .seconds(60))
        return LsofProcessResult(output: Data(), status: 1)
    }
    func isActive() -> Bool { active }
}

@MainActor
final class PortQueryServiceTests: XCTestCase {
    private func snapshot(partial: Bool = false) -> PortSnapshot {
        PortTestFixtures.snapshot(records: [PortTestFixtures.record()], isPartial: partial)
    }

    func testNormalRefreshUsesNativeWithoutLsof() async throws {
        let native = StubPortQueryService(responses: [.snapshot(snapshot())])
        let lsof = StubPortQueryService(responses: [])
        let result = try await PortQueryService(native: native, lsof: lsof).query()
        XCTAssertFalse(result.isPartial)
        let calls = await lsof.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testNativeFailureAndPartialSnapshotBothFallBack() async throws {
        for response in [StubQueryResponse.failure(.unavailable), .snapshot(snapshot(partial: true))] {
            let native = StubPortQueryService(responses: [response])
            let lsof = StubPortQueryService(responses: [.snapshot(snapshot())])
            let result = try await PortQueryService(native: native, lsof: lsof).query()
            XCTAssertFalse(result.isPartial)
            XCTAssertEqual(result.diagnostics.source, .lsofFallback)
            XCTAssertNotNil(result.diagnostics.fallbackReason)
            let calls = await lsof.callCount()
            XCTAssertEqual(calls, 1)
        }
    }

    func testBothFailPropagatesLsofError() async {
        let service = PortQueryService(
            native: StubPortQueryService(responses: [.failure(.timedOut)]),
            lsof: StubPortQueryService(responses: [.failure(.unavailable)]))
        do { _ = try await service.query(); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? LsofQueryError, .unavailable) }
    }

    func testPartialNativeSurvivesFailedFallbackAsPartial() async throws {
        let service = PortQueryService(
            native: StubPortQueryService(responses: [.snapshot(snapshot(partial: true))]),
            lsof: StubPortQueryService(responses: [.failure(.unavailable)]))
        let result = try await service.query()
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertTrue(result.diagnostics.fallbackReason?.contains("fallback failed") == true)
    }

    func testFreshNeverUsesNativeEvenWhenLsofFailsOrIsPartial() async throws {
        let native = StubPortQueryService(responses: [.snapshot(snapshot())])
        let lsof = StubPortQueryService(responses: [.snapshot(snapshot(partial: true)), .failure(.unavailable)])
        let service = PortQueryService(native: native, lsof: lsof)
        let partial = try await service.query(policy: .fresh)
        XCTAssertTrue(partial.isPartial)
        do { _ = try await service.query(policy: .fresh); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? LsofQueryError, .unavailable) }
        let policies = await lsof.policies()
        let nativeCalls = await native.callCount()
        XCTAssertEqual(policies, [.fresh, .fresh])
        XCTAssertEqual(nativeCalls, 0)
    }

    func testConcurrentRefreshesShareFlightAndFreshWaits() async throws {
        let native = GatedPortQueryService(snapshot: snapshot())
        let lsof = StubPortQueryService(responses: [.snapshot(snapshot())])
        let service = PortQueryService(native: native, lsof: lsof)
        let first = Task { try await service.query() }
        for _ in 0..<100 {
            if await native.callCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let second = Task { try await service.query() }
        try await Task.sleep(for: .milliseconds(20))
        let fresh = Task { try await service.query(policy: .fresh) }
        try await Task.sleep(for: .milliseconds(20))
        let earlyCalls = await lsof.callCount()
        XCTAssertEqual(earlyCalls, 0)
        await native.release()
        _ = try await first.value
        _ = try await second.value
        _ = try await fresh.value
        let calls = await native.callCount()
        let policies = await lsof.policies()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(policies, [.fresh])
    }

    func testCancelledFreshWaiterDoesNotStartLsof() async throws {
        let native = StubPortQueryService(responses: [.snapshot(snapshot())], delay: .milliseconds(100))
        let lsof = StubPortQueryService(responses: [])
        let service = PortQueryService(native: native, lsof: lsof)
        let first = Task { try await service.query() }
        try await started(native)
        let fresh = Task { try await service.query(policy: .fresh) }
        fresh.cancel()
        _ = try await first.value
        do { _ = try await fresh.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await lsof.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testCancellationDoesNotTriggerFallbackAndNextRefreshWorks() async throws {
        let native = GatedPortQueryService(snapshot: snapshot())
        let lsof = StubPortQueryService(responses: [])
        let service = PortQueryService(native: native, lsof: lsof)
        let first = Task { try await service.query() }
        while await native.callCount() == 0 { await Task.yield() }
        await service.cancelCurrentQuery()
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let nextQuery = Task { try await service.query() }
        while await native.callCount() < 2 { await Task.yield() }
        await native.release()
        let next = try await nextQuery.value
        XCTAssertFalse(next.isPartial)
        let calls = await lsof.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testNewQueryWaitsForPreviousBackendCancellationCleanup() async throws {
        let native = CleanupGatedPortQueryService()
        let service = PortQueryService(native: native, lsof: StubPortQueryService(responses: []))
        let first = Task { try await service.query() }
        while await native.callCount() == 0 { await Task.yield() }
        let cancellation = Task { await service.cancelCurrentQuery() }
        while !(await native.isCleaningUp()) { await Task.yield() }
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let next = Task { try await service.query() }
        try await Task.sleep(for: .milliseconds(20))
        let earlyCalls = await native.callCount()
        XCTAssertEqual(earlyCalls, 1)
        await native.finishCleanup()
        await cancellation.value
        _ = try await next.value
        let calls = await native.callCount()
        XCTAssertEqual(calls, 2)
    }

    func testCancellationReachesDetachedLsofWork() async throws {
        let runner = CancellableLsofRunner()
        let service = PortQueryService(native: StubPortQueryService(responses: []),
            lsof: LsofService(executableURL: URL(fileURLWithPath: "/usr/bin/true"), runner: runner))
        let query = Task { try await service.query(policy: .fresh) }
        while !(await runner.isActive()) { await Task.yield() }
        await service.cancelCurrentQuery()
        do { _ = try await query.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let active = await runner.isActive()
        XCTAssertFalse(active)
    }

    private func started(_ service: StubPortQueryService) async throws {
        for _ in 0..<100 {
            if await service.callCount() > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Query did not start")
    }
}
