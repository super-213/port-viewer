import AppKit
import SwiftUI

private enum SidebarScope: String, CaseIterable, Identifiable {
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

private enum AccessFilter: String, CaseIterable, Identifiable {
    case all = "全部访问范围"
    case localOnly = "仅这台 Mac"
    case networkPossible = "可能被其他设备访问"
    case unknown = "范围不确定"

    var id: Self { self }
}

private enum OwnerFilter: String, CaseIterable, Identifiable {
    case all = "全部归属"
    case current = "我的应用/服务"
    case others = "其他用户"

    var id: Self { self }
}

private enum ConnectionPhaseFilter: String, CaseIterable, Identifiable {
    case all = "全部连接状态"
    case established = "连接已建立"
    case transitioning = "正在建立/关闭"

    var id: Self { self }
}

private enum ProtocolFilter: String, CaseIterable, Identifiable {
    case all = "全部协议"
    case tcp = "TCP"
    case udp = "UDP"

    var id: Self { self }
}

private enum IPFilter: String, CaseIterable, Identifiable {
    case all = "全部地址格式"
    case v4 = "IPv4"
    case v6 = "IPv6"

    var id: Self { self }
}

struct MainWindowView: View {
    @ObservedObject var store: PortStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scope: SidebarScope = .waiting
    @State private var searchText = ""
    @State private var accessFilter: AccessFilter = .all
    @State private var ownerFilter: OwnerFilter = .all
    @State private var connectionPhaseFilter: ConnectionPhaseFilter = .all
    @State private var protocolFilter: ProtocolFilter = .all
    @State private var ipFilter: IPFilter = .all
    @State private var stateFilter = ""
    @State private var selectedID: ReadablePortItem.ID?
    @State private var lastSelectedItem: ReadablePortItem?
    @State private var expiredSelection: ReadablePortItem?
    @State private var expirationToken = UUID()
    @State private var technicalDetailsExpanded = false
    @State private var sortOrder: [KeyPathComparator<ReadablePortItem>] = [
        KeyPathComparator(\ReadablePortItem.localPortSortValue),
        KeyPathComparator(\ReadablePortItem.processSortValue)
    ]
    @FocusState private var searchIsFocused: Bool

    private var allItems: [ReadablePortItem] {
        ReadablePortItem.group(store.records)
    }

    private var selectedItem: ReadablePortItem? {
        guard let selectedID else { return nil }
        return allItems.first { $0.id == selectedID }
            ?? (expiredSelection?.id == selectedID ? expiredSelection : nil)
    }

    private var selectionHasEnded: Bool {
        guard let selectedID else { return false }
        return expiredSelection?.id == selectedID && !allItems.contains { $0.id == selectedID }
    }

    private var replacementItem: ReadablePortItem? {
        guard selectionHasEnded, let expiredSelection else { return nil }
        return allItems.first {
            $0.pid != expiredSelection.pid
                && $0.transport == expiredSelection.transport
                && $0.localPort == expiredSelection.localPort
        }
    }

    private var displayedItems: [ReadablePortItem] {
        var filtered = allItems
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
        guard !query.isEmpty else { return filtered }

        return filtered.enumerated().sorted { left, right in
            let leftRank = searchRank(for: left.element, query: query)
            let rightRank = searchRank(for: right.element, query: query)
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element)
    }

    private var stateOptions: [String] {
        Array(Set(store.records.compactMap(\.normalizedState))).sorted()
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if let issue = store.state.issueMessage {
                    QueryBanner(message: issue, symbol: "exclamationmark.triangle.fill", color: .orange) {
                        store.refreshNow()
                    }
                } else if store.isPaused {
                    QueryBanner(message: "自动刷新已暂停，当前数据可能已过期。", symbol: "pause.circle.fill", color: .secondary) {
                        store.togglePause()
                    }
                }

                OverviewBar(store: store)
                Divider()
                FilterBar(
                    scope: $scope,
                    accessFilter: $accessFilter,
                    ownerFilter: $ownerFilter,
                    connectionPhaseFilter: $connectionPhaseFilter,
                    protocolFilter: $protocolFilter,
                    ipFilter: $ipFilter,
                    stateFilter: $stateFilter,
                    stateOptions: stateOptions,
                    activeFilterLabels: activeFilterLabels,
                    clearFilter: clearFilter,
                    reset: resetFilters
                )
                Divider()

                tableOrState
                    .frame(minHeight: 230)

                Divider()
                RecordDetailView(
                    item: selectedItem,
                    hasEnded: selectionHasEnded,
                    replacement: replacementItem,
                    allItems: allItems,
                    allRecords: store.records,
                    queryDuration: store.lastQueryDuration,
                    technicalDetailsExpanded: $technicalDetailsExpanded,
                    store: store,
                    onSelectItem: select,
                    onDismissEnded: clearSelection
                )
                .frame(minHeight: 300, idealHeight: 360, maxHeight: 500)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selectedItem?.id)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 720)
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索应用名称或端口，例如 3000")
        .searchFocused($searchIsFocused)
        .toolbar { toolbarContent }
        .onAppear {
            store.setMainWindowVisible(true)
            adoptRequestedSelection(store.requestedSelectionID)
        }
        .onDisappear { store.setMainWindowVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: .focusPortSearch)) { _ in
            searchIsFocused = true
        }
        .onChange(of: store.requestedSelectionID) { _, newValue in
            adoptRequestedSelection(newValue)
        }
        .onChange(of: scope) { _, newValue in
            if newValue != .connections {
                connectionPhaseFilter = .all
            }
        }
        .onChange(of: selectedID) { _, newValue in
            guard let newValue else {
                lastSelectedItem = nil
                expiredSelection = nil
                return
            }
            if let liveItem = allItems.first(where: { $0.id == newValue }) {
                lastSelectedItem = liveItem
                expiredSelection = nil
            }
        }
        .onChange(of: allItems.map(\.id)) { _, _ in
            reconcileSelectionAfterRefresh()
        }
        .onExitCommand {
            if !searchText.isEmpty {
                searchText = ""
            } else if hasActiveFilters {
                resetFilters()
            }
        }
        .alert(item: $store.terminationPrompt) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .destructive(Text(prompt.actionTitle)) {
                    Task { await store.confirmTermination(prompt) }
                }
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let feedback = store.feedback {
                OperationFeedbackBar(feedback: feedback) {
                    store.dismissFeedback()
                }
            }
        }
    }

    private var sidebar: some View {
        List(SidebarScope.allCases, selection: $scope) { item in
            Label {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.rawValue)
                        Text(item.explanation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Text(String(count(for: item)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } icon: {
                Image(systemName: item.symbol)
            }
            .tag(item)
            .accessibilityLabel("\(item.rawValue)，\(count(for: item)) 条。\(item.explanation)")
        }
        .listStyle(.sidebar)
        .navigationTitle("Port Viewer")
        .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 270)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.togglePause()
            } label: {
                Label(store.isPaused ? "继续自动刷新" : "暂停自动刷新", systemImage: store.isPaused ? "play.fill" : "pause.fill")
            }
            .help(store.isPaused ? "继续自动刷新" : "暂停自动刷新")
            .accessibilityLabel(store.isPaused ? "继续自动刷新" : "暂停自动刷新")

            Button {
                store.refreshNow()
            } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
            .help("立即刷新（Command-R）")
            .accessibilityLabel("立即刷新网络活动列表")

            SettingsLink {
                Label("设置", systemImage: "gearshape")
            }
            .help("设置")
        }
    }

    @ViewBuilder
    private var tableOrState: some View {
        if store.state == .loading && store.records.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在查询这台 Mac 的网络活动…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedItems.isEmpty {
            ContentUnavailableView {
                Label(emptyStateTitle, systemImage: searchText.isEmpty ? "tray" : "magnifyingglass")
            } description: {
                Text(emptyStateDescription)
            } actions: {
                if !searchText.isEmpty || hasActiveFilters {
                    Button("清除搜索与筛选") {
                        searchText = ""
                        resetFilters()
                    }
                } else {
                    Button("重新查询") { store.refreshNow() }
                }
            }
        } else {
            PortTable(items: displayedItems, selectedID: $selectedID, sortOrder: $sortOrder)
        }
    }

    private var emptyStateTitle: String {
        if !searchText.isEmpty { return "没有找到“\(searchText)”" }
        if hasActiveFilters { return "当前条件下没有网络活动" }
        return scope == .waiting ? "当前没有应用在等待连接" : "当前没有网络活动"
    }

    private var emptyStateDescription: String {
        if !searchText.isEmpty {
            return "没有应用名称、端口或进程编号匹配当前搜索与筛选条件。"
        }
        if hasActiveFilters {
            return "没有找到“\(activeFilterLabels.joined(separator: "、"))”的网络活动。"
        }
        return "系统查询没有返回这一类 TCP 或 UDP 记录。"
    }

    private var hasActiveFilters: Bool {
        scope != .all
            || accessFilter != .all
            || ownerFilter != .all
            || connectionPhaseFilter != .all
            || protocolFilter != .all
            || ipFilter != .all
            || !stateFilter.isEmpty
    }

    private var activeFilterLabels: [String] {
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

    private func clearFilter(_ label: String) {
        if label == scope.rawValue { scope = .all }
        if label == accessFilter.rawValue { accessFilter = .all }
        if label == ownerFilter.rawValue { ownerFilter = .all }
        if label == connectionPhaseFilter.rawValue { connectionPhaseFilter = .all }
        if label == protocolFilter.rawValue { protocolFilter = .all }
        if label == ipFilter.rawValue { ipFilter = .all }
        if label.contains("（\(stateFilter)）") { stateFilter = "" }
    }

    private func resetFilters() {
        scope = .all
        accessFilter = .all
        ownerFilter = .all
        connectionPhaseFilter = .all
        protocolFilter = .all
        ipFilter = .all
        stateFilter = ""
    }

    private func select(_ item: ReadablePortItem) {
        selectedID = item.id
        lastSelectedItem = item
        expiredSelection = nil
    }

    private func clearSelection() {
        selectedID = nil
        lastSelectedItem = nil
        expiredSelection = nil
        expirationToken = UUID()
    }

    private func adoptRequestedSelection(_ rawRecordID: String?) {
        guard let rawRecordID,
              let item = allItems.first(where: { candidate in
                  candidate.rawRecords.contains { $0.id == rawRecordID }
              }) else { return }
        scope = .all
        searchText = ""
        accessFilter = .all
        ownerFilter = .all
        connectionPhaseFilter = .all
        protocolFilter = .all
        ipFilter = .all
        stateFilter = ""
        select(item)
    }

    private func reconcileSelectionAfterRefresh() {
        guard let selectedID else { return }
        if let liveItem = allItems.first(where: { $0.id == selectedID }) {
            lastSelectedItem = liveItem
            expiredSelection = nil
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
            return
        }
        guard expiredSelection == nil, let lastSelectedItem else { return }

        expiredSelection = lastSelectedItem
        let token = UUID()
        expirationToken = token
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                guard expirationToken == token,
                      self.selectedID == selectedID,
                      !allItems.contains(where: { $0.id == selectedID }) else { return }
                clearSelection()
            }
        }
    }

    private func count(for scope: SidebarScope) -> Int {
        store.records.lazy.filter { record in
            switch scope {
            case .all: return true
            case .waiting: return record.isListening
            case .connections: return record.isActiveConnection
            case .other: return !record.isListening && !record.isActiveConnection
            }
        }.count
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

private struct OverviewBar: View {
    @ObservedObject var store: PortStore
    @State private var help: OverviewHelp?

    private enum OverviewHelp: String, Identifiable {
        case waiting = "等待连接"
        case connections = "连接活动"
        case other = "其他网络活动"
        case port = "什么是端口？"

        var id: Self { self }

        var explanation: String {
            switch self {
            case .waiting: return "TCP 应用开放了编号入口，正在等待其他程序连接。数量来自底层技术记录，不代表风险高低。"
            case .connections: return "应用与另一个地址之间存在建立中、已建立或关闭中的 TCP 连接。"
            case .other: return "包含不保持固定连接状态的 UDP，以及暂时无法归入前两类的网络记录。"
            case .port: return "端口是应用在这台 Mac 上接收或发送网络数据时使用的编号入口。端口号能帮助你找到由哪个应用占用。"
            }
        }
    }

    var body: some View {
        HStack(spacing: 20) {
            metric(.waiting, value: store.listeningCount, symbol: "dot.radiowaves.left.and.right", color: .green)
            metric(.connections, value: store.activeConnectionCount, symbol: "arrow.left.arrow.right", color: .blue)
            metric(.other, value: store.otherNetworkActivityCount, symbol: "antenna.radiowaves.left.and.right", color: .secondary)
            Spacer()
            Text(updateDescription)
                .foregroundStyle(.secondary)
            Button {
                help = .port
            } label: {
                Label("什么是端口？", systemImage: "questionmark.circle")
            }
            .buttonStyle(.link)
            .accessibilityHint("打开端口概念说明")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .popover(item: $help) { topic in
            HelpPopover(title: topic.rawValue, text: topic.explanation)
        }
    }

    private func metric(_ topic: OverviewHelp, value: Int, symbol: String, color: Color) -> some View {
        Button {
            help = topic
        } label: {
            Label("\(topic.rawValue) \(value)", systemImage: symbol)
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help(topic.explanation)
        .accessibilityLabel("\(topic.rawValue)，\(value) 条")
        .accessibilityHint("打开指标说明")
    }

    private var updateDescription: String {
        guard let update = store.lastSuccessfulUpdate else { return "等待首次查询" }
        let elapsed = Date().timeIntervalSince(update)
        if elapsed < 10 { return "刚刚更新" }
        return "已更新 \(update.formatted(.relative(presentation: .named)))"
    }
}

private struct FilterBar: View {
    @Binding var scope: SidebarScope
    @Binding var accessFilter: AccessFilter
    @Binding var ownerFilter: OwnerFilter
    @Binding var connectionPhaseFilter: ConnectionPhaseFilter
    @Binding var protocolFilter: ProtocolFilter
    @Binding var ipFilter: IPFilter
    @Binding var stateFilter: String
    let stateOptions: [String]
    let activeFilterLabels: [String]
    let clearFilter: (String) -> Void
    let reset: () -> Void

    @State private var showsMoreFilters = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("活动类型", selection: $scope) {
                    ForEach(SidebarScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                .accessibilityLabel("活动类型筛选")

                Picker("访问范围", selection: $accessFilter) {
                    ForEach(AccessFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 195)
                .accessibilityLabel("访问范围筛选")

                Picker("归属", selection: $ownerFilter) {
                    ForEach(OwnerFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 155)
                .accessibilityLabel("归属筛选")

                if scope == .connections {
                    Picker("连接状态", selection: $connectionPhaseFilter) {
                        ForEach(ConnectionPhaseFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 155)
                    .accessibilityLabel("连接活动状态筛选")
                }

                Button {
                    showsMoreFilters.toggle()
                } label: {
                    Label("更多筛选", systemImage: "line.3.horizontal.decrease.circle")
                }
                .popover(isPresented: $showsMoreFilters, arrowEdge: .bottom) {
                    MoreFiltersPopover(
                        protocolFilter: $protocolFilter,
                        ipFilter: $ipFilter,
                        stateFilter: $stateFilter,
                        stateOptions: stateOptions
                    )
                }

                Spacer()
                ConceptHelpButton(
                    title: "列表中的信息",
                    text: "“端口”是应用使用的编号入口；“正在做什么”把 TCP 状态转换成中文；“访问范围/连接到”说明谁可能访问监听端口，或当前连接的另一端。"
                )
            }

            if !activeFilterLabels.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(activeFilterLabels, id: \.self) { label in
                            Button {
                                clearFilter(label)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(label)
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("移除筛选：\(label)")
                        }
                        Button("清除全部", action: reset)
                            .buttonStyle(.link)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct MoreFiltersPopover: View {
    @Binding var protocolFilter: ProtocolFilter
    @Binding var ipFilter: IPFilter
    @Binding var stateFilter: String
    let stateOptions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("技术筛选")
                .font(.headline)

            technicalPicker(
                title: "传输方式",
                explanation: "TCP 会建立可靠连接；UDP 不保持固定连接状态。"
            ) {
                Picker("传输方式", selection: $protocolFilter) {
                    ForEach(ProtocolFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }

            technicalPicker(
                title: "地址格式",
                explanation: "IPv4 和 IPv6 是两种网络地址格式，通常不需要手动处理。"
            ) {
                Picker("地址格式", selection: $ipFilter) {
                    ForEach(IPFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }

            technicalPicker(
                title: "原始 TCP 状态",
                explanation: "中文在前，括号中保留系统返回的原始状态代码。"
            ) {
                Picker("原始 TCP 状态", selection: $stateFilter) {
                    Text("全部状态").tag("")
                    ForEach(stateOptions, id: \.self) { state in
                        Text("\(PortRecord.friendlyStatusTitle(for: state))（\(state)）").tag(state)
                    }
                }
                .labelsHidden()
            }
        }
        .padding(18)
        .frame(width: 330)
    }

    private func technicalPicker<Content: View>(
        title: String,
        explanation: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            content()
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PortTable: View {
    let items: [ReadablePortItem]
    @Binding var selectedID: ReadablePortItem.ID?
    @Binding var sortOrder: [KeyPathComparator<ReadablePortItem>]

    var body: some View {
        Table(items, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn("应用/服务", value: \.processSortValue) { item in
                HStack(spacing: 8) {
                    ProcessIconView(record: item.representative, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(item.processName).lineLimit(1)
                            if !item.representative.belongsToCurrentUser {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help("其他用户的应用/服务")
                            }
                            if ProcessProtectionPolicy.isCritical(item.representative) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help("关键系统进程")
                            }
                        }
                        if let groupText = item.containsTechnicalRecordText {
                            Text(groupText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .width(min: 180, ideal: 230)

            TableColumn("端口", value: \.localPortSortValue) { item in
                Text(item.localPortText)
                    .font(.system(.body, design: .monospaced, weight: .medium))
            }
            .width(min: 70, ideal: 90, max: 110)

            TableColumn("正在做什么", value: \.statusSortValue) { item in
                FriendlyStatusLabel(item: item)
            }
            .width(min: 130, ideal: 165)

            TableColumn("访问范围/连接到", value: \.connectionSortValue) { item in
                ConnectionDisplayLabel(item: item)
            }
            .width(min: 210, ideal: 280)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityLabel("应用、端口和网络活动列表")
    }
}

struct ProcessIconView: View {
    let record: PortRecord
    let size: CGFloat

    var body: some View {
        Group {
            if let path = record.executablePath,
               FileManager.default.fileExists(atPath: path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
            } else {
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
                    .padding(2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct FriendlyStatusLabel: View {
    let item: ReadablePortItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
            Text(item.friendlyStatusTitle)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在做什么：\(item.friendlyStatusTitle)")
        .help(item.representative.friendlyStatusExplanation)
    }

    private var symbol: String {
        switch item.activityKind {
        case .waiting: return "circle.fill"
        case .connected: return "arrow.left.arrow.right"
        case .transitioning: return "progress.indicator"
        case .other: return item.transport == .udp ? "circle.dotted" : "questionmark.circle"
        }
    }

    private var color: Color {
        switch item.activityKind {
        case .waiting: return .green
        case .connected: return .blue
        case .transitioning: return .secondary
        case .other: return .secondary
        }
    }
}

private struct ConnectionDisplayLabel: View {
    let item: ReadablePortItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(item.connectionDisplay)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(helpText)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if item.representative.isListening {
            switch item.accessScope {
            case .localOnly: return "laptopcomputer"
            case .networkPossible: return "network"
            case .unknown: return "questionmark.circle"
            }
        }
        return item.representative.remoteAddress == nil ? "questionmark.circle" : "arrow.up.right"
    }

    private var color: Color {
        item.representative.isListening && item.accessScope == .networkPossible ? .orange : .secondary
    }

    private var helpText: String {
        item.representative.isListening ? item.accessScope.explanation : item.textualRelationshipDescription
    }
}

private struct RecordDetailView: View {
    let item: ReadablePortItem?
    let hasEnded: Bool
    let replacement: ReadablePortItem?
    let allItems: [ReadablePortItem]
    let allRecords: [PortRecord]
    let queryDuration: TimeInterval?
    @Binding var technicalDetailsExpanded: Bool
    @ObservedObject var store: PortStore
    let onSelectItem: (ReadablePortItem) -> Void
    let onDismissEnded: () -> Void

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if hasEnded {
                            endedBanner(for: item)
                        }

                        Text(item.conclusion)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)

                        ConnectionDiagramView(item: item)

                        meaningSection(for: item)

                        TechnicalDetailsView(
                            item: item,
                            allItems: allItems,
                            allRecords: allRecords,
                            queryDuration: queryDuration,
                            isExpanded: $technicalDetailsExpanded,
                            onSelectItem: onSelectItem
                        )

                        actionSection(for: item)
                    }
                    .padding(18)
                }
            } else {
                TeachingEmptyDetail()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func endedBanner(for item: ReadablePortItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("这项网络活动已结束")
                    .font(.headline)
                if let replacement {
                    Text("原活动已结束，但端口现在由 \(replacement.processName) 使用。")
                        .font(.callout)
                } else {
                    Text("下面暂时保留最后一次看到的信息，方便你理解发生了什么。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onDismissEnded) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("关闭已结束活动的详情")
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private func meaningSection(for item: ReadablePortItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这意味着什么")
                .font(.headline)
            ForEach(explanations(for: item), id: \.self) { explanation in
                Label(explanation.text, systemImage: explanation.symbol)
                    .font(.callout)
                    .foregroundStyle(explanation.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func explanations(for item: ReadablePortItem) -> [MeaningExplanation] {
        var values = item.meaningMessages.map {
            MeaningExplanation(text: $0, symbol: "info.circle", color: Color.secondary)
        }
        let record = item.representative
        if !record.belongsToCurrentUser {
            values.append(.init(text: "这是其他用户的进程，当前版本不能直接结束它。", symbol: "lock.fill", color: .orange))
        }
        if ProcessProtectionPolicy.isCritical(record) {
            values.append(.init(text: "这是关键系统进程，结束它可能影响系统功能；强制结束已禁用。", symbol: "exclamationmark.shield.fill", color: .orange))
        }
        return Array(values.prefix(3))
    }

    private func actionSection(for item: ReadablePortItem) -> some View {
        let record = item.representative
        let otherCount = allRecords.filter { $0.pid == record.pid && !item.rawRecords.contains($0) }.count
        let isAllowed = record.belongsToCurrentUser && !hasEnded

        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("操作影响")
                    .font(.callout.weight(.medium))
                Text(otherCount > 0
                     ? "结束后，这个应用使用的其他 \(otherCount) 个端口或连接也会关闭。"
                     : "结束的是整个进程；操作前会再次确认它仍在使用这个端口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("结束进程…", role: .destructive) {
                Task { await store.prepareToTerminate(record) }
            }
            .disabled(store.isRefreshing || !isAllowed)
            .help(terminationHelp(for: record))
            .accessibilityHint(terminationHelp(for: record))
        }
        .padding(.top, 2)
    }

    private func terminationHelp(for record: PortRecord) -> String {
        if hasEnded { return "这项活动已经结束" }
        if !record.belongsToCurrentUser { return "该进程属于其他用户，当前版本不会申请管理员权限" }
        return "操作前会重新校验进程和端口，并显示确认对话框"
    }
}

private struct MeaningExplanation: Hashable {
    let text: String
    let symbol: String
    let colorName: String

    init(text: String, symbol: String, color: Color) {
        self.text = text
        self.symbol = symbol
        if color == .orange {
            colorName = "orange"
        } else {
            colorName = "secondary"
        }
    }

    var color: Color { colorName == "orange" ? .orange : .secondary }
}

private struct ConnectionDiagramView: View {
    let item: ReadablePortItem
    @State private var selectedNodeID: String?

    private var nodes: [RelationshipNode] {
        let record = item.representative
        if record.isListening {
            let sourceTitle: String
            let sourceSubtitle: String
            switch item.accessScope {
            case .localOnly:
                sourceTitle = "这台 Mac"
                sourceSubtitle = "本机应用"
            case .networkPossible:
                sourceTitle = "这台 Mac / 同一网络"
                sourceSubtitle = "其他设备可能可访问"
            case .unknown:
                sourceTitle = "访问来源"
                sourceSubtitle = "暂不确定"
            }
            return [
                .init(id: "source", title: sourceTitle, subtitle: sourceSubtitle, symbol: "laptopcomputer.and.arrow.down", explanation: item.accessScope.explanation),
                .init(id: "port", title: "这台 Mac", subtitle: "端口 \(item.localPortText)", symbol: "rectangle.connected.to.line.below", explanation: "这是该应用在本机使用的编号入口。"),
                .init(id: "app", title: item.processName, subtitle: "应用/服务", symbol: "app.dashed", explanation: "这个应用或后台服务正在使用该端口。")
            ]
        }

        let target = record.remoteAddress == nil ? "可能的通信对象" : record.remoteAddress ?? "连接对象未知"
        let targetPort = record.remotePort.map { "端口 \($0)" } ?? (record.remoteAddress == nil ? "无固定对象" : "端口未知")
        return [
            .init(id: "app", title: item.processName, subtitle: "应用/服务", symbol: "app.dashed", explanation: "这个应用或后台服务正在进行网络活动。"),
            .init(id: "port", title: "这台 Mac", subtitle: "\(record.transport.rawValue) 端口 \(item.localPortText)", symbol: "rectangle.connected.to.line.below", explanation: "这是该应用当前在本机使用的端口。"),
            .init(id: "target", title: target, subtitle: targetPort, symbol: "network", explanation: record.remoteAddress == nil ? "系统没有提供固定的连接对象。" : "这是系统返回的另一端地址；不会据此推断网站、位置或安全性。")
        ]
    }

    private var connectors: [RelationshipConnector] {
        let record = item.representative
        if record.isListening {
            return [
                .init(label: item.accessScope == .networkPossible ? "可能可访问" : "可以尝试连接", bidirectional: false, dashed: item.accessScope != .localOnly),
                .init(label: "等待连接", bidirectional: false, dashed: false)
            ]
        }
        if record.transport == .udp {
            return [
                .init(label: "发送或接收", bidirectional: true, dashed: false),
                .init(label: record.remoteAddress == nil ? "对象不固定" : "通信对象", bidirectional: true, dashed: record.remoteAddress == nil)
            ]
        }
        return [
            .init(label: "存在连接", bidirectional: true, dashed: false),
            .init(label: item.friendlyStatusTitle, bidirectional: true, dashed: false)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    RelationshipNodeView(node: nodes[0], selectedNodeID: $selectedNodeID)
                    HorizontalConnectorView(connector: connectors[0])
                    RelationshipNodeView(node: nodes[1], selectedNodeID: $selectedNodeID)
                    HorizontalConnectorView(connector: connectors[1])
                    RelationshipNodeView(node: nodes[2], selectedNodeID: $selectedNodeID)
                }

                VStack(spacing: 8) {
                    RelationshipNodeView(node: nodes[0], selectedNodeID: $selectedNodeID)
                    VerticalConnectorView(connector: connectors[0])
                    RelationshipNodeView(node: nodes[1], selectedNodeID: $selectedNodeID)
                    VerticalConnectorView(connector: connectors[1])
                    RelationshipNodeView(node: nodes[2], selectedNodeID: $selectedNodeID)
                }
            }
            .frame(maxWidth: .infinity)

            if let selectedNodeID, let node = nodes.first(where: { $0.id == selectedNodeID }) {
                Label(node.explanation, systemImage: node.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Text(item.textualRelationshipDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(item.textualRelationshipDescription)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.conclusion)
    }
}

private struct RelationshipNode {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let explanation: String
}

private struct RelationshipConnector {
    let label: String
    let bidirectional: Bool
    let dashed: Bool
}

private struct RelationshipNodeView: View {
    let node: RelationshipNode
    @Binding var selectedNodeID: String?

    var body: some View {
        Button {
            selectedNodeID = node.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: node.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(node.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 11)
            .frame(width: 170, alignment: .leading)
            .frame(minHeight: 58, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(selectedNodeID == node.id ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selectedNodeID == node.id ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .help(node.explanation)
        .accessibilityLabel("\(node.title)，\(node.subtitle)。\(node.explanation)")
        .accessibilityHint("显示这个节点的解释")
    }
}

private struct HorizontalConnectorView: View {
    let connector: RelationshipConnector

    var body: some View {
        VStack(spacing: 3) {
            Text(connector.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 2) {
                if connector.bidirectional {
                    Image(systemName: "arrowtriangle.left.fill")
                        .font(.system(size: 6))
                }
                GeometryReader { proxy in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
                    }
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 1.4, dash: connector.dashed ? [5, 4] : []))
                }
                .frame(height: 8)
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 6))
            }
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 70, idealWidth: 100, maxWidth: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(connector.label)\(connector.dashed ? "，虚线表示可能关系" : "")")
    }
}

private struct VerticalConnectorView: View {
    let connector: RelationshipConnector

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: connector.bidirectional ? "arrow.up.arrow.down" : "arrow.down")
            Text(connector.label)
                .font(.caption2)
            if connector.dashed {
                Text("可能")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct TechnicalDetailsView: View {
    let item: ReadablePortItem
    let allItems: [ReadablePortItem]
    let allRecords: [PortRecord]
    let queryDuration: TimeInterval?
    @Binding var isExpanded: Bool
    let onSelectItem: (ReadablePortItem) -> Void

    private var record: PortRecord { item.representative }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 18) {
                technicalGroup("进程信息", fields: processFields)
                technicalGroup("连接信息", fields: connectionFields)
                technicalGroup("系统信息", fields: systemFields)

                if item.rawRecords.count > 1 {
                    rawRecordsSection
                }

                let others = allItems.filter { $0.pid == item.pid && $0.id != item.id }
                if !others.isEmpty {
                    otherActivitiesSection(others)
                }
            }
            .padding(.top, 12)
        } label: {
            Label("技术详情", systemImage: "wrench.and.screwdriver")
                .font(.headline)
        }
        .accessibilityHint(isExpanded ? "折叠完整技术参数" : "展开 PID、协议、地址、路径等完整技术参数")
    }

    private var processFields: [TechnicalField] {
        [
            .init(title: "应用/服务", value: record.processName, explanation: "正在使用网络的应用、后台服务或系统进程", monospaced: false),
            .init(title: "进程编号", value: String(record.pid), explanation: "系统分配的临时编号，主要用于精确识别和排障"),
            .init(title: "归属用户", value: record.user, explanation: "启动该进程的 macOS 用户", monospaced: false),
            .init(title: "启动来源", value: parentProcessDescription, explanation: "启动当前进程的上一级进程", monospaced: false),
            .init(title: "程序位置", value: record.executablePath ?? "无法获取", explanation: "当前进程对应程序文件在磁盘上的位置", monospaced: false)
        ]
    }

    private var connectionFields: [TechnicalField] {
        [
            .init(title: "传输与地址格式", value: record.protocolDisplay, explanation: "TCP/UDP 是传输方式，IPv4/IPv6 是地址格式", monospaced: false),
            .init(title: "这台 Mac 的地址和端口", value: record.localEndpoint, explanation: "当前进程在本机使用的原始网络地址与端口"),
            .init(title: "连接对象", value: record.remoteEndpoint, explanation: "另一端的原始地址与端口；不能据此判断此刻是否有数据传输"),
            .init(title: "原始 TCP 状态", value: record.normalizedState ?? "无（UDP 或系统未提供）", explanation: record.friendlyStatusExplanation)
        ]
    }

    private var systemFields: [TechnicalField] {
        [
            .init(title: "系统连接编号", value: record.fileDescriptor, explanation: "进程内部标识这条网络资源的编号"),
            .init(title: "数据更新时间", value: record.updatedAt.formatted(date: .abbreviated, time: .standard), explanation: "应用上次确认这条记录存在的精确时间", monospaced: false),
            .init(title: "底层记录数量", value: String(item.rawRecords.count), explanation: "当前易读项目包含的原始系统记录数量"),
            .init(title: "本次查询耗时", value: queryDuration.map { String(format: "%.0f ms", $0 * 1_000) } ?? "无法获取", explanation: "系统工具完成最近一次查询所用时间")
        ]
    }

    private var parentProcessDescription: String {
        guard let parentPID = record.parentPID else { return "无法获取" }
        if let parent = allRecords.first(where: { $0.pid == parentPID }) {
            return "\(parent.processName)（PID \(parentPID)）"
        }
        return "PID \(parentPID)"
    }

    private func technicalGroup(_ title: String, fields: [TechnicalField]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(field.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(field.value)
                            .font(field.monospaced ? .system(.callout, design: .monospaced) : .callout)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(field.explanation)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var rawRecordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("合并的技术记录")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(item.rawRecords) { raw in
                Text("\(raw.ipVersion.rawValue) · \(raw.transport.rawValue) · \(raw.localEndpoint) · \(raw.remoteEndpoint) · \(raw.normalizedState ?? "无状态") · FD \(raw.fileDescriptor)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func otherActivitiesSection(_ items: [ReadablePortItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("同一进程的其他活动")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items.prefix(8)) { other in
                Button {
                    onSelectItem(other)
                } label: {
                    HStack {
                        Text("\(other.transport.rawValue) 端口 \(other.localPortText)")
                            .font(.system(.callout, design: .monospaced))
                        Text(other.friendlyStatusTitle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("切换到这项网络活动")
            }
        }
    }
}

private struct TechnicalField: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let explanation: String
    var monospaced = true
}

private struct TeachingEmptyDetail: View {
    @State private var showsPortHelp = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("选择一项，我会解释它正在做什么")
                .font(.headline)
            Text("你会看到应用、端口、连接关系和访问范围。专业参数仍可在“技术详情”中查看。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("先了解什么是端口") {
                showsPortHelp = true
            }
            .buttonStyle(.link)
            .popover(isPresented: $showsPortHelp) {
                HelpPopover(
                    title: "什么是端口？",
                    text: "端口是应用在这台 Mac 上接收或发送网络数据时使用的编号入口。选择列表中的一项后，Port Viewer 会说明哪个应用正在使用它，以及谁可能访问。"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct ConceptHelpButton: View {
    let title: String
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel("说明：\(title)")
        .popover(isPresented: $isPresented) {
            HelpPopover(title: title, text: text)
        }
    }
}

private struct HelpPopover: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }
}

private struct QueryBanner: View {
    let message: String
    let symbol: String
    let color: Color
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(message)
                .lineLimit(2)
            Spacer()
            Button("重试", action: action)
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(color.opacity(0.10))
        .accessibilityElement(children: .contain)
    }
}

private struct OperationFeedbackBar: View {
    let feedback: OperationFeedback
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(feedback.message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("关闭操作结果")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 42)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch feedback.kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .information: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch feedback.kind {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .information: return .blue
        }
    }
}
