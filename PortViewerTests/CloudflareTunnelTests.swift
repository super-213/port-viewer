import Foundation
import XCTest
@testable import PortViewer

private enum TunnelFixtures {
    // Same response structure observed from cloudflared; synthetic hostnames only.
    static let config = Data(#"{"version":5,"config":{"ingress":[{"hostname":"home.example.com","path":null,"service":"http://127.0.0.1:8080","Handlers":null,"originRequest":{}},{"hostname":"jupyter.example.com","service":"http://127.0.0.1:9173"},{"hostname":"ip.example.com","service":"http://127.0.0.1:9001"},{"hostname":"","service":"http_status:404"}],"warp-routing":{}}}"#.utf8)
    static let ready = Data(#"{"status":200,"readyConnections":4,"connectorId":"test-connector"}"#.utf8)
    static let endpoint = "http://127.0.0.1:20241"

    static func route(host: String = "app.example.com", service: String = "http://127.0.0.1:3000") -> TunnelRoute {
        TunnelRoute(hostname: host, path: nil, service: service, order: 0, shadowed: false)
    }
}

private actor FakeTunnelHTTP: TunnelHTTPReading {
    var calls: [URL] = []
    var fails = false
    let delay: Duration

    init(delay: Duration = .zero) { self.delay = delay }
    func setFailure(_ value: Bool) { fails = value }
    func count() -> Int { calls.count }
    func get(_ url: URL) async throws -> TunnelHTTPResponse {
        calls.append(url)
        try await Task.sleep(for: delay)
        if fails { throw URLError(.timedOut) }
        switch url.lastPathComponent {
        case "ready": return .init(status: 200, data: TunnelFixtures.ready)
        case "config": return .init(status: 200, data: TunnelFixtures.config)
        default: return .init(status: 200, data: Data(#"{"hostname":""}"#.utf8))
        }
    }
}

private struct FakeTunnelInspector: TunnelProcessInspecting {
    var current: ProcessIdentity?
    var additional: [ProcessIdentity] = []
    func identity(for pid: Int32) -> ProcessIdentity? {
        ([current].compactMap { $0 } + additional).first { $0.pid == pid }
    }
    func owns(endpoint: URL, identity: ProcessIdentity) -> Bool { self.identity(for: identity.pid) == identity }
}

private struct InconclusiveIdentityInspector: TunnelProcessInspecting {
    func identity(for pid: Int32) -> ProcessIdentity? { nil }
    func owns(endpoint: URL, identity: ProcessIdentity) -> Bool { true }
}

final class TunnelParsingTests: XCTestCase {
    func testObservedNamedTunnelShapeParsesWithoutQuickHostname() throws {
        let (version, routes) = try TunnelParser.configuration(TunnelFixtures.config, quickHostname: nil)
        XCTAssertEqual(version, 5)
        XCTAssertEqual(routes.map(\.port), [8080, 9173, 9001])
        XCTAssertEqual(routes.map(\.hostname), ["home.example.com", "jupyter.example.com", "ip.example.com"])
        XCTAssertNil(try TunnelParser.quickHostname(Data(#"{"hostname":""}"#.utf8)))
    }

    func testQuickTunnelCombinesHostnameWithUnnamedOrigin() throws {
        let config = Data(#"{"config":{"ingress":[{"service":"http://localhost:3000"}]}}"#.utf8)
        let (_, routes) = try TunnelParser.configuration(config, quickHostname: "test.trycloudflare.com")
        XCTAssertEqual(routes.first?.hostname, "test.trycloudflare.com")
        XCTAssertEqual(routes.first?.port, 3000)
        XCTAssertTrue(try TunnelParser.configuration(config, quickHostname: nil).1.isEmpty)
    }

    func testReadinessRequiresConsistentHTTPAndBody() throws {
        XCTAssertEqual(try TunnelParser.readiness(TunnelFixtures.ready, httpStatus: 200).0, .connected)
        let down = Data(#"{"status":503,"readyConnections":0}"#.utf8)
        XCTAssertEqual(try TunnelParser.readiness(down, httpStatus: 503).0, .disconnected)
        XCTAssertThrowsError(try TunnelParser.readiness(TunnelFixtures.ready, httpStatus: 503))
        XCTAssertThrowsError(try TunnelParser.readiness(Data(#"{"status":200,"readyConnections":0}"#.utf8), httpStatus: 200))
        XCTAssertThrowsError(try TunnelParser.configuration(Data("{}".utf8), quickHostname: nil))
    }

    func testFirstMatchingRuleShadowsLaterOriginAndCatchAllIsNotAnAssociation() throws {
        let config = Data(#"{"config":{"ingress":[{"hostname":"app.example.com","service":"http_status:403"},{"hostname":"app.example.com","service":"http://localhost:3000"},{"hostname":"other.example.com","path":"/api/.*","service":"http://localhost:4000"},{"service":"http_status:404"}]}}"#.utf8)
        let routes = try TunnelParser.configuration(config, quickHostname: nil).1
        XCTAssertEqual(routes.count, 2)
        XCTAssertTrue(routes[0].shadowed)
        XCTAssertFalse(routes[1].shadowed)
        XCTAssertNil(routes[1].browserURL, "A path regex must not be opened as a literal URL")
    }

    func testSensitiveURLsAndNonHTTPServicesAreExcluded() throws {
        let config = Data(#"{"config":{"ingress":[{"hostname":"app.example.com","service":"http://user:secret@localhost:3000"},{"hostname":"app.example.com","service":"http://localhost:3000?token=secret"},{"hostname":"app.example.com","service":"unix:/tmp/app.sock"}]}}"#.utf8)
        XCTAssertTrue(try TunnelParser.configuration(config, quickHostname: nil).1.isEmpty)
        XCTAssertFalse(TunnelRoute.validHostname("bad.example.com/path"))
        XCTAssertFalse(TunnelRoute.validHostname("app..example.com"))
        XCTAssertTrue(TunnelRoute.validHostname("*.example.com"))
        XCTAssertNil(TunnelFixtures.route(host: "*.example.com").browserURL)
    }

    func testMatchingUsesAddressFamilyAndIgnoresOutboundConnections() {
        let ipv4 = PortTestFixtures.record()
        XCTAssertTrue(TunnelMatching.matches(TunnelFixtures.route(), record: ipv4))
        XCTAssertFalse(TunnelMatching.matches(TunnelFixtures.route(service: "http://[::1]:3000"), record: ipv4))
        XCTAssertFalse(TunnelMatching.matches(TunnelFixtures.route(service: "http://remote.example.com:3000"), record: ipv4))
        XCTAssertFalse(TunnelMatching.matches(TunnelFixtures.route(), record: PortTestFixtures.record(state: "ESTABLISHED")))
        XCTAssertFalse(TunnelMatching.matches(TunnelFixtures.route(), record: PortTestFixtures.record(localAddress: "192.168.1.2")))
        let ipv6 = PortTestFixtures.record(ipVersion: .v6, localAddress: "::")
        XCTAssertTrue(TunnelMatching.matches(TunnelFixtures.route(service: "http://[::1]:3000"), record: ipv6))
        XCTAssertTrue(TunnelMatching.matches(TunnelFixtures.route(service: "http://localhost:3000"), record: ipv6))
        XCTAssertEqual(TunnelFixtures.route(service: "https://localhost").port, 443)
    }

    func testAssociationsCoverAllGroupedPortsAndBecomeStale() throws {
        let date = Date(timeIntervalSince1970: 100)
        let routes = try TunnelParser.configuration(TunnelFixtures.config, quickHostname: nil).1
        let connector = TunnelConnector(endpoint: URL(string: TunnelFixtures.endpoint)!, identity: nil,
                                        routes: routes, state: .connected, observedAt: date, routesObservedAt: date)
        let snapshot = TunnelSnapshot(connectors: [connector], capturedAt: date)
        let records = [8080, 9173, 9001].map { PortTestFixtures.record(localPort: $0) }
        let fresh = snapshot.associations(for: records, at: date, maximumAge: 60)
        XCTAssertEqual(fresh.count, 3)
        XCTAssertTrue(fresh.allSatisfy { !$0.stale })
        XCTAssertTrue(snapshot.associations(for: records, at: date.addingTimeInterval(61), maximumAge: 60).allSatisfy(\.stale))
    }

    func testManualEndpointsAreLiteralLoopbackOnlyAndCanonicalized() {
        XCTAssertEqual(CloudflareTunnelService.localEndpoint(TunnelFixtures.endpoint + "/")?.absoluteString, TunnelFixtures.endpoint)
        XCTAssertNotNil(CloudflareTunnelService.localEndpoint("http://[::1]:20241"))
        for text in ["http://example.com:20241", "http://127.0.0.1", "https://127.0.0.1:20241",
                     "http://127.0.0.1:20241/config", "http://user:pass@127.0.0.1:20241", "http://127.0.0.1:20241?token=x"] {
            XCTAssertNil(CloudflareTunnelService.localEndpoint(text), text)
        }
    }
}

final class TunnelDiscoveryTests: XCTestCase {
    func testManualEndpointStillReadsWhenAutomaticCandidateOwnershipCannotBeVerified() async throws {
        let record = PortTestFixtures.record(processName: "cloudflared", localPort: 20241,
                                             executablePath: "/opt/homebrew/bin/cloudflared")
        let http = FakeTunnelHTTP()
        let service = CloudflareTunnelService(http: http, inspector: FakeTunnelInspector(current: nil))
        let snapshot = try await service.discover(records: [record], isPartial: false,
                                                 manualEndpoint: TunnelFixtures.endpoint, force: true, interval: 5)
        XCTAssertEqual(snapshot.connectors.count, 1)
        XCTAssertNil(snapshot.connectors.first?.identity)
        XCTAssertEqual(snapshot.connectors.first?.routes.count, 3)
        XCTAssertEqual(snapshot.connectors.first?.state, .connected)
    }

    func testPartialSnapshotAndUnreadableIdentityPreserveMappingsAsUnknown() async throws {
        let record = PortTestFixtures.record(processName: "cloudflared", localPort: 20241,
                                             executablePath: "/opt/homebrew/bin/cloudflared")
        let service = CloudflareTunnelService(http: FakeTunnelHTTP(), inspector: InconclusiveIdentityInspector())
        _ = try await service.discover(records: [record], isPartial: false, manualEndpoint: "", force: true, interval: 5)
        let partial = try await service.discover(records: [], isPartial: true, manualEndpoint: "", force: false, interval: 5)
        XCTAssertEqual(partial.connectors.first?.routes.count, 3)
        XCTAssertEqual(partial.connectors.first?.state, .unknown)
        XCTAssertNotNil(partial.connectors.first?.issue)
    }

    func testRoundBudgetLimitsProbesAndEventuallyVisitsRemainingConnectors() async throws {
        let http = FakeTunnelHTTP()
        let records = (0..<5).map {
            PortTestFixtures.record(processName: "cloudflared", pid: Int32(200 + $0), localPort: 20241 + $0,
                                    executablePath: "/opt/homebrew/bin/cloudflared")
        }
        let inspector = FakeTunnelInspector(current: nil, additional: records.compactMap(\.context.identity))
        let service = CloudflareTunnelService(http: http, inspector: inspector)
        let first = try await service.discover(records: records, isPartial: false, manualEndpoint: "", force: false, interval: 30)
        XCTAssertEqual(first.connectors.count, 4)
        let count = await http.count()
        XCTAssertEqual(count, 12)
        let second = try await service.discover(records: records, isPartial: false, manualEndpoint: "", force: false, interval: 30)
        XCTAssertEqual(second.connectors.count, 5)
        let total = await http.count()
        XCTAssertEqual(total, 15)
    }

    func testNoCandidateMakesNoNetworkRequests() async throws {
        let http = FakeTunnelHTTP()
        let service = CloudflareTunnelService(http: http)
        let snapshot = try await service.discover(records: [PortTestFixtures.record()], isPartial: false,
                                                 manualEndpoint: "", force: false, interval: 5)
        XCTAssertTrue(snapshot.connectors.isEmpty)
        let count = await http.count()
        XCTAssertEqual(count, 0)
    }

    func testManualDiscoveryWorksWithoutVisibleProcessAndUsesCache() async throws {
        let http = FakeTunnelHTTP()
        let service = CloudflareTunnelService(http: http)
        let first = try await service.discover(records: [], isPartial: false, manualEndpoint: TunnelFixtures.endpoint, force: false, interval: 5)
        XCTAssertEqual(first.connectors.first?.routes.count, 3)
        XCTAssertNil(first.connectors.first?.identity)
        XCTAssertEqual(first.connectors.first?.state, .connected)
        _ = try await service.discover(records: [], isPartial: false, manualEndpoint: TunnelFixtures.endpoint, force: false, interval: 5)
        let count = await http.count()
        XCTAssertEqual(count, 3)
    }

    func testFailedRefreshPreservesMappingsButDoesNotReportConnected() async throws {
        let http = FakeTunnelHTTP()
        let service = CloudflareTunnelService(http: http)
        _ = try await service.discover(records: [], isPartial: false, manualEndpoint: TunnelFixtures.endpoint, force: true, interval: 5)
        await http.setFailure(true)
        let second = try await service.discover(records: [], isPartial: false, manualEndpoint: TunnelFixtures.endpoint, force: true, interval: 5)
        XCTAssertEqual(second.connectors.first?.routes.count, 3)
        XCTAssertEqual(second.connectors.first?.state, .unknown)
        XCTAssertNotNil(second.connectors.first?.issue)
    }

    func testAutomaticDiscoveryValidatesProcessIdentityAndClearsOnExit() async throws {
        let http = FakeTunnelHTTP()
        let record = PortTestFixtures.record(processName: "cloudflared", localPort: 20241, executablePath: "/opt/homebrew/bin/cloudflared")
        let service = CloudflareTunnelService(http: http, inspector: FakeTunnelInspector(current: record.context.identity))
        let first = try await service.discover(records: [record], isPartial: false, manualEndpoint: "", force: true, interval: 5)
        XCTAssertEqual(first.connectors.first?.identity, record.context.identity)
        let partial = try await service.discover(records: [], isPartial: true, manualEndpoint: "", force: false, interval: 5)
        XCTAssertEqual(partial.connectors.count, 1)
        let complete = try await service.discover(records: [], isPartial: false, manualEndpoint: "", force: false, interval: 5)
        XCTAssertTrue(complete.connectors.isEmpty)

        let reused = CloudflareTunnelService(http: http, inspector: FakeTunnelInspector(current: nil))
        let rejected = try await reused.discover(records: [record], isPartial: false, manualEndpoint: "", force: true, interval: 5)
        XCTAssertTrue(rejected.connectors.isEmpty)
    }

    func testSingleFlightAndCancellationDoNotPublishPartialResults() async throws {
        let http = FakeTunnelHTTP(delay: .milliseconds(30))
        let service = CloudflareTunnelService(http: http)
        async let first = service.discover(records: [], isPartial: false, manualEndpoint: TunnelFixtures.endpoint, force: true, interval: 5)
        async let second = service.discover(records: [], isPartial: false, manualEndpoint: TunnelFixtures.endpoint, force: true, interval: 5)
        _ = try await (first, second)
        let count = await http.count()
        XCTAssertEqual(count, 3)

        let cancelled = Task {
            try await service.discover(records: [], isPartial: false, manualEndpoint: TunnelFixtures.endpoint, force: true, interval: 5)
        }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testInvalidManualEndpointNeverContactsRemoteHost() async throws {
        let http = FakeTunnelHTTP()
        let snapshot = try await CloudflareTunnelService(http: http).discover(
            records: [], isPartial: false, manualEndpoint: "http://example.com:20241", force: true, interval: 5)
        XCTAssertNotNil(snapshot.connectors.first?.issue)
        let count = await http.count()
        XCTAssertEqual(count, 0)
    }
}

@MainActor
final class TunnelViewModelTests: XCTestCase {
    func testDefaultEndpointDiscoversWithoutOpeningSettingsOrApplying() async throws {
        let suite = "PortViewerTests.TunnelDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = PortViewModel(
            queryService: StubPortQueryService(responses: [.snapshot(PortTestFixtures.snapshot(records: []))]),
            processService: StubProcessService(),
            tunnelService: CloudflareTunnelService(http: FakeTunnelHTTP()),
            userDefaults: defaults
        )

        XCTAssertEqual(root.tunnelEndpoint, TunnelFixtures.endpoint)
        await root.refreshForTesting()
        await root.waitForTunnelRefreshForTesting()
        XCTAssertEqual(root.tunnelSnapshot.connectors.first?.endpoint.absoluteString, TunnelFixtures.endpoint)
        XCTAssertEqual(root.tunnelSnapshot.connectors.first?.routes.count, 3)
        root.stop()
    }

    func testSavedEmptyEndpointUsesDefaultAndCustomEndpointIsPreserved() throws {
        let suite = "PortViewerTests.TunnelDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for endpoint in ["http://127.0.0.1:20245", "", " \n "] {
            defaults.set(endpoint, forKey: "cloudflareTunnelEndpoint")
            let root = PortViewModel(queryService: StubPortQueryService(responses: []),
                                     processService: StubProcessService(), userDefaults: defaults)
            let expected = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? TunnelFixtures.endpoint : endpoint
            XCTAssertEqual(root.tunnelEndpoint, expected)
        }
    }

    func testReapplyingSameEndpointRetriesEvenWhenPortQueriesFail() async throws {
        let http = FakeTunnelHTTP()
        await http.setFailure(true)
        let root = PortViewModel(queryService: StubPortQueryService(responses: [.failure(.unavailable)]),
                                 processService: StubProcessService(),
                                 tunnelService: CloudflareTunnelService(http: http))
        root.configureTunnels(enabled: true, endpoint: TunnelFixtures.endpoint, refresh: true)
        await root.waitForTunnelRefreshForTesting()
        XCTAssertEqual(root.tunnelSnapshot.connectors.first?.state, .unknown)
        await root.refreshForTesting()
        await http.setFailure(false)
        root.configureTunnels(enabled: true, endpoint: TunnelFixtures.endpoint, refresh: true)
        await root.waitForTunnelRefreshForTesting()
        XCTAssertEqual(root.tunnelSnapshot.connectors.first?.routes.count, 3)
        XCTAssertEqual(root.tunnelSnapshot.connectors.first?.state, .connected)
        let count = await http.count()
        XCTAssertEqual(count, 6)
        root.stop()
    }

    func testDomainsAreSearchableAcrossPagesAndDisablingInvalidatesCaches() async throws {
        let query = StubPortQueryService(responses: [.snapshot(PortTestFixtures.snapshot(records: [PortTestFixtures.record(localPort: 9001)]))])
        let service = CloudflareTunnelService(http: FakeTunnelHTTP())
        let root = PortViewModel(queryService: query, processService: StubProcessService(), tunnelService: service)
        root.configureTunnels(enabled: true, endpoint: TunnelFixtures.endpoint, refresh: true)
        await root.waitForTunnelRefreshForTesting()
        let main = MainWindowViewModel(portViewModel: root)
        let menu = MenuBarViewModel(portViewModel: root)
        main.searchText = "ip.example.com"
        menu.searchText = "ip.example.com"
        XCTAssertTrue(main.displayedItems.isEmpty)
        await root.refreshForTesting()
        await root.waitForTunnelRefreshForTesting()
        XCTAssertEqual(main.displayedItems.count, 1)
        XCTAssertEqual(menu.displayedRecords.count, 1)
        main.tunnelOnly = true
        XCTAssertEqual(main.displayedItems.count, 1)
        XCTAssertFalse(root.matchesTunnelSearch(root.records[0], query: ":9001"))
        root.configureTunnels(enabled: false, endpoint: "")
        XCTAssertTrue(main.displayedItems.isEmpty)
        XCTAssertTrue(menu.displayedRecords.isEmpty)
        root.stop()
    }

    func testDisabledDiscoveryRejectsLateResults() async throws {
        let root = PortViewModel(queryService: StubPortQueryService(responses: []), processService: StubProcessService(),
                                 tunnelService: CloudflareTunnelService(http: FakeTunnelHTTP(delay: .milliseconds(30))))
        root.configureTunnels(enabled: true, endpoint: TunnelFixtures.endpoint, refresh: true)
        root.configureTunnels(enabled: false, endpoint: "")
        await root.waitForTunnelRefreshForTesting()
        XCTAssertTrue(root.tunnelSnapshot.connectors.isEmpty)
        XCTAssertFalse(root.isCheckingTunnels)
    }
}

@MainActor
final class TunnelHTTPIntegrationTests: XCTestCase {
    func testRealLoopbackHTTPRejectsRedirectsOversizedBodiesAndTimeouts() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", #"""
import http.server, time
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/ready')
            self.end_headers()
        elif self.path == '/large':
            self.send_response(200)
            self.send_header('Content-Length', '1048577')
            self.end_headers()
            self.wfile.write(b'x' * 1048577)
        elif self.path == '/stream':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'x' * 1048577)
        elif self.path == '/slow':
            time.sleep(2)
            self.send_response(200)
            self.end_headers()
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":200,"readyConnections":4}')
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); try? pipe.fileHandleForReading.close() }
        var portText = ""
        for _ in 0..<8 {
            guard let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { break }
            let text = String(decoding: byte, as: UTF8.self)
            if text == "\n" { break }
            portText += text
        }
        let port = try XCTUnwrap(Int(portText))
        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let http = TunnelHTTPClient()
        let ready = try await http.get(endpoint.appendingPathComponent("ready"))
        XCTAssertEqual(try TunnelParser.readiness(ready.data, httpStatus: ready.status).1, 4)
        let redirect = try await http.get(endpoint.appendingPathComponent("redirect"))
        XCTAssertEqual(redirect.status, 302, "The client must not follow redirects")
        for path in ["large", "stream"] {
            do { _ = try await http.get(endpoint.appendingPathComponent(path)); XCTFail("Expected size limit") }
            catch TunnelDiscoveryError.responseTooLarge { }
        }
        let start = ContinuousClock.now
        do { _ = try await http.get(endpoint.appendingPathComponent("slow")); XCTFail("Expected timeout") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        XCTAssertLessThan(start.duration(to: .now).secondsValue, 1.8)
    }
}
