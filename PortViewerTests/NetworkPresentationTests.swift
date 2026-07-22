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

    func testMultipleListenerPortsBecomeOneServiceActivityWithinTheSameScope() throws {
        let first = makeRecord(address: "127.0.0.1", descriptor: "4", localPort: 3_000)
        let second = makeRecord(address: "127.0.0.1", descriptor: "5", localPort: 8_080)

        let items = ReadablePortItem.group([first, second])
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.localPorts, [3_000, 8_080])
        XCTAssertEqual(item.localPortText, "2 个")
        XCTAssertEqual(item.localPortRelationshipText, "2 个服务端口")
        XCTAssertEqual(item.activitySummaryText, "2 个服务端口")
        XCTAssertEqual(item.topologyKind, .multipleServicePorts)
        XCTAssertTrue(item.conclusion.contains("通过 2 个服务端口"))
        XCTAssertTrue(item.meaningMessages.contains { $0.contains("端口数量本身不代表异常") })
    }

    func testSharedListenerAcrossProcessesBecomesOneExpandableServiceGroup() throws {
        let workerA = makeRecord(address: "*", descriptor: "4", pid: 843, localPort: 8_080)
        let workerB = makeRecord(address: "*", descriptor: "5", pid: 939, localPort: 8_080)

        let items = ReadablePortItem.group([workerA, workerB])
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.localPorts, [8_080])
        XCTAssertEqual(item.processCount, 2)
        XCTAssertEqual(item.processSummaries.map(\.pid), [843, 939])
        XCTAssertEqual(item.processSummaries.map(\.recordCount), [1, 1])
    }

    func testGroupingKeepsListenerScopesSeparateAndSummarizesConnectionsByProcess() throws {
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
        let connectionItem = try XCTUnwrap(ReadablePortItem.group([firstRemote, secondRemote]).first)
        XCTAssertEqual(ReadablePortItem.group([firstRemote, secondRemote]).count, 1)
        XCTAssertEqual(connectionItem.connectionCount, 2)
        XCTAssertEqual(connectionItem.remoteTargetCount, 2)
        XCTAssertEqual(connectionItem.localPorts, [53_124])
        XCTAssertEqual(connectionItem.activitySummaryText, "2 条连接 · 2 个目标")
        XCTAssertEqual(connectionItem.topologyKind, .onePortToMultipleTargets)
        XCTAssertTrue(connectionItem.conclusion.contains("共同使用本机端口 53124"))
        XCTAssertTrue(connectionItem.meaningMessages.contains { $0.contains("相同端口不代表同一连接") })
    }

    func testMultipleLocalPortsToOneTargetBecomeOneReadableActivity() throws {
        let first = makeRecord(
            address: "192.168.1.10",
            descriptor: "6",
            localPort: 50_490,
            remoteAddress: "198.18.0.4",
            remotePort: 443,
            state: "ESTABLISHED"
        )
        let second = makeRecord(
            address: "192.168.1.10",
            descriptor: "7",
            localPort: 50_578,
            remoteAddress: "198.18.0.4",
            remotePort: 443,
            state: "ESTABLISHED"
        )

        let item = try XCTUnwrap(ReadablePortItem.group([first, second]).first)

        XCTAssertEqual(item.connectionCount, 2)
        XCTAssertEqual(item.remoteEndpoints, ["198.18.0.4:443"])
        XCTAssertEqual(item.localPorts, [50_490, 50_578])
        XCTAssertEqual(item.localPortText, "2 个")
        XCTAssertEqual(item.connectionDisplay, "连接到 198.18.0.4:443 · 2 条")
        XCTAssertEqual(item.topologyKind, .multiplePortsToOneTarget)
        XCTAssertTrue(item.conclusion.contains("使用 2 个本机连接端口"))
        XCTAssertTrue(item.meaningMessages.contains { $0.contains("不是对外开放的服务") })
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

    func testListenerActivitySummaryCombinesConnectionsAcrossGroupedServicePorts() throws {
        let firstListener = makeRecord(address: "127.0.0.1", descriptor: "4", localPort: 3_000)
        let secondListener = makeRecord(address: "127.0.0.1", descriptor: "5", localPort: 8_080)
        let firstConnection = makeRecord(
            address: "127.0.0.1",
            descriptor: "6",
            localPort: 3_000,
            remoteAddress: "127.0.0.1",
            remotePort: 50_001,
            state: "ESTABLISHED"
        )
        let secondConnection = makeRecord(
            address: "127.0.0.1",
            descriptor: "7",
            localPort: 8_080,
            remoteAddress: "127.0.0.1",
            remotePort: 50_002,
            state: "ESTABLISHED"
        )
        let item = try XCTUnwrap(ReadablePortItem.group([firstListener, secondListener]).first)
        let snapshot = PortActivitySnapshot.capture(from: [firstListener, secondListener, firstConnection, secondConnection])
        let summary = try XCTUnwrap(ListenerActivitySummary.make(for: item, snapshot: snapshot, recentChanges: [:]))

        XCTAssertEqual(summary.connectionCount, 2)
        XCTAssertEqual(summary.remoteEndpoints, ["127.0.0.1:50001", "127.0.0.1:50002"])
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
        pid: Int32 = 123,
        ipVersion: IPVersion = .v4,
        localPort: Int = 3000,
        remoteAddress: String? = nil,
        remotePort: Int? = nil,
        state: String? = "LISTEN",
        transport: TransportProtocol = .tcp
    ) -> PortRecord {
        PortRecord(
            processName: "node",
            pid: pid,
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
