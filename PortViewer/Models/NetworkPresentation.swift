import Foundation

enum NetworkActivityKind: String, CaseIterable, Identifiable, Sendable {
    case waiting = "等待连接"
    case connected = "连接已建立"
    case transitioning = "正在建立/关闭"
    case other = "其他网络活动"

    var id: Self { self }
}

struct PortMapBucket: Identifiable, Hashable, Sendable {
    let index: Int
    let lowerBound: Int
    let upperBound: Int
    let items: [ReadablePortItem]
    let ports: [Int]

    var id: Int { index }
    var rangeDescription: String { "\(lowerBound)–\(upperBound)" }
}

enum PortMapLayout {
    static let bucketCount = 128
    static let portCapacity = 65_536
    static let bucketSize = portCapacity / bucketCount

    static func bucketIndex(for port: Int) -> Int? {
        guard (0..<portCapacity).contains(port) else { return nil }
        return port / bucketSize
    }

    static func buckets(for items: [ReadablePortItem]) -> [PortMapBucket] {
        var assignments = Array(repeating: [ReadablePortItem](), count: bucketCount)

        for item in items {
            let indices = Set(item.localPorts.compactMap(bucketIndex(for:)))
            for index in indices {
                assignments[index].append(item)
            }
        }

        return assignments.enumerated().map { index, bucketItems in
            let lowerBound = index * bucketSize
            let upperBound = min(((index + 1) * bucketSize) - 1, portCapacity - 1)
            let sortedItems = bucketItems.sorted {
                if $0.localPortSortValue != $1.localPortSortValue {
                    return $0.localPortSortValue < $1.localPortSortValue
                }
                return $0.processSortValue < $1.processSortValue
            }
            return PortMapBucket(
                index: index,
                lowerBound: lowerBound,
                upperBound: upperBound,
                items: sortedItems,
                ports: Array(Set(sortedItems.flatMap(\.localPorts).filter { lowerBound...upperBound ~= $0 })).sorted()
            )
        }
    }
}

enum ActivityTopologyKind: String, Sendable {
    case single
    case multipleServicePorts
    case multiplePortsToOneTarget
    case onePortToMultipleTargets
    case multiplePortsToMultipleTargets
}

struct ProcessUsageSummary: Identifiable, Hashable, Sendable {
    let pid: Int32
    let processName: String
    let recordCount: Int

    var id: Int32 { pid }
}

enum NetworkAccessScope: String, CaseIterable, Identifiable, Sendable {
    case localOnly = "仅这台 Mac"
    case networkPossible = "可能被其他设备访问"
    case unknown = "访问范围暂不确定"

    var id: Self { self }

    var explanation: String {
        switch self {
        case .localOnly:
            return L10n.string("这个地址通常只能由这台 Mac 上的应用访问。")
        case .networkPossible:
            return L10n.string("同一网络中的设备可能具备访问条件；实际能否访问仍取决于 macOS 防火墙、路由器和应用设置。")
        case .unknown:
            return L10n.string("当前数据不足以判断访问范围，可以在技术详情中查看原始地址。")
        }
    }
}

struct ListenerActivityKey: Hashable, Sendable {
    let pid: Int32
    let transport: TransportProtocol
    let localPort: Int

    init?(listener record: PortRecord) {
        guard record.isListening, let localPort = record.localPort else { return nil }
        pid = record.pid
        transport = record.transport
        self.localPort = localPort
    }

    init?(connection record: PortRecord) {
        guard record.isActiveConnection, let localPort = record.localPort else { return nil }
        pid = record.pid
        transport = record.transport
        self.localPort = localPort
    }
}

enum PortActivityChangeKind: Equatable, Sendable {
    case appeared(Int)
    case ended(Int)
    case changed(appeared: Int, ended: Int)

    var shortDescription: String {
        switch self {
        case .appeared(let count):
            return L10n.format("刚发现 %lld 条新连接", count)
        case .ended(let count):
            return L10n.format("刚有 %lld 条连接结束", count)
        case .changed(let appeared, let ended):
            return L10n.format("刚新增 %lld 条、结束 %lld 条", appeared, ended)
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .appeared(let count):
            return L10n.format("刚刚发现 %lld 条新的连接活动", count)
        case .ended(let count):
            return L10n.format("刚刚有 %lld 条连接活动结束", count)
        case .changed(let appeared, let ended):
            return L10n.format("连接刚刚发生变化，新增 %lld 条，结束 %lld 条", appeared, ended)
        }
    }
}

struct RecentPortActivityChange: Equatable, Sendable {
    let kind: PortActivityChangeKind
    let observedAt: Date
}

struct PortActivitySnapshot: Equatable, Sendable {
    let connectionIDsByListener: [ListenerActivityKey: Set<String>]
    let remoteEndpointsByListener: [ListenerActivityKey: [String]]

    static func capture(from records: [PortRecord]) -> PortActivitySnapshot {
        let listenerKeys = Set(records.compactMap { ListenerActivityKey(listener: $0) })
        var connectionIDs = Dictionary(
            uniqueKeysWithValues: listenerKeys.map { ($0, Set<String>()) }
        )
        var remoteEndpoints = Dictionary(
            uniqueKeysWithValues: listenerKeys.map { ($0, Set<String>()) }
        )

        for record in records {
            guard let key = ListenerActivityKey(connection: record), listenerKeys.contains(key) else { continue }
            connectionIDs[key, default: []].insert(record.id)
            remoteEndpoints[key, default: []].insert(record.remoteEndpoint)
        }

        return PortActivitySnapshot(
            connectionIDsByListener: connectionIDs,
            remoteEndpointsByListener: remoteEndpoints.mapValues { $0.sorted() }
        )
    }

    func changes(
        comparedTo previous: PortActivitySnapshot,
        observedAt: Date
    ) -> [ListenerActivityKey: RecentPortActivityChange] {
        let allKeys = Set(connectionIDsByListener.keys).union(previous.connectionIDsByListener.keys)
        var result: [ListenerActivityKey: RecentPortActivityChange] = [:]

        for key in allKeys {
            let currentIDs = connectionIDsByListener[key] ?? []
            let previousIDs = previous.connectionIDsByListener[key] ?? []
            let appearedCount = currentIDs.subtracting(previousIDs).count
            let endedCount = previousIDs.subtracting(currentIDs).count

            let kind: PortActivityChangeKind
            switch (appearedCount, endedCount) {
            case (0, 0):
                continue
            case (_, 0):
                kind = .appeared(appearedCount)
            case (0, _):
                kind = .ended(endedCount)
            default:
                kind = .changed(appeared: appearedCount, ended: endedCount)
            }
            result[key] = RecentPortActivityChange(kind: kind, observedAt: observedAt)
        }

        return result
    }
}

struct ListenerActivitySummary: Equatable, Sendable {
    let connectionCount: Int
    let remoteEndpoints: [String]
    let recentChange: RecentPortActivityChange?

    var currentDescription: String {
        connectionCount == 0
            ? L10n.string("当前未观察到连接")
            : L10n.format("当前有 %lld 条连接活动", connectionCount)
    }

    var inlineDescription: String? {
        if let recentChange {
            return L10n.format("%@ · 当前 %lld 条", recentChange.kind.shortDescription, connectionCount)
        }
        return connectionCount > 0 ? L10n.format("当前 %lld 条连接活动", connectionCount) : nil
    }

    var accessibilityDescription: String {
        if let recentChange {
            return L10n.format("%@。%@。", recentChange.kind.accessibilityDescription, currentDescription)
        }
        return L10n.format("%@。", currentDescription)
    }

    static func make(
        for item: ReadablePortItem,
        snapshot: PortActivitySnapshot,
        recentChanges: [ListenerActivityKey: RecentPortActivityChange]
    ) -> ListenerActivitySummary? {
        let keys = Set(item.rawRecords.compactMap(ListenerActivityKey.init(listener:)))
        guard !keys.isEmpty else { return nil }
        let connectionIDs = keys.reduce(into: Set<String>()) { result, key in
            result.formUnion(snapshot.connectionIDsByListener[key] ?? [])
        }
        let remoteEndpoints = keys.reduce(into: Set<String>()) { result, key in
            result.formUnion(snapshot.remoteEndpointsByListener[key] ?? [])
        }
        let changes = keys.compactMap { recentChanges[$0] }
        return ListenerActivitySummary(
            connectionCount: connectionIDs.count,
            remoteEndpoints: remoteEndpoints.sorted(),
            recentChange: aggregateRecentChanges(changes)
        )
    }

    private static func aggregateRecentChanges(
        _ changes: [RecentPortActivityChange]
    ) -> RecentPortActivityChange? {
        guard !changes.isEmpty else { return nil }
        var appeared = 0
        var ended = 0
        for change in changes {
            switch change.kind {
            case .appeared(let count): appeared += count
            case .ended(let count): ended += count
            case .changed(let appearedCount, let endedCount):
                appeared += appearedCount
                ended += endedCount
            }
        }
        let kind: PortActivityChangeKind
        switch (appeared, ended) {
        case (_, 0): kind = .appeared(appeared)
        case (0, _): kind = .ended(ended)
        default: kind = .changed(appeared: appeared, ended: ended)
        }
        return RecentPortActivityChange(
            kind: kind,
            observedAt: changes.map(\.observedAt).max() ?? Date()
        )
    }
}

extension PortRecord {
    var normalizedState: String? {
        guard let state = state?.trimmingCharacters(in: .whitespacesAndNewlines), !state.isEmpty else {
            return nil
        }
        return state.uppercased()
    }

    var activityKind: NetworkActivityKind {
        if isListening { return .waiting }
        guard transport == .tcp else { return .other }

        switch normalizedState {
        case "ESTABLISHED":
            return .connected
        case "SYN_SENT", "SYN_RECEIVED", "TIME_WAIT", "CLOSE_WAIT", "FIN_WAIT_1", "FIN_WAIT_2", "LAST_ACK", "CLOSING", "CLOSED":
            return .transitioning
        default:
            return .other
        }
    }

    var accessScope: NetworkAccessScope {
        guard isListening else { return .unknown }
        let address = localAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty, address != "-", address != "?" else { return .unknown }

        if address == "127.0.0.1" || address == "::1" || address == "localhost" {
            return .localOnly
        }
        return .networkPossible
    }

    var friendlyStatusTitle: String {
        Self.friendlyStatusTitle(for: normalizedState, transport: transport)
    }

    var friendlyStatusExplanation: String {
        switch normalizedState {
        case "LISTEN":
            return L10n.string("应用开放了一个端口，正在等待其他程序连接。")
        case "ESTABLISHED":
            return L10n.string("双方具备交换数据的条件，但不代表此刻一定有数据传输。")
        case "SYN_SENT":
            return L10n.string("这台 Mac 正在尝试连接另一端。")
        case "SYN_RECEIVED":
            return L10n.string("已收到连接请求，正在完成建立连接。")
        case "TIME_WAIT":
            return L10n.string("连接已经关闭，系统暂时保留记录以处理延迟数据。")
        case "CLOSE_WAIT":
            return L10n.string("另一端已结束连接，本机应用还在完成关闭流程。")
        case "FIN_WAIT_1", "FIN_WAIT_2", "CLOSING":
            return L10n.string("连接正在关闭，系统仍在等待一端或双方确认。")
        case "LAST_ACK":
            return L10n.string("连接即将结束，正在等待最后确认。")
        case "CLOSED":
            return L10n.string("连接已经关闭。")
        case nil where transport == .udp:
            return L10n.string("UDP 不保持 TCP 式连接状态，因此没有“已连接/未连接”状态。")
        case nil:
            return L10n.string("系统没有为这条记录提供可识别的 TCP 状态。")
        default:
            return L10n.string("这是系统返回的技术状态，可在技术详情中查看原始代码。")
        }
    }

    static func friendlyStatusTitle(for state: String?, transport: TransportProtocol = .tcp) -> String {
        switch state?.uppercased() {
        case "LISTEN": return L10n.string("等待连接")
        case "ESTABLISHED": return L10n.string("连接已建立")
        case "SYN_SENT": return L10n.string("正在发起连接")
        case "SYN_RECEIVED": return L10n.string("正在确认连接")
        case "TIME_WAIT": return L10n.string("刚刚结束")
        case "CLOSE_WAIT": return L10n.string("等待应用关闭")
        case "FIN_WAIT_1", "FIN_WAIT_2", "CLOSING": return L10n.string("正在关闭")
        case "LAST_ACK": return L10n.string("正在完成关闭")
        case "CLOSED": return L10n.string("已结束")
        case nil where transport == .udp: return L10n.string("正在使用")
        default: return L10n.string("其他状态")
        }
    }
}

struct ReadablePortItem: Identifiable, Hashable, Sendable {
    let id: String
    let rawRecords: [PortRecord]
    let localPorts: [Int]
    let remoteEndpoints: [String]
    let connectionCount: Int
    let processSummaries: [ProcessUsageSummary]

    init(id: String, rawRecords: [PortRecord]) {
        self.id = id
        self.rawRecords = rawRecords
        localPorts = Array(Set(rawRecords.compactMap(\.localPort))).sorted()
        remoteEndpoints = Array(Set(rawRecords.compactMap { record in
            record.remoteAddress == nil ? nil : record.remoteEndpoint
        })).sorted()
        connectionCount = rawRecords.reduce(into: 0) { count, record in
            if record.isActiveConnection { count += 1 }
        }
        processSummaries = Dictionary(grouping: rawRecords, by: \.pid).map { pid, records in
            ProcessUsageSummary(
                pid: pid,
                processName: records[0].processName,
                recordCount: records.count
            )
        }.sorted { $0.pid < $1.pid }
    }

    var representative: PortRecord { rawRecords[0] }
    var processName: String { representative.processName }
    var pid: Int32 { representative.pid }
    var transport: TransportProtocol { representative.transport }
    var localPort: Int? { representative.localPort }
    var remoteTargetCount: Int { remoteEndpoints.count }
    var processCount: Int { processSummaries.count }
    var localPortText: String {
        switch localPorts.count {
        case 0: return "*"
        case 1: return String(localPorts[0])
        default: return L10n.format("%lld 个", localPorts.count)
        }
    }
    var localPortSortValue: Int { localPorts.first ?? Int.max }
    var activityKind: NetworkActivityKind { representative.activityKind }
    var accessScope: NetworkAccessScope { representative.accessScope }
    var friendlyStatusTitle: String { representative.friendlyStatusTitle }
    var processSortValue: String { processName.localizedLowercase }
    var statusSortValue: String { friendlyStatusTitle }
    var connectionSortValue: String { connectionDisplay }
    var isConnectionSummary: Bool {
        transport == .tcp && !representative.isListening && rawRecords.contains { $0.remoteAddress != nil }
    }
    var topologyKind: ActivityTopologyKind {
        if representative.isListening {
            return localPorts.count > 1 ? .multipleServicePorts : .single
        }
        guard isConnectionSummary else { return .single }
        switch (localPorts.count > 1, remoteTargetCount > 1) {
        case (true, false): return .multiplePortsToOneTarget
        case (false, true): return .onePortToMultipleTargets
        case (true, true): return .multiplePortsToMultipleTargets
        case (false, false): return .single
        }
    }

    var localPortRoleText: String {
        if representative.isListening { return L10n.string("服务端口") }
        if isConnectionSummary { return L10n.string("连接端口") }
        if transport == .udp { return L10n.string("UDP 端口") }
        return L10n.string("本机端口")
    }

    var localPortRelationshipText: String {
        let port = localPorts.first.map(String.init) ?? L10n.string("未知")
        if representative.isListening {
            return localPorts.count > 1
                ? L10n.format("%lld 个服务端口", localPorts.count)
                : L10n.format("服务端口 %@", port)
        }
        if isConnectionSummary {
            return localPorts.count > 1
                ? L10n.format("%lld 个本机连接端口", localPorts.count)
                : L10n.format("本机连接端口 %@", port)
        }
        if transport == .udp { return L10n.format("UDP 端口 %@", port) }
        return L10n.format("本机端口 %@", port)
    }

    var activitySummaryText: String? {
        if representative.isListening, localPorts.count > 1 {
            return L10n.format("%lld 个服务端口", localPorts.count)
        }
        if isConnectionSummary, connectionCount > 1 {
            let targetText = remoteTargetCount == 1
                ? L10n.string("1 个目标")
                : L10n.format("%lld 个目标", remoteTargetCount)
            return L10n.format("%lld 条连接 · %@", connectionCount, targetText)
        }
        return containsTechnicalRecordText
    }

    var containsTechnicalRecordText: String? {
        rawRecords.count > 1 ? L10n.format("包含 %lld 条技术记录", rawRecords.count) : nil
    }

    var connectionDisplay: String {
        if representative.isListening {
            return L10n.string(accessScope.rawValue)
        }
        if isConnectionSummary {
            if remoteTargetCount == 1, let endpoint = remoteEndpoints.first {
                let countSuffix = connectionCount > 1 ? L10n.format(" · %lld 条", connectionCount) : ""
                return L10n.format("连接到 %@%@", endpoint, countSuffix)
            }
            if remoteTargetCount > 1 {
                return L10n.format("连接到 %lld 个目标 · %lld 条", remoteTargetCount, connectionCount)
            }
        }
        if representative.transport == .udp {
            return L10n.string("通信对象不固定")
        }
        return L10n.string("连接对象未知")
    }

    var conclusion: String {
        let record = representative
        let port = record.localPort.map(String.init) ?? L10n.string("未知端口")

        if record.isListening {
            if localPorts.count > 1 {
                switch accessScope {
                case .localOnly:
                    return L10n.format("%@ 正在通过 %lld 个服务端口等待这台 Mac 上的应用连接。", processName, localPorts.count)
                case .networkPossible:
                    return L10n.format("%@ 正在通过 %lld 个服务端口等待连接，同一网络中的其他设备可能也能访问它们。", processName, localPorts.count)
                case .unknown:
                    return L10n.format("%@ 正在通过 %lld 个服务端口等待连接，但访问范围暂不确定。", processName, localPorts.count)
                }
            }
            switch accessScope {
            case .localOnly:
                return L10n.format("%@ 正在通过端口 %@ 等待这台 Mac 上的应用连接。", processName, port)
            case .networkPossible:
                return L10n.format("%@ 正在通过端口 %@ 等待连接，同一网络中的其他设备可能也能访问它。", processName, port)
            case .unknown:
                return L10n.format("%@ 正在通过端口 %@ 等待连接，但访问范围暂不确定。", processName, port)
            }
        }

        if record.transport == .udp {
            if record.remoteAddress != nil {
                return L10n.format("%@ 正在使用 UDP 端口 %@ 与 %@ 通信。", processName, port, record.remoteEndpoint)
            }
            return L10n.format("%@ 正在使用 UDP 端口 %@ 发送或接收无固定连接的数据。", processName, port)
        }

        if isConnectionSummary, connectionCount > 1 {
            let targetText: String
            if remoteTargetCount == 1, let endpoint = remoteEndpoints.first {
                targetText = endpoint
            } else {
                targetText = L10n.format("%lld 个不同目标", remoteTargetCount)
            }
            let portText: String
            if localPorts.count == 1, let sharedPort = localPorts.first {
                portText = L10n.format("共同使用本机端口 %lld", sharedPort)
            } else {
                portText = L10n.format("使用 %lld 个本机连接端口", localPorts.count)
            }
            switch activityKind {
            case .connected:
                return L10n.format("%@ 与 %@ 之间有 %lld 条已建立连接，%@。", processName, targetText, connectionCount, portText)
            case .transitioning:
                return L10n.format("%@ 与 %@ 之间有 %lld 条连接正在建立或关闭，%@。", processName, targetText, connectionCount, portText)
            default:
                return L10n.format("%@ 正在与 %@ 进行 %lld 条网络连接活动，%@。", processName, targetText, connectionCount, portText)
            }
        }

        if let remoteAddress = record.remoteAddress {
            let remotePort = record.remotePort.map(String.init) ?? L10n.string("未知")
            switch record.activityKind {
            case .connected:
                return L10n.format("%@ 与 %@ 的 %@ 端口之间已建立连接。", processName, remoteAddress, remotePort)
            case .transitioning:
                return L10n.format("%@ 与 %@ 的 %@ 端口之间%@。", processName, remoteAddress, remotePort, record.friendlyStatusTitle)
            default:
                return L10n.format("%@ 正在与 %@ 的 %@ 端口进行网络活动。", processName, remoteAddress, remotePort)
            }
        }

        return L10n.format("%@ 正在进行网络活动，但目前的信息不足以确定连接对象。", processName)
    }

    var textualRelationshipDescription: String {
        let record = representative
        let port = record.localPort.map(String.init) ?? L10n.string("未知")
        if record.isListening {
            let source = accessScope == .localOnly
                ? L10n.string("这台 Mac")
                : accessScope == .networkPossible
                    ? L10n.string("这台 Mac 或同一网络设备")
                    : L10n.string("访问来源暂不确定")
            let ownership = localPorts.count > 1 ? L10n.string("这些端口") : L10n.string("该端口")
            return L10n.format(
                "连接关系：%@ 可以尝试连接这台 Mac 的%@，%@由 %@ 使用。",
                source,
                localPortRelationshipText,
                ownership,
                processName
            )
        }
        if record.transport == .udp {
            let target = record.remoteAddress == nil ? L10n.string("可能的通信对象") : record.remoteEndpoint
            return L10n.format(
                "连接关系：%@ 通过这台 Mac 的 UDP 端口 %@ 与 %@ 发送或接收数据。UDP 没有 TCP 式的连接状态。",
                processName,
                port,
                target
            )
        }
        if isConnectionSummary, connectionCount > 1 {
            let target = remoteTargetCount == 1
                ? (remoteEndpoints.first ?? L10n.string("连接对象未知"))
                : L10n.format("%lld 个不同目标", remoteTargetCount)
            return L10n.format(
                "连接关系：%@ 通过这台 Mac 的%@，与 %@ 保持 %lld 条独立连接；这些本机端口不表示应用对外开放了同样数量的服务。",
                processName,
                localPortRelationshipText,
                target,
                connectionCount
            )
        }
        let target = record.remoteAddress == nil ? L10n.string("连接对象未知") : record.remoteEndpoint
        return L10n.format(
            "连接关系：%@ 通过这台 Mac 的本机端口 %@ 与 %@ 存在连接关系；双向箭头不表示此刻一定正在传输数据。",
            processName,
            port,
            target
        )
    }

    var meaningMessages: [String] {
        let record = representative
        if record.isListening {
            var messages = [accessScope.explanation]
            if localPorts.count > 1 {
                messages.append(L10n.string("同一应用可以为不同功能使用多个服务端口；端口数量本身不代表异常。"))
            }
            return messages
        }
        if record.transport == .udp {
            return [L10n.string("UDP 不保持“已连接/未连接”状态，因此这里没有 TCP 那样的连接状态。")]
        }
        var messages: [String]
        switch record.normalizedState {
        case "ESTABLISHED":
            messages = [L10n.string("两端已建立连接并具备交换数据的条件，但不代表此刻一定在传输数据。")]
        case "TIME_WAIT", "CLOSED":
            messages = [L10n.string("连接已经结束，系统可能会短暂保留这条记录。")]
        default:
            messages = [record.friendlyStatusExplanation]
        }

        guard isConnectionSummary, connectionCount > 1 else { return messages }
        let repeatedPorts = Dictionary(grouping: rawRecords.compactMap(\.localPort), by: { $0 })
            .filter { $0.value.count > 1 }
            .sorted { $0.key < $1.key }
        if let repeatedPort = repeatedPorts.first {
            messages.append(L10n.format(
                "本机端口 %lld 同时出现在 %lld 条连接中，因为连接对象不同；相同端口不代表同一连接。",
                repeatedPort.key,
                repeatedPort.value.count
            ))
        } else {
            messages.append(L10n.string("同一应用可以同时建立多条独立连接；这些本机连接端口不是对外开放的服务。"))
        }
        return messages
    }

    static func group(_ records: [PortRecord]) -> [ReadablePortItem] {
        struct GroupKey: Hashable {
            let pid: Int32?
            let processIdentity: String
            let transport: TransportProtocol
            let port: Int?
            let activityMeaning: String
            let accessScope: NetworkAccessScope
            let remoteEndpoint: String
            let presentationKind: String
        }

        let grouped = Dictionary(grouping: records) { record in
            let unknownStateSuffix = record.friendlyStatusTitle == L10n.string("其他状态") ? "|\(record.normalizedState ?? "")" : ""
            let summarizesConnections = record.isActiveConnection
            let summarizesListeners = record.isListening
            return GroupKey(
                pid: summarizesListeners ? nil : record.pid,
                processIdentity: summarizesListeners
                    ? [record.processName, record.user, record.executablePath ?? ""].joined(separator: "|")
                    : "",
                transport: record.transport,
                port: summarizesConnections || summarizesListeners ? nil : record.localPort,
                activityMeaning: record.friendlyStatusTitle + unknownStateSuffix,
                accessScope: record.accessScope,
                remoteEndpoint: summarizesConnections || record.isListening ? "" : record.remoteEndpoint,
                presentationKind: summarizesConnections ? "connection-summary" : summarizesListeners ? "listener-summary" : "port-activity"
            )
        }

        return grouped.map { key, values in
            let sortedValues = values.sorted {
                if $0.localPortSortValue != $1.localPortSortValue {
                    return $0.localPortSortValue < $1.localPortSortValue
                }
                if $0.remoteEndpoint != $1.remoteEndpoint {
                    return $0.remoteEndpoint.localizedStandardCompare($1.remoteEndpoint) == .orderedAscending
                }
                if $0.pid != $1.pid {
                    return $0.pid < $1.pid
                }
                if $0.ipVersion.rawValue != $1.ipVersion.rawValue {
                    return $0.ipVersion.rawValue < $1.ipVersion.rawValue
                }
                if $0.localAddress != $1.localAddress {
                    return $0.localAddress.localizedStandardCompare($1.localAddress) == .orderedAscending
                }
                return $0.fileDescriptor.localizedStandardCompare($1.fileDescriptor) == .orderedAscending
            }
            let stableID = [
                key.pid.map(String.init) ?? key.processIdentity, key.transport.rawValue, key.port.map(String.init) ?? "*",
                key.activityMeaning, key.accessScope.rawValue, key.remoteEndpoint, key.presentationKind
            ].joined(separator: "|")
            return ReadablePortItem(id: stableID, rawRecords: sortedValues)
        }.sorted {
            if $0.localPortSortValue != $1.localPortSortValue {
                return $0.localPortSortValue < $1.localPortSortValue
            }
            return $0.processName.localizedStandardCompare($1.processName) == .orderedAscending
        }
    }
}
