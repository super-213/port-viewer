import XCTest
@testable import PortViewer

final class LsofClientIntegrationTests: XCTestCase {
    func testReadsARealLsofSnapshotWithinTimeout() async throws {
        let snapshot = try await LsofClient().query()

        XCTAssertLessThan(snapshot.duration, 5.5)
        XCTAssertFalse(snapshot.records.isEmpty, "The test Mac should expose at least one TCP or UDP record")
        XCTAssertTrue(snapshot.records.allSatisfy { $0.transport == .tcp || $0.transport == .udp })
        XCTAssertTrue(snapshot.records.allSatisfy { !$0.processName.isEmpty })
    }
}
