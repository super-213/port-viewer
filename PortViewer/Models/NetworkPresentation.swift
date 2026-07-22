import Foundation

enum NetworkActivityKind: String, CaseIterable, Identifiable, Sendable {
    case waiting = "等待连接"
    case connected = "连接已建立"
    case transitioning = "正在建立/关闭"
    case other = "其他网络活动"

    var id: Self { self }
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
            return "这个地址通常只能由这台 Mac 上的应用访问。"
        case .networkPossible:
            return "同一网络中的设备可能具备访问条件；实际能否访问仍取决于 macOS 防火墙、路由器和应用设置。"
        case .unknown:
            return "当前数据不足以判断访问范围，可以在技术详情中查看原始地址。"
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
            return "刚发现 \(count) 条新连接"
        case .ended(let count):
            return "刚有 \(count) 条连接结束"
        case .changed(let appeared, let ended):
            return "刚新增 \(appeared) 条、结束 \(ended) 条"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .appeared(let count):
            return "刚刚发现 \(count) 条新的连接活动"
        case .ended(let count):
            return "刚刚有 \(count) 条连接活动结束"
        case .changed(let appeared, let ended):
            return "连接刚刚发生变化，新增 \(appeared) 条，结束 \(ended) 条"
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
        connectionCount == 0 ? "当前未观察到连接" : "当前有 \(connectionCount) 条连接活动"
    }

    var inlineDescription: String? {
        if let recentChange {
            return "\(recentChange.kind.shortDescription) · 当前 \(connectionCount) 条"
        }
        return connectionCount > 0 ? "当前 \(connectionCount) 条连接活动" : nil
    }

    var accessibilityDescription: String {
        if let recentChange {
            return "\(recentChange.kind.accessibilityDescription)。\(currentDescription)。"
        }
        return "\(currentDescription)。"
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
            return "应用开放了一个端口，正在等待其他程序连接。"
        case "ESTABLISHED":
            return "双方具备交换数据的条件，但不代表此刻一定有数据传输。"
        case "SYN_SENT":
            return "这台 Mac 正在尝试连接另一端。"
        case "SYN_RECEIVED":
            return "已收到连接请求，正在完成建立连接。"
        case "TIME_WAIT":
            return "连接已经关闭，系统暂时保留记录以处理延迟数据。"
        case "CLOSE_WAIT":
            return "另一端已结束连接，本机应用还在完成关闭流程。"
        case "FIN_WAIT_1", "FIN_WAIT_2", "CLOSING":
            return "连接正在关闭，系统仍在等待一端或双方确认。"
        case "LAST_ACK":
            return "连接即将结束，正在等待最后确认。"
        case "CLOSED":
            return "连接已经关闭。"
        case nil where transport == .udp:
            return "UDP 不保持 TCP 式连接状态，因此没有“已连接/未连接”状态。"
        case nil:
            return "系统没有为这条记录提供可识别的 TCP 状态。"
        default:
            return "这是系统返回的技术状态，可在技术详情中查看原始代码。"
        }
    }

    static func friendlyStatusTitle(for state: String?, transport: TransportProtocol = .tcp) -> String {
        switch state?.uppercased() {
        case "LISTEN": return "等待连接"
        case "ESTABLISHED": return "连接已建立"
        case "SYN_SENT": return "正在发起连接"
        case "SYN_RECEIVED": return "正在确认连接"
        case "TIME_WAIT": return "刚刚结束"
        case "CLOSE_WAIT": return "等待应用关闭"
        case "FIN_WAIT_1", "FIN_WAIT_2", "CLOSING": return "正在关闭"
        case "LAST_ACK": return "正在完成关闭"
        case "CLOSED": return "已结束"
        case nil where transport == .udp: return "正在使用"
        default: return "其他状态"
        }
    }
}

struct ReadablePortItem: Identifiable, Hashable, Sendable {
    let id: String
    let rawRecords: [PortRecord]

    var representative: PortRecord { rawRecords[0] }
    var processName: String { representative.processName }
    var pid: Int32 { representative.pid }
    var transport: TransportProtocol { representative.transport }
    var localPort: Int? { representative.localPort }
    var localPorts: [Int] { Array(Set(rawRecords.compactMap(\.localPort))).sorted() }
    var remoteEndpoints: [String] {
        Array(Set(rawRecords.compactMap { record in
            record.remoteAddress == nil ? nil : record.remoteEndpoint
        })).sorted()
    }
    var connectionCount: Int { rawRecords.filter(\.isActiveConnection).count }
    var remoteTargetCount: Int { remoteEndpoints.count }
    var processSummaries: [ProcessUsageSummary] {
        Dictionary(grouping: rawRecords, by: \.pid).map { pid, records in
            ProcessUsageSummary(
                pid: pid,
                processName: records[0].processName,
                recordCount: records.count
            )
        }.sorted { $0.pid < $1.pid }
    }
    var processCount: Int { processSummaries.count }
    var localPortText: String {
        switch localPorts.count {
        case 0: return "*"
        case 1: return String(localPorts[0])
        default: return "\(localPorts.count) 个"
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
        if representative.isListening { return "服务端口" }
        if isConnectionSummary { return "连接端口" }
        if transport == .udp { return "UDP 端口" }
        return "本机端口"
    }

    var localPortRelationshipText: String {
        let port = localPorts.first.map(String.init) ?? "未知"
        if representative.isListening {
            return localPorts.count > 1 ? "\(localPorts.count) 个服务端口" : "服务端口 \(port)"
        }
        if isConnectionSummary {
            return localPorts.count > 1 ? "\(localPorts.count) 个本机连接端口" : "本机连接端口 \(port)"
        }
        if transport == .udp { return "UDP 端口 \(port)" }
        return "本机端口 \(port)"
    }

    var activitySummaryText: String? {
        if representative.isListening, localPorts.count > 1 {
            return "\(localPorts.count) 个服务端口"
        }
        if isConnectionSummary, connectionCount > 1 {
            let targetText = remoteTargetCount == 1 ? "1 个目标" : "\(remoteTargetCount) 个目标"
            return "\(connectionCount) 条连接 · \(targetText)"
        }
        return containsTechnicalRecordText
    }

    var containsTechnicalRecordText: String? {
        rawRecords.count > 1 ? "包含 \(rawRecords.count) 条技术记录" : nil
    }

    var connectionDisplay: String {
        if representative.isListening {
            return accessScope.rawValue
        }
        if isConnectionSummary {
            if remoteTargetCount == 1, let endpoint = remoteEndpoints.first {
                let countSuffix = connectionCount > 1 ? " · \(connectionCount) 条" : ""
                return "连接到 \(endpoint)\(countSuffix)"
            }
            if remoteTargetCount > 1 {
                return "连接到 \(remoteTargetCount) 个目标 · \(connectionCount) 条"
            }
        }
        if representative.transport == .udp {
            return "通信对象不固定"
        }
        return "连接对象未知"
    }

    var conclusion: String {
        let record = representative
        let port = record.localPort.map(String.init) ?? "未知端口"

        if record.isListening {
            if localPorts.count > 1 {
                switch accessScope {
                case .localOnly:
                    return "\(processName) 正在通过 \(localPorts.count) 个服务端口等待这台 Mac 上的应用连接。"
                case .networkPossible:
                    return "\(processName) 正在通过 \(localPorts.count) 个服务端口等待连接，同一网络中的其他设备可能也能访问它们。"
                case .unknown:
                    return "\(processName) 正在通过 \(localPorts.count) 个服务端口等待连接，但访问范围暂不确定。"
                }
            }
            switch accessScope {
            case .localOnly:
                return "\(processName) 正在通过端口 \(port) 等待这台 Mac 上的应用连接。"
            case .networkPossible:
                return "\(processName) 正在通过端口 \(port) 等待连接，同一网络中的其他设备可能也能访问它。"
            case .unknown:
                return "\(processName) 正在通过端口 \(port) 等待连接，但访问范围暂不确定。"
            }
        }

        if record.transport == .udp {
            if record.remoteAddress != nil {
                return "\(processName) 正在使用 UDP 端口 \(port) 与 \(record.remoteEndpoint) 通信。"
            }
            return "\(processName) 正在使用 UDP 端口 \(port) 发送或接收无固定连接的数据。"
        }

        if isConnectionSummary, connectionCount > 1 {
            let targetText: String
            if remoteTargetCount == 1, let endpoint = remoteEndpoints.first {
                targetText = endpoint
            } else {
                targetText = "\(remoteTargetCount) 个不同目标"
            }
            let portText: String
            if localPorts.count == 1, let sharedPort = localPorts.first {
                portText = "共同使用本机端口 \(sharedPort)"
            } else {
                portText = "使用 \(localPorts.count) 个本机连接端口"
            }
            switch activityKind {
            case .connected:
                return "\(processName) 与 \(targetText) 之间有 \(connectionCount) 条已建立连接，\(portText)。"
            case .transitioning:
                return "\(processName) 与 \(targetText) 之间有 \(connectionCount) 条连接正在建立或关闭，\(portText)。"
            default:
                return "\(processName) 正在与 \(targetText) 进行 \(connectionCount) 条网络连接活动，\(portText)。"
            }
        }

        if let remoteAddress = record.remoteAddress {
            let remotePort = record.remotePort.map(String.init) ?? "未知"
            switch record.activityKind {
            case .connected:
                return "\(processName) 与 \(remoteAddress) 的 \(remotePort) 端口之间已建立连接。"
            case .transitioning:
                return "\(processName) 与 \(remoteAddress) 的 \(remotePort) 端口之间\(record.friendlyStatusTitle)。"
            default:
                return "\(processName) 正在与 \(remoteAddress) 的 \(remotePort) 端口进行网络活动。"
            }
        }

        return "\(processName) 正在进行网络活动，但目前的信息不足以确定连接对象。"
    }

    var textualRelationshipDescription: String {
        let record = representative
        let port = record.localPort.map(String.init) ?? "未知"
        if record.isListening {
            let source = accessScope == .localOnly ? "这台 Mac" : accessScope == .networkPossible ? "这台 Mac 或同一网络设备" : "访问来源暂不确定"
            let ownership = localPorts.count > 1 ? "这些端口" : "该端口"
            return "连接关系：\(source) 可以尝试连接这台 Mac 的\(localPortRelationshipText)，\(ownership)由 \(processName) 使用。"
        }
        if record.transport == .udp {
            let target = record.remoteAddress == nil ? "可能的通信对象" : record.remoteEndpoint
            return "连接关系：\(processName) 通过这台 Mac 的 UDP 端口 \(port) 与 \(target) 发送或接收数据。UDP 没有 TCP 式的连接状态。"
        }
        if isConnectionSummary, connectionCount > 1 {
            let target = remoteTargetCount == 1
                ? (remoteEndpoints.first ?? "连接对象未知")
                : "\(remoteTargetCount) 个不同目标"
            return "连接关系：\(processName) 通过这台 Mac 的\(localPortRelationshipText)，与 \(target) 保持 \(connectionCount) 条独立连接；这些本机端口不表示应用对外开放了同样数量的服务。"
        }
        let target = record.remoteAddress == nil ? "连接对象未知" : record.remoteEndpoint
        return "连接关系：\(processName) 通过这台 Mac 的本机端口 \(port) 与 \(target) 存在连接关系；双向箭头不表示此刻一定正在传输数据。"
    }

    var meaningMessages: [String] {
        let record = representative
        if record.isListening {
            var messages = [accessScope.explanation]
            if localPorts.count > 1 {
                messages.append("同一应用可以为不同功能使用多个服务端口；端口数量本身不代表异常。")
            }
            return messages
        }
        if record.transport == .udp {
            return ["UDP 不保持“已连接/未连接”状态，因此这里没有 TCP 那样的连接状态。"]
        }
        var messages: [String]
        switch record.normalizedState {
        case "ESTABLISHED":
            messages = ["两端已建立连接并具备交换数据的条件，但不代表此刻一定在传输数据。"]
        case "TIME_WAIT", "CLOSED":
            messages = ["连接已经结束，系统可能会短暂保留这条记录。"]
        default:
            messages = [record.friendlyStatusExplanation]
        }

        guard isConnectionSummary, connectionCount > 1 else { return messages }
        let repeatedPorts = Dictionary(grouping: rawRecords.compactMap(\.localPort), by: { $0 })
            .filter { $0.value.count > 1 }
            .sorted { $0.key < $1.key }
        if let repeatedPort = repeatedPorts.first {
            messages.append("本机端口 \(repeatedPort.key) 同时出现在 \(repeatedPort.value.count) 条连接中，因为连接对象不同；相同端口不代表同一连接。")
        } else {
            messages.append("同一应用可以同时建立多条独立连接；这些本机连接端口不是对外开放的服务。")
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
            let unknownStateSuffix = record.friendlyStatusTitle == "其他状态" ? "|\(record.normalizedState ?? "")" : ""
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
