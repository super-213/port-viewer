import Darwin
import XCTest
@testable import PortViewer

final class ProcessContextTests: XCTestCase {
    func testProjectDiscoveryWalksToNearestManifestAndKeepsProjectsSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("shop/src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"name":"商城前端"}"#.utf8).write(to: root.appendingPathComponent("shop/package.json"))
        let project = try XCTUnwrap(ProjectResolver.resolve(workingDirectory: source.path))
        XCTAssertEqual(project.name, "商城前端")
        XCTAssertEqual(project.root, root.appendingPathComponent("shop").path)
        var first = PortTestFixtures.record()
        first.context.projectRoot = project.root
        first.context.projectName = project.name
        first.context.framework = "Vite"
        var second = PortTestFixtures.record(pid: 456, localPort: 5173)
        second.context.projectRoot = root.appendingPathComponent("admin").path
        XCTAssertEqual(ReadablePortItem.group([first, second]).count, 2)
        XCTAssertEqual(first.displayName, "商城前端 · Vite")
        XCTAssertEqual(PortSearch.rank(of: first, query: "商城"), 0)
        XCTAssertEqual(PortSearch.rank(of: first, query: "Vite"), 0)
        XCTAssertEqual(PortSearch.rank(of: first, query: "node"), 0)
    }

    func testArgumentsStopAtArgcAndDoNotIncludeEnvironment() {
        var argc: Int32 = 3
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(Data("/usr/bin/node\0\0node\0vite\0--host\0SECRET_TOKEN=private\0".utf8))
        XCTAssertEqual(ProcessMetadataResolver.parseArguments(data), ["node", "vite", "--host"])
        XCTAssertEqual(ProcessMetadataResolver.parseArguments(Data([1, 2])), [])
        XCTAssertEqual(ProcessMetadataResolver.redacted(["node", "--token", "secret", "--password=value", "vite"]),
                       ["node", "--token", "••••", "--password=••••", "vite"])
    }

    func testFrameworkNeedsExecutableEvidenceAndDoesNotGuessFromPort() {
        XCTAssertEqual(ProjectResolver.framework(arguments: ["node", "/shop/node_modules/vite/bin/vite.js"], processName: "node"), "Vite")
        XCTAssertEqual(ProjectResolver.framework(arguments: ["python", "manage.py", "runserver"], processName: "python"), "Django")
        XCTAssertNil(ProjectResolver.framework(arguments: ["node", "app.js", "--port", "5173"], processName: "node"))
    }

    func testLiveIdentityAndWrongStartTimeAreRejectedWithoutKillingProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["20"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let current = try XCTUnwrap(ProcessMetadataResolver.identity(for: child.processIdentifier))
        let reused = ProcessIdentity(pid: current.pid, userID: current.userID,
                                     startSeconds: current.startSeconds + 1, startMicroseconds: current.startMicroseconds)
        XCTAssertThrowsError(try ProcessService().send(signal: SIGTERM, to: current.pid, expectedIdentity: reused)) {
            XCTAssertEqual($0 as? ProcessSignalError, .identityChanged)
        }
        XCTAssertTrue(child.isRunning)
        try ProcessService().send(signal: 0, to: current.pid, expectedIdentity: current)
    }
}

final class SignalRecorder: ProcessControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32] = []
    func send(signal: Int32, to pid: Int32, expectedIdentity: ProcessIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        values.append(signal)
    }
    func exists(pid: Int32) -> Bool { true }
    var signals: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

@MainActor
final class ProcessIdentitySafetyTests: XCTestCase {
    func testBothTerminationStagesRejectPIDReusedDuringConfirmation() async {
        for stage in [TerminationPrompt.Stage.standard, .force] {
            let original = PortTestFixtures.record()
            var replacement = original
            replacement.context.identity = ProcessIdentity(pid: original.pid, userID: getuid(), startSeconds: 999, startMicroseconds: 0)
            let query = StubPortQueryService(responses: [.snapshot(PortTestFixtures.snapshot(records: [replacement]))])
            let signals = SignalRecorder()
            let vm = PortViewModel(queryService: query, processService: signals)
            vm.confirmTermination(TerminationPrompt(stage: stage, record: original, otherConnectionCount: 0, otherOccupants: [], isCritical: false))
            await vm.waitForTerminationTaskForTesting()
            XCTAssertTrue(signals.signals.isEmpty)
            XCTAssertEqual(vm.feedback?.kind, .error)
        }
    }

    func testConfirmationRejectsPartialSnapshotAndMissingIdentity() async {
        var unknown = PortTestFixtures.record()
        unknown.context.identity = nil
        for snapshot in [PortTestFixtures.snapshot(records: [PortTestFixtures.record()], isPartial: true),
                         PortTestFixtures.snapshot(records: [unknown])] {
            let query = StubPortQueryService(responses: [.snapshot(snapshot)])
            let signals = SignalRecorder()
            let vm = PortViewModel(queryService: query, processService: signals)
            vm.confirmTermination(TerminationPrompt(stage: .standard, record: PortTestFixtures.record(), otherConnectionCount: 0, otherOccupants: [], isCritical: false))
            await vm.waitForTerminationTaskForTesting()
            XCTAssertTrue(signals.signals.isEmpty)
            XCTAssertEqual(vm.feedback?.kind, .error)
        }
    }

    func testManagedServiceNeverFallsBackToKillingSharedPIDWhenContextIsLost() async {
        var original = PortTestFixtures.record(processName: "com.docker.backend")
        original.context.managedService = ManagedService(kind: .docker, target: String(repeating: "a", count: 64), name: "web",
                                                       executable: "/usr/local/bin/docker", endpoint: "/var/run/docker.sock", generation: "first")
        var replacement = original
        replacement.context.managedService = nil
        let query = StubPortQueryService(responses: [.snapshot(PortTestFixtures.snapshot(records: [replacement]))])
        let signals = SignalRecorder()
        let vm = PortViewModel(queryService: query, processService: signals, serviceContexts: StubManagedServices())
        vm.confirmTermination(TerminationPrompt(stage: .standard, record: original, otherConnectionCount: 0, otherOccupants: [], isCritical: false))
        await vm.waitForTerminationTaskForTesting()
        XCTAssertTrue(signals.signals.isEmpty)
        XCTAssertEqual(vm.feedback?.kind, .error)
    }

    func testManagedStopUsesServiceControllerAndVerifiesPortWithoutSignals() async {
        for kind in [ManagedService.Kind.docker, .homebrew] {
            var record = PortTestFixtures.record()
            let service = ManagedService(kind: kind, target: "service", name: "shop", executable: "/tool", endpoint: "/local", generation: "first")
            record.context.managedService = service
            let snapshot = PortTestFixtures.snapshot(records: [record])
            let query = StubPortQueryService(responses: [.snapshot(snapshot), .snapshot(snapshot), .snapshot(PortTestFixtures.snapshot(records: []))])
            let signals = SignalRecorder()
            let services = StubManagedServices()
            let vm = PortViewModel(queryService: query, processService: signals, serviceContexts: services)
            vm.prepareToTerminate(record)
            await vm.waitForTerminationTaskForTesting()
            guard let prompt = vm.terminationPrompt else { XCTFail("Expected service confirmation"); continue }
            XCTAssertEqual(prompt.service, service)
            vm.confirmTermination(prompt)
            await vm.waitForTerminationTaskForTesting()
            let stops = await services.stops
            XCTAssertEqual(stops, [service])
            XCTAssertTrue(signals.signals.isEmpty)
            XCTAssertEqual(vm.feedback?.kind, .success)
        }
    }
}

actor StubManagedServices: ServiceContextProviding {
    private(set) var stops: [ManagedService] = []
    func enrich(_ records: [PortRecord], forceRefresh: Bool) async -> [PortRecord] { records }
    func stop(_ service: ManagedService, for record: PortRecord) async throws { stops.append(service) }
}
