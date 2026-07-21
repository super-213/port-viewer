import XCTest
@testable import PortViewer

final class NetworkPresentationTests: XCTestCase {
    func testFriendlyTCPStateMappingUsesChinesePrimaryText() {
        XCTAssertEqual(PortRecord.friendlyStatusTitle(for: "LISTEN"), "等待连接")
        XCTAssertEqual(PortRecord.friendlyStatusTitle(for: "ESTABLISHED"), "连接已建立")
        XCTAssertEqual(PortRecord.friendlyStatusTitle(for: "SYN_SENT"), "正在发起连接")
        XCTAssertEqual(PortRecord.friendlyStatusTitle(for: "TIME_WAIT"), "刚刚结束")
        XCTAssertEqual(PortRecord.friendlyStatusTitle(for: "FUTURE_STATE"), "其他状态")
        XCTAssertEqual(PortRecord.friendlyStatusTitle(for: nil, transport: .udp), "正在使用")
    }

    func testListenerAccessScopeMappingPreservesUncertainty() {
        XCTAssertEqual(makeRecord(address: "127.0.0.1").accessScope, .localOnly)
        XCTAssertEqual(makeRecord(address: "::1", ipVersion: .v6).accessScope, .localOnly)
        XCTAssertEqual(makeRecord(address: "*").accessScope, .networkPossible)
        XCTAssertEqual(makeRecord(address: "0.0.0.0").accessScope, .networkPossible)
        XCTAssertEqual(makeRecord(address: "192.168.1.20").accessScope, .networkPossible)
        XCTAssertEqual(makeRecord(address: "?").accessScope, .unknown)
        XCTAssertEqual(
            makeRecord(address: "*", state: nil, transport: .udp).accessScope,
            .unknown
        )
    }

    func testGroupingMergesEquivalentIPv4AndIPv6Listeners() throws {
        let ipv4 = makeRecord(address: "127.0.0.1", descriptor: "4", ipVersion: .v4)
        let ipv6 = makeRecord(address: "::1", descriptor: "5", ipVersion: .v6)

        let item = try XCTUnwrap(ReadablePortItem.group([ipv4, ipv6]).first)

        XCTAssertEqual(item.rawRecords.count, 2)
        XCTAssertEqual(item.containsTechnicalRecordText, "包含 2 条技术记录")
        XCTAssertEqual(item.accessScope, .localOnly)
        XCTAssertTrue(item.conclusion.contains("等待这台 Mac 上的应用连接"))
    }

    func testGroupingDoesNotMergeDifferentRemoteEndpointsOrAccessScopes() {
        let localListener = makeRecord(address: "127.0.0.1", descriptor: "4")
        let networkListener = makeRecord(address: "*", descriptor: "5")
        let firstRemote = makeRecord(
            address: "127.0.0.1",
            descriptor: "6",
            localPort: 53124,
            remoteAddress: "142.250.72.14",
            remotePort: 443,
            state: "ESTABLISHED"
        )
        let secondRemote = makeRecord(
            address: "127.0.0.1",
            descriptor: "7",
            localPort: 53124,
            remoteAddress: "1.1.1.1",
            remotePort: 443,
            state: "ESTABLISHED"
        )

        XCTAssertEqual(ReadablePortItem.group([localListener, networkListener]).count, 2)
        XCTAssertEqual(ReadablePortItem.group([firstRemote, secondRemote]).count, 2)
    }

    func testRawRecordIdentityRemainsStableWhenOnlyTCPStateChanges() {
        let establishing = makeRecord(
            address: "127.0.0.1",
            localPort: 53124,
            remoteAddress: "142.250.72.14",
            remotePort: 443,
            state: "SYN_SENT"
        )
        let established = makeRecord(
            address: "127.0.0.1",
            localPort: 53124,
            remoteAddress: "142.250.72.14",
            remotePort: 443,
            state: "ESTABLISHED"
        )

        XCTAssertEqual(establishing.id, established.id)
        XCTAssertNotEqual(
            ReadablePortItem.group([establishing])[0].id,
            ReadablePortItem.group([established])[0].id
        )
    }

    func testEstablishedAndUDPConclusionsDoNotOverstateDataTransfer() throws {
        let tcp = makeRecord(
            address: "127.0.0.1",
            localPort: 53124,
            remoteAddress: "142.250.72.14",
            remotePort: 443,
            state: "ESTABLISHED"
        )
        let udp = makeRecord(
            address: "*",
            localPort: 5353,
            state: nil,
            transport: .udp
        )

        let tcpItem = try XCTUnwrap(ReadablePortItem.group([tcp]).first)
        let udpItem = try XCTUnwrap(ReadablePortItem.group([udp]).first)

        XCTAssertEqual(tcpItem.friendlyStatusTitle, "连接已建立")
        XCTAssertTrue(tcpItem.meaningMessages[0].contains("不代表此刻一定在传输数据"))
        XCTAssertEqual(udpItem.friendlyStatusTitle, "正在使用")
        XCTAssertTrue(udpItem.conclusion.contains("无固定连接的数据"))
    }

    func testListenerActivitySnapshotReportsAppearedAndEndedConnections() throws {
        let listener = makeRecord(address: "127.0.0.1")
        let connection = makeRecord(
            address: "127.0.0.1",
            descriptor: "8",
            remoteAddress: "127.0.0.1",
            remotePort: 53124,
            state: "ESTABLISHED"
        )
        let observedAt = Date(timeIntervalSince1970: 20)
        let baseline = PortActivitySnapshot.capture(from: [listener])
        let active = PortActivitySnapshot.capture(from: [listener, connection])
        let key = try XCTUnwrap(ListenerActivityKey(listener: listener))

        XCTAssertEqual(
            active.changes(comparedTo: baseline, observedAt: observedAt)[key]?.kind,
            .appeared(1)
        )

        let item = try XCTUnwrap(ReadablePortItem.group([listener]).first)
        let summary = try XCTUnwrap(ListenerActivitySummary.make(
            for: item,
            snapshot: active,
            recentChanges: active.changes(comparedTo: baseline, observedAt: observedAt)
        ))
        XCTAssertEqual(summary.connectionCount, 1)
        XCTAssertEqual(summary.remoteEndpoints, ["127.0.0.1:53124"])
        XCTAssertEqual(summary.currentDescription, "当前有 1 条连接活动")
        XCTAssertEqual(summary.inlineDescription, "刚发现 1 条新连接 · 当前 1 条")

        XCTAssertEqual(
            baseline.changes(comparedTo: active, observedAt: observedAt)[key]?.kind,
            .ended(1)
        )
    }

    func testListenerActivityDoesNotTreatTCPStateChangeAsANewConnection() {
        let listener = makeRecord(address: "127.0.0.1")
        let establishing = makeRecord(
            address: "127.0.0.1",
            descriptor: "8",
            remoteAddress: "127.0.0.1",
            remotePort: 53124,
            state: "SYN_SENT"
        )
        let established = makeRecord(
            address: "127.0.0.1",
            descriptor: "8",
            remoteAddress: "127.0.0.1",
            remotePort: 53124,
            state: "ESTABLISHED"
        )
        let before = PortActivitySnapshot.capture(from: [listener, establishing])
        let after = PortActivitySnapshot.capture(from: [listener, established])

        XCTAssertTrue(after.changes(comparedTo: before, observedAt: Date()).isEmpty)
    }

    private func makeRecord(
        address: String,
        descriptor: String = "4",
        ipVersion: IPVersion = .v4,
        localPort: Int = 3000,
        remoteAddress: String? = nil,
        remotePort: Int? = nil,
        state: String? = "LISTEN",
        transport: TransportProtocol = .tcp
    ) -> PortRecord {
        PortRecord(
            processName: "node",
            pid: 123,
            user: NSUserName(),
            fileDescriptor: descriptor,
            ipVersion: ipVersion,
            transport: transport,
            localAddress: address,
            localPort: localPort,
            remoteAddress: remoteAddress,
            remotePort: remotePort,
            state: state,
            executablePath: nil,
            parentPID: 1,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }
}
