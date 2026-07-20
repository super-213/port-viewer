import XCTest
@testable import PortViewer

final class PortSearchTests: XCTestCase {
    func testColonSearchOnlyMatchesExactPort() {
        let record = makeRecord(name: "node3000", pid: 3000, port: 8080)

        XCTAssertNil(PortSearch.rank(of: record, query: ":3000"))
        XCTAssertEqual(PortSearch.rank(of: record, query: ":8080"), 0)
    }

    func testNumericExactMatchesRankBeforePartialMatches() {
        let exactPort = makeRecord(name: "node", pid: 99, port: 3000)
        let exactPID = makeRecord(name: "python", pid: 3000, port: 9000)
        let partial = makeRecord(name: "java", pid: 13000, port: 8080)

        XCTAssertEqual(PortSearch.rank(of: exactPort, query: "3000"), 0)
        XCTAssertEqual(PortSearch.rank(of: exactPID, query: "3000"), 0)
        XCTAssertEqual(PortSearch.rank(of: partial, query: "3000"), 1)
    }

    func testProcessNameSearchIsCaseInsensitive() {
        let record = makeRecord(name: "Postgres", pid: 12, port: 5432)
        XCTAssertEqual(PortSearch.rank(of: record, query: "POST"), 0)
        XCTAssertNil(PortSearch.rank(of: record, query: "node"))
    }

    private func makeRecord(name: String, pid: Int32, port: Int) -> PortRecord {
        PortRecord(
            processName: name,
            pid: pid,
            user: "tester",
            fileDescriptor: "1",
            ipVersion: .v4,
            transport: .tcp,
            localAddress: "*",
            localPort: port,
            remoteAddress: nil,
            remotePort: nil,
            state: "LISTEN",
            executablePath: nil,
            parentPID: nil,
            updatedAt: Date()
        )
    }
}
