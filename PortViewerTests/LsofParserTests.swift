import XCTest
@testable import PortViewer

final class LsofParserTests: XCTestCase {
    func testParsesProcessesFilesAndIPv6Endpoints() throws {
        let data = nulSeparated([
            "p123", "cnode", "u501", "Ltester", "R42",
            "\nf12", "tIPv4", "PTCP", "n*:3000", "TST=LISTEN",
            "\nf13", "tIPv6", "PTCP", "n[::1]:3000->[::1]:51000", "TST=ESTABLISHED",
            "\np456", "cpython", "u502", "Lother",
            "\nf7", "tIPv4", "PUDP", "n127.0.0.1:5353"
        ])

        let records = LsofParser().parse(data, timestamp: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].processName, "node")
        XCTAssertEqual(records[0].pid, 123)
        XCTAssertEqual(records[0].localAddress, "*")
        XCTAssertEqual(records[0].localPort, 3000)
        XCTAssertEqual(records[0].state, "LISTEN")
        XCTAssertEqual(records[0].parentPID, 42)
        XCTAssertTrue(records[0].isListening)

        XCTAssertEqual(records[1].ipVersion, .v6)
        XCTAssertEqual(records[1].localEndpoint, "[::1]:3000")
        XCTAssertEqual(records[1].remoteEndpoint, "[::1]:51000")
        XCTAssertTrue(records[1].isActiveConnection)

        XCTAssertEqual(records[2].transport, .udp)
        XCTAssertEqual(records[2].statusDisplay, "—")
        XCTAssertEqual(records[2].user, "other")
        XCTAssertEqual(Set(records.map(\.id)).count, 3)
    }

    func testParserIgnoresUnknownAndIncompleteFields() {
        let data = nulSeparated([
            "p100", "ctool", "Ltester", "zunknown",
            "\nf1", "tIPv4", "PTCP", // No name: ignored.
            "\nf2", "tIPv4", "PUDP", "n*:9000", "Xfuture"
        ])

        let records = LsofParser().parse(data)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].fileDescriptor, "2")
        XCTAssertEqual(records[0].localPort, 9000)
    }

    func testEndpointParserHandlesWildcardIPv4AndIPv6() {
        XCTAssertEqual(LsofParser.parseEndpoint("*:8080"), .init(address: "*", port: 8080))
        XCTAssertEqual(LsofParser.parseEndpoint("127.0.0.1:443"), .init(address: "127.0.0.1", port: 443))
        XCTAssertEqual(LsofParser.parseEndpoint("[fe80::1]:22"), .init(address: "fe80::1", port: 22))
        XCTAssertEqual(LsofParser.parseEndpoint("*:*"), .init(address: "*", port: nil))
    }

    private func nulSeparated(_ fields: [String]) -> Data {
        Data((fields.joined(separator: "\0") + "\0").utf8)
    }
}
