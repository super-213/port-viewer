import Darwin
import Foundation
import XCTest
@testable import PortViewer

actor ScriptedCommandRunner: LocalCommandRunning {
    struct Call: Equatable { let executable: String; let arguments: [String] }
    private var responses: [Data]
    private(set) var calls: [Call] = []
    init(_ responses: [String]) { self.responses = responses.map { Data($0.utf8) } }
    func run(executable: String, arguments: [String], timeout: Duration) async throws -> Data {
        calls.append(Call(executable: executable, arguments: arguments))
        guard !responses.isEmpty else { throw ManagedServiceError.commandFailed }
        return responses.removeFirst()
    }
}

struct StubServiceProcessInspector: ServiceProcessInspecting {
    let identities: [Int32: ProcessIdentity]
    let paths: [Int32: String]
    let ancestors: [Int32: [ProcessIdentity]]
    func identity(for pid: Int32) -> ProcessIdentity? { identities[pid] }
    func executablePath(for pid: Int32) -> String? { paths[pid] }
    func ancestry(for pid: Int32) -> [ProcessIdentity] { ancestors[pid] ?? [] }
}

final class ManagedServiceTests: XCTestCase {
    private let containerID = String(repeating: "a", count: 64)
    private let docker = "/usr/local/bin/docker"
    private let socket = "/var/run/docker.sock"

    private func inspection(start: String = "first", running: Bool = true) -> String {
        """
        [{"Id":"\(containerID)","Name":"/shop-db","State":{"Running":\(running),"StartedAt":"\(start)"},
        "NetworkSettings":{"Ports":{"5432/tcp":[{"HostIp":"127.0.0.1","HostPort":"15432"}],"9999/tcp":null,"53/udp":[{"HostIp":"::","HostPort":"1053"}]}}}]
        """
    }

    private func record() throws -> PortRecord {
        var record = PortTestFixtures.record(processName: "com.docker.backend", pid: ProcessInfo.processInfo.processIdentifier,
                                            localPort: 15432, executablePath: "/Applications/Docker.app/Contents/MacOS/com.docker.backend")
        record.context.identity = try XCTUnwrap(ProcessMetadataResolver.identity(for: record.pid))
        return record
    }

    func testDockerUsesPublishedHostPortProtocolAddressAndKnownForwarder() throws {
        let containers = try ManagedServiceController.parseContainers(Data(inspection().utf8), executable: docker, socket: socket)
        let container = try XCTUnwrap(containers.first)
        XCTAssertEqual(container.service.name, "shop-db")
        XCTAssertEqual(container.bindings.count, 2)
        XCTAssertTrue(ManagedServiceController.matches(try record(), container: container))
        XCTAssertFalse(ManagedServiceController.matches(PortTestFixtures.record(localPort: 15432), container: container))
        XCTAssertFalse(ManagedServiceController.matches(PortTestFixtures.record(processName: "com.docker.backend", localPort: 5432), container: container))
        XCTAssertFalse(ManagedServiceController.matches(PortTestFixtures.record(processName: "com.docker.backend", transport: .udp, localPort: 15432), container: container))
        XCTAssertFalse(ManagedServiceController.matches(PortTestFixtures.record(processName: "com.docker.backend", localAddress: "192.168.1.1", localPort: 15432), container: container))
    }

    func testDockerStopRechecksGenerationUsesFullIDAndVerifiesStopped() async throws {
        // Exact expected sequence: ps, inspect, stop, ps. Four scripted outputs.
        let exactRunner = ScriptedCommandRunner([containerID, inspection(), containerID, ""])
        let controller = ManagedServiceController(runner: exactRunner, tools: .init(docker: docker, dockerSocket: socket))
        let service = try XCTUnwrap(ManagedServiceController.parseContainers(Data(inspection().utf8), executable: docker, socket: socket).first?.service)
        try await controller.stop(service, for: record())
        let calls = await exactRunner.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[2].arguments, ["--host", "unix://" + socket, "stop", "--timeout", "10", containerID])
        XCTAssertFalse(calls.contains { $0.executable == "/bin/kill" })
    }

    func testDockerRestartDuringConfirmationRejectsStop() async throws {
        let runner = ScriptedCommandRunner([containerID, inspection(start: "restarted")])
        let controller = ManagedServiceController(runner: runner, tools: .init(docker: docker, dockerSocket: socket))
        let service = try XCTUnwrap(ManagedServiceController.parseContainers(Data(inspection().utf8), executable: docker, socket: socket).first?.service)
        do {
            try await controller.stop(service, for: record())
            XCTFail("A restarted container must require a new confirmation")
        } catch { XCTAssertEqual(error as? ManagedServiceError, .changed) }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls.contains { $0.arguments.contains("stop") })
    }

    func testUnavailableIntegrationClearsCachedOwnershipWithoutDiscardingPorts() async throws {
        let runner = ScriptedCommandRunner([containerID, inspection()])
        let controller = ManagedServiceController(runner: runner, tools: .init(docker: docker, dockerSocket: socket))
        let original = try record()
        let first = await controller.enrich([original], forceRefresh: true)
        XCTAssertEqual(first.first?.context.managedService?.name, "shop-db")
        let failed = await controller.enrich(first, forceRefresh: true)
        XCTAssertEqual(failed.count, 1)
        XCTAssertNil(failed.first?.context.managedService)
    }

    func testBrewOnlyParsesRunningJobsAndChecksFormulaInstallationBoundary() {
        let data = Data("PID\tStatus\tLabel\n123\t0\thomebrew.mxcl.postgresql@16\n-\t0\thomebrew.mxcl.redis\n789\t0\tcom.example.server\n".utf8)
        let jobs = ManagedServiceController.launchdJobs(data)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.formula, "postgresql@16")
        XCTAssertFalse(ManagedServiceController.validFormula("--all"))
        XCTAssertFalse(ManagedServiceController.validFormula("redis;echo unsafe"))
        let service = ManagedService(kind: .homebrew, target: "postgresql@16", name: "postgresql@16", executable: "/opt/homebrew/bin/brew", endpoint: "/opt/homebrew", generation: "1")
        XCTAssertTrue(ManagedServiceController.isBrewExecutable("/opt/homebrew/Cellar/postgresql@16/16.0/bin/postgres", service: service))
        XCTAssertFalse(ManagedServiceController.isBrewExecutable("/opt/homebrew/Cellar/postgresql@160/16.0/bin/postgres", service: service))
        XCTAssertFalse(ManagedServiceController.isBrewExecutable("/usr/local/Cellar/postgresql@16/16.0/bin/postgres", service: service))
    }

    func testHomebrewChildMapsToOwningJobAndStopsThroughBrew() async throws {
        let parent = ProcessIdentity(pid: 200, userID: getuid(), startSeconds: 10, startMicroseconds: 2)
        let child = ProcessIdentity(pid: 201, userID: getuid(), startSeconds: 11, startMicroseconds: 3)
        let path = "/opt/homebrew/Cellar/postgresql@16/16.0/bin/postgres"
        let inspector = StubServiceProcessInspector(identities: [200: parent, 201: child], paths: [200: path], ancestors: [201: [child, parent]])
        let listing = "PID\tStatus\tLabel\n200\t0\thomebrew.mxcl.postgresql@16\n"
        let runner = ScriptedCommandRunner([listing, listing, "Successfully stopped", "PID\tStatus\tLabel\n"])
        let controller = ManagedServiceController(runner: runner, tools: .init(brew: ["/opt/homebrew/bin/brew"]), processes: inspector)
        var record = PortTestFixtures.record(processName: "postgres", pid: 201, executablePath: path)
        record.context.identity = child
        let enriched = await controller.enrich([record], forceRefresh: true)
        let service = try XCTUnwrap(enriched.first?.context.managedService)
        XCTAssertEqual(service.kind, .homebrew)
        XCTAssertEqual(service.target, "postgresql@16")
        try await controller.stop(service, for: record)
        let calls = await runner.calls
        XCTAssertEqual(calls[2], .init(executable: "/opt/homebrew/bin/brew", arguments: ["services", "stop", "postgresql@16", "--max-wait=10"]))
        XCTAssertEqual(calls.last?.arguments, ["list"])
    }

    func testHomebrewRejectsSameFormulaWithRestartedLaunchdJob() async throws {
        let identity = ProcessIdentity(pid: 200, userID: getuid(), startSeconds: 20, startMicroseconds: 2)
        let path = "/opt/homebrew/Cellar/redis/7.0/bin/redis-server"
        let inspector = StubServiceProcessInspector(identities: [200: identity], paths: [200: path], ancestors: [200: [identity]])
        let runner = ScriptedCommandRunner(["200\t0\thomebrew.mxcl.redis\n"])
        let controller = ManagedServiceController(runner: runner, tools: .init(brew: ["/opt/homebrew/bin/brew"]), processes: inspector)
        var record = PortTestFixtures.record(processName: "redis-server", pid: 200, executablePath: path)
        record.context.identity = identity
        let service = ManagedService(kind: .homebrew, target: "redis", name: "redis", executable: "/opt/homebrew/bin/brew", endpoint: "/opt/homebrew", generation: "200:10:2")
        do { try await controller.stop(service, for: record); XCTFail("Restarted launchd job must be rejected") }
        catch { XCTAssertEqual(error as? ManagedServiceError, .changed) }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testAmbiguousDockerOwnershipDoesNotOfferStop() async throws {
        let json = inspection()
        let other = json.replacingOccurrences(of: containerID, with: String(repeating: "b", count: 64))
        let combined = String(json.dropLast()) + "," + String(other.dropFirst())
        let runner = ScriptedCommandRunner([containerID, combined])
        let controller = ManagedServiceController(runner: runner, tools: .init(docker: docker, dockerSocket: socket))
        let records = await controller.enrich([try record()], forceRefresh: true)
        XCTAssertNil(records.first?.context.managedService)
        XCTAssertTrue(ProcessProtectionPolicy.isSharedServiceHost(try record()))
    }
}
