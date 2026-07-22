import Foundation
import Observation

struct ReadablePortSortComparator: SortComparator, Sendable {
    enum Field: Sendable {
        case process
        case localPort
        case status
        case connection
    }

    let field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: ReadablePortItem, _ rhs: ReadablePortItem) -> ComparisonResult {
        let result: ComparisonResult
        switch field {
        case .process:
            result = lhs.processSortValue.localizedStandardCompare(rhs.processSortValue)
        case .localPort:
            result = Self.compare(lhs.localPortSortValue, rhs.localPortSortValue)
        case .status:
            result = lhs.statusSortValue.localizedStandardCompare(rhs.statusSortValue)
        case .connection:
            result = lhs.connectionSortValue.localizedStandardCompare(rhs.connectionSortValue)
        }

        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private static func compare(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

enum SidebarScope: String, CaseIterable, Identifiable {
    case all = "全部活动"
    case waiting = "等待连接"
    case connections = "连接活动"
    case other = "其他网络活动"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .all: return "list.bullet"
        case .waiting: return "dot.radiowaves.left.and.right"
        case .connections: return "arrow.left.arrow.right"
        case .other: return "antenna.radiowaves.left.and.right"
        }
    }

    var explanation: String {
        switch self {
        case .all: return "所有端口和网络连接"
        case .waiting: return "应用正在等待连接"
        case .connections: return "存在建立中、已建立或关闭中的连接"
        case .other: return "UDP 及暂时无法归类的活动"
        }
    }
}

enum AccessFilter: String, CaseIterable, Identifiable {
    case all = "全部访问范围"
    case localOnly = "仅这台 Mac"
    case networkPossible = "可能被其他设备访问"
    case unknown = "范围不确定"

    var id: Self { self }
}

enum OwnerFilter: String, CaseIterable, Identifiable {
    case all = "全部归属"
    case current = "我的应用/服务"
    case others = "其他用户"

    var id: Self { self }
}

enum ConnectionPhaseFilter: String, CaseIterable, Identifiable {
    case all = "全部连接状态"
    case established = "连接已建立"
    case transitioning = "正在建立/关闭"

    var id: Self { self }
}

enum ProtocolFilter: String, CaseIterable, Identifiable {
    case all = "全部协议"
    case tcp = "TCP"
    case udp = "UDP"

    var id: Self { self }
}

enum IPFilter: String, CaseIterable, Identifiable {
    case all = "全部地址格式"
    case v4 = "IPv4"
    case v6 = "IPv6"

    var id: Self { self }
}

@MainActor
@Observable
final class MainWindowViewModel {
    var scope: SidebarScope = .waiting {
        didSet {
            if scope != .connections {
                connectionPhaseFilter = .all
            }
            invalidateDisplayedItems()
        }
    }
    var searchText = "" { didSet { invalidateDisplayedItems() } }
    var accessFilter: AccessFilter = .all { didSet { invalidateDisplayedItems() } }
    var ownerFilter: OwnerFilter = .all { didSet { invalidateDisplayedItems() } }
    var connectionPhaseFilter: ConnectionPhaseFilter = .all { didSet { invalidateDisplayedItems() } }
    var protocolFilter: ProtocolFilter = .all { didSet { invalidateDisplayedItems() } }
    var ipFilter: IPFilter = .all { didSet { invalidateDisplayedItems() } }
    var stateFilter = "" { didSet { invalidateDisplayedItems() } }
    var selectedID: ReadablePortItem.ID? {
        didSet { selectionDidChange() }
    }
    var sortOrder: [ReadablePortSortComparator] = [
        ReadablePortSortComparator(field: .localPort),
        ReadablePortSortComparator(field: .process)
    ] { didSet { invalidateDisplayedItems() } }

    @ObservationIgnored private let portViewModel: PortViewModel
    @ObservationIgnored private var lastSelectedItem: ReadablePortItem?
    @ObservationIgnored private var expiredSelection: ReadablePortItem?
    @ObservationIgnored private var expirationTask: Task<Void, Never>?
    @ObservationIgnored private var cachedRecords: [PortRecord] = []
    @ObservationIgnored private var cachedItems: [ReadablePortItem] = []
    @ObservationIgnored private var cachedDisplayedItems: [ReadablePortItem]?
    @ObservationIgnored private var cachedStateOptions: [String] = []
    @ObservationIgnored private var cachedScopeCounts: [SidebarScope: Int] = [:]

    init(portViewModel: PortViewModel) {
        self.portViewModel = portViewModel
    }

    deinit {
        expirationTask?.cancel()
    }

    var allItems: [ReadablePortItem] {
        let records = portViewModel.records
        if records != cachedRecords {
            cachedRecords = records
            cachedItems = ReadablePortItem.group(records)
            cachedDisplayedItems = nil
            cachedStateOptions = Array(Set(records.compactMap(\.normalizedState))).sorted()

            var counts = Dictionary(uniqueKeysWithValues: SidebarScope.allCases.map { ($0, 0) })
            counts[.all] = records.count
            for record in records {
                if record.isListening {
                    counts[.waiting, default: 0] += 1
                } else if record.isActiveConnection {
                    counts[.connections, default: 0] += 1
                } else {
                    counts[.other, default: 0] += 1
                }
            }
            cachedScopeCounts = counts
        }
        return cachedItems
    }

    var recordIDs: [ReadablePortItem.ID] {
        allItems.map(\.id)
    }

    var selectedItem: ReadablePortItem? {
        guard let selectedID else { return nil }
        return allItems.first { $0.id == selectedID }
            ?? (expiredSelection?.id == selectedID ? expiredSelection : nil)
    }

    var selectionHasEnded: Bool {
        guard let selectedID else { return false }
        return expiredSelection?.id == selectedID && !allItems.contains { $0.id == selectedID }
    }

    var replacementItem: ReadablePortItem? {
        guard selectionHasEnded, let expiredSelection else { return nil }
        return allItems.first {
            $0.pid != expiredSelection.pid
                && $0.transport == expiredSelection.transport
                && $0.localPort == expiredSelection.localPort
        }
    }

    var displayedItems: [ReadablePortItem] {
        let items = allItems
        if let cachedDisplayedItems { return cachedDisplayedItems }

        var filtered = items
            .filter(matchesScope)
            .filter(matchesAccess)
            .filter(matchesOwner)
            .filter(matchesConnectionPhase)
            .filter(matchesProtocol)
            .filter(matchesIPVersion)
            .filter(matchesState)
            .filter(matchesSearch)

        filtered.sort(using: sortOrder)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            cachedDisplayedItems = filtered
            return filtered
        }

        let ranked = filtered.enumerated().sorted { left, right in
            let leftRank = searchRank(for: left.element, query: query)
            let rightRank = searchRank(for: right.element, query: query)
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element)
        cachedDisplayedItems = ranked
        return ranked
    }

    var stateOptions: [String] {
        _ = allItems
        return cachedStateOptions
    }

    var hasActiveFilters: Bool {
        scope != .all
            || accessFilter != .all
            || ownerFilter != .all
            || connectionPhaseFilter != .all
            || protocolFilter != .all
            || ipFilter != .all
            || !stateFilter.isEmpty
    }

    var activeFilterLabels: [String] {
        var labels: [String] = []
        if scope != .all { labels.append(scope.rawValue) }
        if accessFilter != .all { labels.append(accessFilter.rawValue) }
        if ownerFilter != .all { labels.append(ownerFilter.rawValue) }
        if connectionPhaseFilter != .all { labels.append(connectionPhaseFilter.rawValue) }
        if protocolFilter != .all { labels.append(protocolFilter.rawValue) }
        if ipFilter != .all { labels.append(ipFilter.rawValue) }
        if !stateFilter.isEmpty {
            labels.append("\(PortRecord.friendlyStatusTitle(for: stateFilter))（\(stateFilter)）")
        }
        return labels
    }

    var emptyStateTitle: String {
        if !searchText.isEmpty { return "没有找到“\(searchText)”" }
        if hasActiveFilters { return "当前条件下没有网络活动" }
        return scope == .waiting ? "当前没有应用在等待连接" : "当前没有网络活动"
    }

    var emptyStateDescription: String {
        if !searchText.isEmpty {
            return "没有应用名称、端口或进程编号匹配当前搜索与筛选条件。"
        }
        if hasActiveFilters {
            return "没有找到“\(activeFilterLabels.joined(separator: "、"))”的网络活动。"
        }
        return "系统查询没有返回这一类 TCP 或 UDP 记录。"
    }

    func clearFilter(_ label: String) {
        if label == scope.rawValue { scope = .all }
        if label == accessFilter.rawValue { accessFilter = .all }
        if label == ownerFilter.rawValue { ownerFilter = .all }
        if label == connectionPhaseFilter.rawValue { connectionPhaseFilter = .all }
        if label == protocolFilter.rawValue { protocolFilter = .all }
        if label == ipFilter.rawValue { ipFilter = .all }
        if label.contains("（\(stateFilter)）") { stateFilter = "" }
    }

    func resetFilters() {
        scope = .all
        accessFilter = .all
        ownerFilter = .all
        connectionPhaseFilter = .all
        protocolFilter = .all
        ipFilter = .all
        stateFilter = ""
    }

    func clearSearchAndFilters() {
        searchText = ""
        resetFilters()
    }

    func handleExitCommand() {
        if !searchText.isEmpty {
            searchText = ""
        } else if hasActiveFilters {
            resetFilters()
        }
    }

    func select(_ item: ReadablePortItem) {
        selectedID = item.id
        lastSelectedItem = item
        expiredSelection = nil
        expirationTask?.cancel()
    }

    func clearSelection() {
        expirationTask?.cancel()
        expirationTask = nil
        selectedID = nil
        lastSelectedItem = nil
        expiredSelection = nil
    }

    func selectFromMenuBar(_ record: PortRecord) {
        guard let item = allItems.first(where: { candidate in
            candidate.rawRecords.contains { $0.id == record.id }
        }) else { return }
        resetFilters()
        searchText = ""
        select(item)
    }

    func reconcileSelectionAfterRefresh() {
        guard let selectedID else { return }
        if let liveItem = allItems.first(where: { $0.id == selectedID }) {
            lastSelectedItem = liveItem
            expiredSelection = nil
            expirationTask?.cancel()
            return
        }
        if let lastSelectedItem,
           let continuation = allItems.first(where: { candidate in
               candidate.rawRecords.contains { current in
                   lastSelectedItem.rawRecords.contains { previous in
                       current.id == previous.id
                           || (current.pid == previous.pid
                               && current.fileDescriptor == previous.fileDescriptor
                               && current.transport == previous.transport
                               && current.localEndpoint == previous.localEndpoint)
                   }
               }
           }) {
            self.selectedID = continuation.id
            self.lastSelectedItem = continuation
            expiredSelection = nil
            expirationTask?.cancel()
            return
        }
        guard expiredSelection == nil, let lastSelectedItem else { return }

        expiredSelection = lastSelectedItem
        expirationTask?.cancel()
        expirationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self,
                  self.selectedID == selectedID,
                  !self.allItems.contains(where: { $0.id == selectedID }) else { return }
            self.clearSelection()
        }
    }

    func count(for scope: SidebarScope) -> Int {
        _ = allItems
        return cachedScopeCounts[scope] ?? 0
    }

    private func invalidateDisplayedItems() {
        cachedDisplayedItems = nil
    }

    private func selectionDidChange() {
        guard let selectedID else {
            lastSelectedItem = nil
            expiredSelection = nil
            expirationTask?.cancel()
            return
        }
        if let liveItem = allItems.first(where: { $0.id == selectedID }) {
            lastSelectedItem = liveItem
            expiredSelection = nil
            expirationTask?.cancel()
        }
    }

    private func matchesScope(_ item: ReadablePortItem) -> Bool {
        let record = item.representative
        switch scope {
        case .all: return true
        case .waiting: return record.isListening
        case .connections: return record.isActiveConnection
        case .other: return !record.isListening && !record.isActiveConnection
        }
    }

    private func matchesAccess(_ item: ReadablePortItem) -> Bool {
        guard accessFilter == .all || item.representative.isListening else { return false }
        switch accessFilter {
        case .all: return true
        case .localOnly: return item.accessScope == .localOnly
        case .networkPossible: return item.accessScope == .networkPossible
        case .unknown: return item.accessScope == .unknown
        }
    }

    private func matchesOwner(_ item: ReadablePortItem) -> Bool {
        switch ownerFilter {
        case .all: return true
        case .current: return item.representative.belongsToCurrentUser
        case .others: return !item.representative.belongsToCurrentUser
        }
    }

    private func matchesConnectionPhase(_ item: ReadablePortItem) -> Bool {
        guard scope == .connections else { return true }
        switch connectionPhaseFilter {
        case .all: return true
        case .established: return item.activityKind == .connected
        case .transitioning: return item.activityKind == .transitioning
        }
    }

    private func matchesProtocol(_ item: ReadablePortItem) -> Bool {
        switch protocolFilter {
        case .all: return true
        case .tcp: return item.rawRecords.contains { $0.transport == .tcp }
        case .udp: return item.rawRecords.contains { $0.transport == .udp }
        }
    }

    private func matchesIPVersion(_ item: ReadablePortItem) -> Bool {
        switch ipFilter {
        case .all: return true
        case .v4: return item.rawRecords.contains { $0.ipVersion == .v4 }
        case .v6: return item.rawRecords.contains { $0.ipVersion == .v6 }
        }
    }

    private func matchesState(_ item: ReadablePortItem) -> Bool {
        stateFilter.isEmpty || item.rawRecords.contains { $0.normalizedState == stateFilter }
    }

    private func matchesSearch(_ item: ReadablePortItem) -> Bool {
        item.rawRecords.contains { PortSearch.rank(of: $0, query: searchText) != nil }
    }

    private func searchRank(for item: ReadablePortItem, query: String) -> Int {
        item.rawRecords.compactMap { PortSearch.rank(of: $0, query: query) }.min() ?? Int.max
    }
}
