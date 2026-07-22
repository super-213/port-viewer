import XCTest
@testable import PortViewer

@MainActor
final class PageViewModelTests: XCTestCase {
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
}
