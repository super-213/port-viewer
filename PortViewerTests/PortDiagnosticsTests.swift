import XCTest
@testable import PortViewer

final class PortDiagnosticsTests: XCTestCase {
    private let containerID = String(repeating: "a", count: 64)
    private let docker = "/usr/local/bin/docker"
    private let socket = "/var/run/docker.sock"

    private func sample(_ records: [PortRecord], at time: TimeInterval, partial: Bool = false) -> PortSnapshot {
        PortTestFixtures.snapshot(records: records, capturedAt: Date(timeIntervalSince1970: time), isPartial: partial)
    }

    func testFirstSampleIsBaselineAndFileDescriptorChangesAreIgnored() {
        var history = PortEventHistory()
        history.observe(sample([PortTestFixtures.record(fileDescriptor: "10")], at: 100))
        history.observe(sample([PortTestFixtures.record(fileDescriptor: "20")], at: 103))
        XCTAssertTrue(history.events.isEmpty)
    }

    func testPIDReuseProducesOccupantChangeAndPreservesBothInstances() {
        var history = PortEventHistory()
        let original = PortTestFixtures.record()
        var replacement = original
        replacement.context.identity = ProcessIdentity(pid: original.pid, userID: 501, startSeconds: 105, startMicroseconds: 2)
        history.observe(sample([original], at: 100))
        history.observe(sample([replacement], at: 106))
        XCTAssertEqual(history.events.map(\.kind), [.occupantsChanged])
        XCTAssertEqual(history.archivedListeners.count, 2)
    }

    func testSharedListenersKeepEveryOccupantAndMetadataChangesDoNotCreateEvents() {
        var history = PortEventHistory()
        let first = PortTestFixtures.record(pid: 10)
        var enriched = first
        enriched.context.projectName = "project"
        let second = PortTestFixtures.record(pid: 20)
        history.observe(sample([first, second], at: 100))
        history.observe(sample([enriched, second], at: 103))
        XCTAssertTrue(history.events.isEmpty)
        history.observe(sample([second], at: 106))
        XCTAssertEqual(history.events.map(\.kind), [.occupantsChanged])
        XCTAssertTrue(history.events[0].summary.contains("10"))
        XCTAssertTrue(history.events[0].summary.contains("20"))
    }

    func testIPv6AndMultipleBindingsProduceAddressSetChange() {
        var history = PortEventHistory()
        let loopback = PortTestFixtures.record(ipVersion: .v6, localAddress: "::1")
        let wildcard = PortTestFixtures.record(ipVersion: .v6, localAddress: "::")
        history.observe(sample([loopback], at: 100))
        history.observe(sample([loopback, wildcard], at: 103))
        XCTAssertTrue(history.events.contains { $0.kind == .scopeChanged })
        XCTAssertFalse(history.events.contains { $0.kind == .disappeared })
    }

    func testPartialSampleAndLongGapResetContinuityWithoutFalseExitOrRestart() {
        var history = PortEventHistory()
        history.observe(sample([PortTestFixtures.record()], at: 100))
        history.observe(sample([], at: 103, partial: true))
        history.observe(sample([], at: 106, partial: true))
        history.observe(sample([PortTestFixtures.record(pid: 20)], at: 109))
        XCTAssertEqual(history.events.map(\.kind), [.interruption])
        history.observe(sample([], at: 400))
        XCTAssertEqual(history.events.map(\.kind), [.interruption, .interruption])
    }

    func testEventsAreBoundedAndArchiveStripsArguments() {
        var history = PortEventHistory()
        var record = PortTestFixtures.record()
        record.context.arguments = ["--token", "private-value"]
        history.observe(sample([record], at: 100))
        XCTAssertEqual(history.archivedListeners.first?.context.arguments, [])
        for index in 0..<1_100 {
            history.append(.init(observedAt: Date(timeIntervalSince1970: 101 + Double(index)), kind: .appeared,
                                 port: 3000, transport: .tcp, summary: "observation"))
        }
        XCTAssertEqual(history.events.count, 1_000)
        XCTAssertEqual(history.discardedEventCount, 100)
        history.observe(sample([], at: 4_000))
        XCTAssertTrue(history.archivedListeners.isEmpty)
        XCTAssertTrue(history.events.allSatisfy { $0.observedAt.timeIntervalSince1970 >= 2_200 })
    }

    @MainActor
    func testDisappearedPortRemainsSearchableAndSelectableThroughNormalViewModels() async throws {
        let query = StubPortQueryService(responses: [.snapshot(sample([PortTestFixtures.record()], at: 100)),
                                                     .snapshot(sample([], at: 103))])
        let root = PortTestFixtures.viewModel(queryService: query)
        let page = MainWindowViewModel(portViewModel: root)
        await root.refreshForTesting()
        await root.refreshForTesting()
        page.searchText = ":3000"
        let item = try XCTUnwrap(page.historicalItems.first)
        page.selectHistorical(item)
        XCTAssertTrue(page.selectionHasEnded)
        XCTAssertEqual(page.selectedItem?.localPort, 3000)
        XCTAssertEqual(root.eventHistory.events(for: item).map(\.kind), [.disappeared])
        page.searchText = ":5432"
        XCTAssertTrue(page.historicalItems.isEmpty)
    }

    @MainActor
    func testFailedRefreshAndPauseRecordOneInterruptionAndRebaseline() async {
        let record = PortTestFixtures.record(updatedAt: Date())
        let now = Date().timeIntervalSince1970
        let query = StubPortQueryService(responses: [.snapshot(sample([record], at: now)), .failure(.executionFailed(2)),
                                                     .snapshot(sample([], at: now + 1))])
        let root = PortTestFixtures.viewModel(queryService: query)
        await root.refreshForTesting()
        await root.refreshForTesting()
        root.togglePause()
        XCTAssertEqual(root.eventHistory.events.map(\.kind), [.interruption])
        await root.refreshForTesting()
        XCTAssertEqual(root.eventHistory.events.map(\.kind), [.interruption])
        root.stop()
    }

    private func inspection(extra: String = "", state: String = "\"Status\":\"running\",\"StartedAt\":\"first\"") -> String {
        """
        [{"Id":"\(containerID)","Name":"/database","State":{\(state)},
        "NetworkSettings":{"Ports":{"5432/tcp":[{"HostIp":"127.0.0.1","HostPort":"15432"}],"99/tcp":null}}\(extra)}]
        """
    }

    func testDockerStatusSeparatesLifecycleHealthAndPublishedContainerPort() throws {
        let json = inspection(extra: ",\"RestartCount\":3,\"Config\":{}")
        let status = try DockerContainerStatus.parse(Data(json.utf8), expectedID: containerID)
        XCTAssertEqual(status.lifecycle, "running")
        XCTAssertEqual(status.healthConfigured, false)
        XCTAssertNil(status.health)
        XCTAssertEqual(status.restartCount, 3)
        XCTAssertEqual(status.mappings.first?.hostPort, 15432)
        XCTAssertEqual(status.mappings.first?.containerPort, 5432)
    }

    func testDockerHealthAndUnknownOptionalFields() throws {
        let json = inspection(state: "\"Status\":\"restarting\",\"Health\":{\"Status\":\"unhealthy\"}")
        let status = try DockerContainerStatus.parse(Data(json.utf8), expectedID: containerID)
        XCTAssertEqual(status.health, "unhealthy")
        XCTAssertEqual(status.healthConfigured, true)
        XCTAssertNil(status.startedAt)
        let minimal = "[{\"Id\":\"\(containerID)\"}]"
        let missing = try DockerContainerStatus.parse(Data(minimal.utf8), expectedID: containerID)
        XCTAssertNil(missing.lifecycle)
        XCTAssertNil(missing.healthConfigured)
        XCTAssertTrue(missing.mappings.isEmpty)
        XCTAssertThrowsError(try DockerContainerStatus.parse(Data(minimal.utf8), expectedID: String(repeating: "b", count: 64)))
    }

    private var service: ManagedService {
        .init(kind: .docker, target: containerID, name: "database", executable: docker, endpoint: socket, generation: "first")
    }

    func testDockerReadsExactLocalIDAndCachesAcrossPublishedPorts() async throws {
        let runner = ScriptedCommandRunner([inspection()])
        let provider = DockerStatusService(runner: runner, tools: .init(docker: docker, dockerSocket: socket))
        let first = try await provider.status(for: service)
        let second = try await provider.status(for: service)
        XCTAssertEqual(first.observedAt, second.observedAt)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments, ["--host", "unix://" + socket, "inspect", "--type", "container", containerID])
    }

    func testDockerDistinguishesRemovedFromUnreadableAndKeepsOriginalID() async throws {
        let removedRunner = ScriptedCommandRunner(["unreadable", ""])
        let removedProvider = DockerStatusService(runner: removedRunner, tools: .init(docker: docker, dockerSocket: socket))
        let removed = try await removedProvider.status(for: service)
        XCTAssertEqual(removed.availability, .removed)
        let calls = await removedRunner.calls
        XCTAssertEqual(calls.last?.arguments, ["--host", "unix://" + socket, "ps", "--all", "--quiet", "--no-trunc"])
        let unavailableProvider = DockerStatusService(runner: ScriptedCommandRunner([]), tools: .init(docker: docker, dockerSocket: socket))
        let unavailable = try await unavailableProvider.status(for: service)
        XCTAssertEqual(unavailable.availability, .unavailable)
    }

    func testDockerRejectsChangedSocketBeforeExecuting() async {
        let runner = ScriptedCommandRunner([])
        let provider = DockerStatusService(runner: runner, tools: .init(docker: docker, dockerSocket: "/another.sock"))
        do {
            _ = try await provider.status(for: service)
            XCTFail("Changed local socket must be rejected")
        } catch { XCTAssertEqual(error as? ManagedServiceError, .changed) }
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }
    @MainActor
    func testDockerGenerationEventsAndFailureKeepLastKnownStateThroughSelectionEntryPoint() async throws {
        let firstDate = Date()
        let first = try DockerContainerStatus.parse(Data(inspection().utf8), expectedID: containerID)
        let restarted = try DockerContainerStatus.parse(Data(inspection(state: "\"Status\":\"running\",\"StartedAt\":\"second\"").utf8), expectedID: containerID)
        let provider = QueueDockerStatusProvider(snapshots: [
            .init(serviceID: service.id, observedAt: firstDate, availability: .available, container: first),
            .init(serviceID: service.id, observedAt: firstDate.addingTimeInterval(1), availability: .available, container: restarted),
            .init(serviceID: service.id, observedAt: firstDate.addingTimeInterval(2), availability: .unavailable, container: nil)
        ])
        let root = PortViewModel(queryService: StubPortQueryService(responses: []), processService: StubProcessService(),
                                 dockerService: provider)
        defer { root.stop() }
        func item(generation: String) -> ReadablePortItem {
            var record = PortTestFixtures.record()
            record.context.managedService = .init(kind: .docker, target: containerID, name: "database", executable: docker,
                                                  endpoint: socket, generation: generation)
            return ReadablePortItem(id: "container", rawRecords: [record])
        }
        root.inspectDocker(for: item(generation: "first"))
        for _ in 0..<100 {
            if root.dockerStatus?.observedAt == firstDate { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(root.dockerStatus?.container?.startedAt, "first")
        root.inspectDocker(for: item(generation: "second"))
        for _ in 0..<100 {
            if root.dockerStatus?.observedAt == firstDate.addingTimeInterval(1) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(root.eventHistory.events.map(\.kind), [.containerChanged])
        root.inspectDocker(for: item(generation: "third"))
        for _ in 0..<100 {
            if root.dockerStatus?.availability == .unavailable { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(root.dockerStatus?.availability, .unavailable)
        XCTAssertEqual(root.dockerLastKnownStatus?.container?.startedAt, "second")
        XCTAssertEqual(root.eventHistory.events.count, 1)
        root.inspectDocker(for: nil)
        XCTAssertNil(root.dockerStatus)
    }

}


private actor QueueDockerStatusProvider: DockerStatusQuerying {
    private var snapshots: [DockerStatusSnapshot]
    init(snapshots: [DockerStatusSnapshot]) { self.snapshots = snapshots }
    func status(for service: ManagedService) async throws -> DockerStatusSnapshot {
        guard !snapshots.isEmpty else { throw ManagedServiceError.commandFailed }
        return snapshots.removeFirst()
    }
}
