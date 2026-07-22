import Darwin
import XCTest
@testable import PortViewer

@MainActor
final class PortViewModelTests: XCTestCase {
    func testRefreshMapsSuccessEmptyPartialFailureAndUnavailableWithoutDiscardingGoodData() async {
        let record = PortTestFixtures.record()
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: [record])),
            .failure(.executionFailed(2)),
            .snapshot(PortTestFixtures.snapshot(records: [], capturedAt: Date(timeIntervalSince1970: 200))),
            .snapshot(PortTestFixtures.snapshot(records: [record], isPartial: true)),
            .failure(.unavailable)
        ])
        let viewModel = PortTestFixtures.viewModel(queryService: query)

        await viewModel.refreshForTesting()
        XCTAssertEqual(viewModel.records, [record])
        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(viewModel.lastSuccessfulUpdate, Date(timeIntervalSince1970: 100))

        await viewModel.refreshForTesting()
        XCTAssertEqual(viewModel.records, [record], "失败时必须保留上一份快照")
        XCTAssertEqual(viewModel.state, .failed("lsof 查询失败（退出代码 2）。"))

        await viewModel.refreshForTesting()
        XCTAssertTrue(viewModel.records.isEmpty)
        XCTAssertEqual(viewModel.state, .empty)
        XCTAssertEqual(viewModel.lastSuccessfulUpdate, Date(timeIntervalSince1970: 200))

        await viewModel.refreshForTesting()
        XCTAssertEqual(viewModel.state, .partial("lsof 返回了部分结果；已展示可安全解析的数据。"))
        XCTAssertEqual(viewModel.lastSuccessfulUpdate, Date(timeIntervalSince1970: 200), "部分结果不是成功基线")

        await viewModel.refreshForTesting()
        XCTAssertEqual(viewModel.records, [record])
        XCTAssertEqual(viewModel.state, .unavailable("找不到系统工具 /usr/sbin/lsof。请确认 macOS 系统文件完整后重试。"))
    }

    func testRepeatedManualRefreshQueuesAtMostOneFollowUp() async {
        let snapshot = PortTestFixtures.snapshot(records: [PortTestFixtures.record()])
        let query = StubPortQueryService(
            responses: [.snapshot(snapshot), .snapshot(snapshot)],
            delay: .milliseconds(30)
        )
        let viewModel = PortTestFixtures.viewModel(queryService: query)

        viewModel.refreshNow()
        viewModel.refreshNow()
        viewModel.refreshNow()
        await viewModel.waitForManualRefreshForTesting()

        let callCount = await query.callCount()
        XCTAssertEqual(callCount, 2)
        XCTAssertFalse(viewModel.isRefreshing)
    }

    func testEquivalentSnapshotOnlyAdvancesTimestampAndKeepsStableRecords() async {
        let original = PortTestFixtures.record(updatedAt: Date(timeIntervalSince1970: 100))
        let equivalent = PortTestFixtures.record(updatedAt: Date(timeIntervalSince1970: 200))
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(
                records: [original],
                capturedAt: Date(timeIntervalSince1970: 100)
            )),
            .snapshot(PortTestFixtures.snapshot(
                records: [equivalent],
                capturedAt: Date(timeIntervalSince1970: 200)
            ))
        ])
        let viewModel = PortTestFixtures.viewModel(queryService: query)

        await viewModel.refreshForTesting()
        await viewModel.refreshForTesting()

        XCTAssertEqual(viewModel.records.first?.updatedAt, original.updatedAt)
        XCTAssertEqual(viewModel.lastSuccessfulUpdate, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(viewModel.listeningCount, 1)
        XCTAssertEqual(viewModel.activeConnectionCount, 0)
        XCTAssertEqual(viewModel.otherNetworkActivityCount, 0)
    }

    func testPauseRemovesAutomaticTimerAndResumeRestoresIt() async {
        let now = Date()
        let snapshot = PortTestFixtures.snapshot(
            records: [PortTestFixtures.record(updatedAt: now)],
            capturedAt: now
        )
        let query = StubPortQueryService(responses: [
            .snapshot(snapshot),
            .snapshot(snapshot)
        ])
        let viewModel = PortTestFixtures.viewModel(queryService: query)

        viewModel.setMainWindowVisible(true)
        viewModel.start()
        await viewModel.waitForManualRefreshForTesting()
        XCTAssertTrue(viewModel.hasScheduledAutomaticRefreshForTesting)

        viewModel.togglePause()
        XCTAssertFalse(viewModel.hasScheduledAutomaticRefreshForTesting)

        viewModel.togglePause()
        await viewModel.waitForManualRefreshForTesting()
        XCTAssertTrue(viewModel.hasScheduledAutomaticRefreshForTesting)
        viewModel.stop()
    }

    func testPauseAndResumePreserveStateAndResumeWithRefresh() async {
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: [PortTestFixtures.record()]))
        ])
        let viewModel = PortTestFixtures.viewModel(queryService: query)

        viewModel.togglePause()
        XCTAssertTrue(viewModel.isPaused)
        XCTAssertEqual(viewModel.state, .paused)

        viewModel.togglePause()
        await viewModel.waitForManualRefreshForTesting()
        XCTAssertFalse(viewModel.isPaused)
        XCTAssertEqual(viewModel.state, .ready)
        let callCount = await query.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testListenerActivityChangesExpireAndPartialSnapshotsDoNotInventChanges() async {
        let listener = PortTestFixtures.record()
        let connection = PortTestFixtures.record(
            fileDescriptor: "11",
            localPort: 3_000,
            remoteAddress: "10.0.0.2",
            remotePort: 50_000,
            state: "ESTABLISHED"
        )
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: [listener, connection], capturedAt: Date(timeIntervalSince1970: 100))),
            .snapshot(PortTestFixtures.snapshot(records: [listener], capturedAt: Date(timeIntervalSince1970: 101), isPartial: true)),
            .snapshot(PortTestFixtures.snapshot(records: [listener], capturedAt: Date(timeIntervalSince1970: 102))),
            .snapshot(PortTestFixtures.snapshot(records: [listener], capturedAt: Date(timeIntervalSince1970: 108)))
        ])
        let viewModel = PortTestFixtures.viewModel(queryService: query)

        await viewModel.refreshForTesting()
        await viewModel.refreshForTesting()
        XCTAssertTrue(viewModel.recentListenerActivity.isEmpty)

        await viewModel.refreshForTesting()
        XCTAssertEqual(viewModel.recentListenerActivity.values.first?.kind, .ended(1))

        await viewModel.refreshForTesting()
        XCTAssertTrue(viewModel.recentListenerActivity.isEmpty)
    }

    func testTerminationPreparationRejectsOtherUserAndPartialSafetySnapshot() async {
        let otherUserRecord = PortTestFixtures.record(user: "another-user")
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: [PortTestFixtures.record()], isPartial: true))
        ])
        let viewModel = PortTestFixtures.viewModel(queryService: query)

        viewModel.prepareToTerminate(otherUserRecord)
        await viewModel.waitForTerminationTaskForTesting()
        XCTAssertTrue(viewModel.feedback?.message.contains("无法结束其他用户的进程") == true)
        let rejectedCallCount = await query.callCount()
        XCTAssertEqual(rejectedCallCount, 0)

        viewModel.prepareToTerminate(PortTestFixtures.record())
        await viewModel.waitForTerminationTaskForTesting()
        XCTAssertNil(viewModel.terminationPrompt)
        XCTAssertEqual(viewModel.feedback?.message, "最新查询结果不完整，无法安全校验进程与端口的关联。请重试。")
        let policies = await query.policies()
        XCTAssertEqual(policies, [.fresh])
    }

    func testTerminationPreparationUsesFreshSnapshotAndReportsDisappearedRecord() async {
        let target = PortTestFixtures.record()
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: []))
        ])
        let viewModel = PortTestFixtures.viewModel(
            queryService: query,
            processService: StubProcessService(processExists: false)
        )

        viewModel.prepareToTerminate(target)
        await viewModel.waitForTerminationTaskForTesting()

        XCTAssertNil(viewModel.terminationPrompt)
        XCTAssertEqual(viewModel.feedback?.message, "进程已在操作前自行退出，未发送任何信号。")
        let policies = await query.policies()
        XCTAssertEqual(policies, [.fresh])
    }

    func testTerminationPreparationReportsPortMigrationWithoutSendingSignal() async {
        let target = PortTestFixtures.record()
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: []))
        ])
        let viewModel = PortTestFixtures.viewModel(
            queryService: query,
            processService: StubProcessService(processExists: true)
        )

        viewModel.prepareToTerminate(target)
        await viewModel.waitForTerminationTaskForTesting()

        XCTAssertEqual(viewModel.feedback?.message, "该进程已不再占用所选端口，未发送任何信号。")
        XCTAssertNil(viewModel.terminationPrompt)
    }

    func testSIGTERMSuccessReportsReleasedPort() async throws {
        let target = PortTestFixtures.record()
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: [target])),
            .snapshot(PortTestFixtures.snapshot(records: []))
        ])
        let viewModel = PortTestFixtures.viewModel(queryService: query)

        viewModel.prepareToTerminate(target)
        await viewModel.waitForTerminationTaskForTesting()
        let prompt = try XCTUnwrap(viewModel.terminationPrompt)
        viewModel.confirmTermination(prompt)
        await viewModel.waitForTerminationTaskForTesting()

        XCTAssertEqual(viewModel.feedback?.kind, .success)
        XCTAssertEqual(viewModel.feedback?.message, "TCP 端口 3000 已释放。")
        let policies = await query.policies()
        XCTAssertEqual(policies, [.fresh, .fresh])
    }

    func testSignalErrorStopsBeforePostSignalQuery() async throws {
        let target = PortTestFixtures.record()
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: [target]))
        ])
        let viewModel = PortTestFixtures.viewModel(
            queryService: query,
            processService: StubProcessService(signalError: .permissionDenied)
        )

        viewModel.prepareToTerminate(target)
        await viewModel.waitForTerminationTaskForTesting()
        let prompt = try XCTUnwrap(viewModel.terminationPrompt)
        viewModel.confirmTermination(prompt)
        await viewModel.waitForTerminationTaskForTesting()

        XCTAssertEqual(viewModel.feedback?.kind, .error)
        XCTAssertEqual(viewModel.feedback?.message, "权限不足，无法结束该进程。当前版本不申请管理员权限。")
        let policies = await query.policies()
        XCTAssertEqual(policies, [.fresh])
    }

    func testSIGTERMPersistsThenOffersForceAndPostSignalQueryFailureNeverReportsSuccess() async throws {
        let target = PortTestFixtures.record()
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: [target])),
            .snapshot(PortTestFixtures.snapshot(records: [target])),
            .failure(.executionFailed(3))
        ])
        let viewModel = PortTestFixtures.viewModel(queryService: query)

        viewModel.prepareToTerminate(target)
        await viewModel.waitForTerminationTaskForTesting()
        let standardPrompt = try XCTUnwrap(viewModel.terminationPrompt)
        XCTAssertEqual(standardPrompt.stage, .standard)

        viewModel.confirmTermination(standardPrompt)
        await viewModel.waitForTerminationTaskForTesting()
        let forcePrompt = try XCTUnwrap(viewModel.terminationPrompt)
        XCTAssertEqual(forcePrompt.stage, .force)

        viewModel.confirmTermination(forcePrompt)
        await viewModel.waitForTerminationTaskForTesting()
        XCTAssertEqual(viewModel.feedback?.kind, .warning)
        XCTAssertTrue(viewModel.feedback?.message.contains("无法验证端口状态") == true)
        let policies = await query.policies()
        XCTAssertEqual(policies, [.fresh, .fresh, .fresh])
    }

    func testCriticalProcessCannotBeForceTerminated() async {
        let query = StubPortQueryService(responses: [])
        let viewModel = PortTestFixtures.viewModel(queryService: query)
        let critical = PortTestFixtures.record(processName: "launchd", pid: 1)
        let prompt = TerminationPrompt(
            stage: .force,
            record: critical,
            otherConnectionCount: 0,
            otherOccupants: [],
            isCritical: true
        )

        viewModel.confirmTermination(prompt)
        await viewModel.waitForTerminationTaskForTesting()

        XCTAssertEqual(viewModel.feedback?.kind, .error)
        XCTAssertTrue(viewModel.feedback?.message.contains("禁止强制结束") == true)
        let callCount = await query.callCount()
        XCTAssertEqual(callCount, 0)
    }
}
