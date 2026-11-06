import XCTest
@testable import PortViewer

@MainActor
final class PageViewModelTests: XCTestCase {
    func testServiceRowsCollapseAcceptedConnectionsAndKeepConnectionFiltersAndSelection() async throws {
        let listener = PortTestFixtures.record(processName: "redis", pid: 10, localPort: 6379)
        let accepted = PortTestFixtures.record(processName: "redis", pid: 10, fileDescriptor: "11", localPort: 6379,
                                               remoteAddress: "127.0.0.1", remotePort: 54410, state: "ESTABLISHED")
        let records = [listener, accepted]
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: records)),
            .snapshot(PortTestFixtures.snapshot(records: records)),
            .snapshot(PortTestFixtures.snapshot(records: [listener]))
        ])
        let root = PortTestFixtures.viewModel(queryService: query)
        let viewModel = MainWindowViewModel(portViewModel: root)
        await root.refreshForTesting()
        viewModel.scope = .all
        let service = try XCTUnwrap(viewModel.displayedItems.first)
        XCTAssertEqual(viewModel.displayedItems.count, 1)
        XCTAssertEqual(viewModel.count(for: .all), 1)
        XCTAssertEqual(viewModel.count(for: .waiting), 1)
        XCTAssertEqual(viewModel.count(for: .connections), 1)
        XCTAssertEqual(viewModel.overviewSnapshot.itemCount, 1)
        let child = try XCTUnwrap(service.connectionChildren.first)
        viewModel.select(child)
        XCTAssertEqual(viewModel.selectedItem?.id, child.id)
        await root.refreshForTesting()
        viewModel.reconcileSelectionAfterRefresh()
        XCTAssertFalse(viewModel.selectionHasEnded)
        XCTAssertEqual(viewModel.selectedItem?.id, child.id)

        viewModel.searchText = "54410"
        XCTAssertEqual(viewModel.displayedItems.map(\.id), [service.id])
        viewModel.searchText = ""
        viewModel.scope = .connections
        XCTAssertEqual(viewModel.displayedItems.count, 1)
        XCTAssertEqual(viewModel.displayedItems.first?.serviceName, "redis")
        viewModel.connectionPhaseFilter = .transitioning
        XCTAssertTrue(viewModel.displayedItems.isEmpty)
        viewModel.scope = .waiting
        XCTAssertEqual(viewModel.displayedItems.map(\.id), [service.id])
        await root.refreshForTesting()
        viewModel.reconcileSelectionAfterRefresh()
        XCTAssertTrue(viewModel.selectionHasEnded)
        XCTAssertEqual(viewModel.displayedItems.first?.serviceConnections.count, 0)
    }

    func testMainWindowSearchFiltersAndSortsFromSharedSnapshot() async {
        let node = PortTestFixtures.record(processName: "node", pid: 10, localPort: 3_000)
        let postgres = PortTestFixtures.record(processName: "postgres", pid: 20, transport: .tcp, localAddress: "*", localPort: 5432)
        let udp = PortTestFixtures.record(processName: "mDNSResponder", pid: 30, transport: .udp, localAddress: "*", localPort: 5353, state: nil)
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: [postgres, udp, node]))
        ])
        let root = PortTestFixtures.viewModel(queryService: query)
        let viewModel = MainWindowViewModel(portViewModel: root)
        await root.refreshForTesting()

        viewModel.scope = .all
        XCTAssertEqual(viewModel.displayedItems.map(\.localPort), [3_000, 5_353, 5_432])

        viewModel.searchText = "node"
        viewModel.protocolFilter = .tcp
        viewModel.ownerFilter = .current
        XCTAssertEqual(viewModel.displayedItems.map(\.representative.processName), ["node"])

        viewModel.searchText = ""
        viewModel.protocolFilter = .udp
        XCTAssertEqual(viewModel.displayedItems.map(\.representative.processName), ["mDNSResponder"])
    }

    func testSelectionSurvivesRefreshThenShowsExpiredItemAndReplacementOccupant() async throws {
        let original = PortTestFixtures.record(processName: "node", pid: 10, localPort: 3_000)
        let replacement = PortTestFixtures.record(processName: "python", pid: 11, localPort: 3_000)
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: [original])),
            .snapshot(PortTestFixtures.snapshot(records: [original.withExecutablePath("/opt/node")])),
            .snapshot(PortTestFixtures.snapshot(records: [replacement]))
        ])
        let root = PortTestFixtures.viewModel(queryService: query)
        let viewModel = MainWindowViewModel(portViewModel: root)

        await root.refreshForTesting()
        let item = try XCTUnwrap(viewModel.allItems.first)
        viewModel.select(item)

        await root.refreshForTesting()
        viewModel.reconcileSelectionAfterRefresh()
        XCTAssertFalse(viewModel.selectionHasEnded)
        XCTAssertNotNil(viewModel.selectedItem)

        await root.refreshForTesting()
        viewModel.reconcileSelectionAfterRefresh()
        XCTAssertTrue(viewModel.selectionHasEnded)
        XCTAssertEqual(viewModel.selectedItem?.representative.processName, "node")
        XCTAssertEqual(viewModel.replacementItem?.representative.processName, "python")
    }

    func testMenuBarHasIndependentSearchAndCapsSharedListenersAtTen() async {
        let records = (1...12).map { index in
            PortTestFixtures.record(
                processName: index == 12 ? "special-server" : "server-\(index)",
                pid: Int32(index),
                localPort: 2_000 + index
            )
        }
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: records))
        ])
        let root = PortTestFixtures.viewModel(queryService: query)
        let main = MainWindowViewModel(portViewModel: root)
        let menu = MenuBarViewModel(portViewModel: root)
        await root.refreshForTesting()

        XCTAssertEqual(menu.displayedRecords.count, 10)
        menu.searchText = "special"
        XCTAssertEqual(menu.displayedRecords.map(\.processName), ["special-server"])
        XCTAssertEqual(main.searchText, "", "页面级搜索状态必须互相独立")
    }

    func testOverviewSnapshotBuildsDashboardBreakdownsAndProcessRanking() async {
        let localListener = PortTestFixtures.record(processName: "node", pid: 10, localPort: 3_000)
        let connection = PortTestFixtures.record(
            processName: "node",
            pid: 10,
            fileDescriptor: "11",
            localPort: 51_000,
            remoteAddress: "10.0.0.8",
            remotePort: 443,
            state: "ESTABLISHED"
        )
        let networkListener = PortTestFixtures.record(
            processName: "postgres",
            pid: 20,
            localAddress: "*",
            localPort: 5_432
        )
        let udp = PortTestFixtures.record(
            processName: "mDNSResponder",
            pid: 30,
            fileDescriptor: "12",
            ipVersion: .v6,
            transport: .udp,
            localAddress: "*",
            localPort: 5_353,
            state: nil
        )
        let query = StubPortQueryService(responses: [
            .snapshot(PortTestFixtures.snapshot(records: [localListener, connection, networkListener, udp]))
        ])
        let root = PortTestFixtures.viewModel(queryService: query)
        let viewModel = MainWindowViewModel(portViewModel: root)

        await root.refreshForTesting()
        let overview = viewModel.overviewSnapshot

        XCTAssertEqual(overview.recordCount, 4)
        XCTAssertEqual(overview.waitingCount, 2)
        XCTAssertEqual(overview.connectionCount, 1)
        XCTAssertEqual(overview.networkPossibleCount, 1)
        XCTAssertEqual(overview.protocolBreakdown.first { $0.kind == .udp }?.count, 1)
        XCTAssertEqual(overview.ipBreakdown.first { $0.kind == .ipv6 }?.count, 1)
        XCTAssertEqual(overview.accessBreakdown.first { $0.kind == .localOnly }?.count, 1)
        XCTAssertEqual(overview.accessBreakdown.first { $0.kind == .networkPossible }?.count, 1)
        XCTAssertEqual(overview.topProcesses.first?.processName, "node")
        XCTAssertEqual(overview.topProcesses.first?.recordCount, 2)
    }
}
