import AppKit
import SwiftUI

struct MainWindowView: View {
    @Bindable var portViewModel: PortViewModel
    @Bindable var viewModel: MainWindowViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var technicalDetailsExpanded = false
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if let issue = portViewModel.state.issueMessage {
                    QueryBanner(message: issue, symbol: "exclamationmark.triangle.fill", color: .orange) {
                        portViewModel.refreshNow()
                    }
                } else if portViewModel.isPaused {
                    QueryBanner(message: "自动刷新已暂停，当前数据可能已过期。", symbol: "pause.circle.fill", color: .secondary) {
                        portViewModel.togglePause()
                    }
                }

                OverviewBar(portViewModel: portViewModel)
                Divider()
                FilterBar(
                    scope: $viewModel.scope,
                    accessFilter: $viewModel.accessFilter,
                    ownerFilter: $viewModel.ownerFilter,
                    connectionPhaseFilter: $viewModel.connectionPhaseFilter,
                    protocolFilter: $viewModel.protocolFilter,
                    ipFilter: $viewModel.ipFilter,
                    stateFilter: $viewModel.stateFilter,
                    stateOptions: viewModel.stateOptions,
                    activeFilterLabels: viewModel.activeFilterLabels,
                    clearFilter: viewModel.clearFilter,
                    reset: viewModel.resetFilters
                )
                Divider()

                tableOrState
                    .frame(minHeight: 230)

                Divider()
                RecordDetailView(
                    item: viewModel.selectedItem,
                    hasEnded: viewModel.selectionHasEnded,
                    replacement: viewModel.replacementItem,
                    allItems: viewModel.allItems,
                    allRecords: portViewModel.records,
                    queryDuration: portViewModel.lastQueryDuration,
                    lastSuccessfulUpdate: portViewModel.lastSuccessfulUpdate,
                    technicalDetailsExpanded: $technicalDetailsExpanded,
                    portViewModel: portViewModel,
                    onSelectItem: viewModel.select,
                    onDismissEnded: viewModel.clearSelection
                )
                .frame(minHeight: 300, idealHeight: 360, maxHeight: 500)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: viewModel.selectedItem?.id)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 720)
        .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: "搜索应用名称或端口，例如 3000")
        .searchFocused($searchIsFocused)
        .toolbar { toolbarContent }
        .onAppear {
            portViewModel.setMainWindowVisible(true)
        }
        .onDisappear { portViewModel.setMainWindowVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: .focusPortSearch)) { _ in
            searchIsFocused = true
        }
        .onChange(of: viewModel.recordIDs) { _, _ in
            viewModel.reconcileSelectionAfterRefresh()
        }
        .onExitCommand(perform: viewModel.handleExitCommand)
        .alert(item: $portViewModel.terminationPrompt) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .destructive(Text(prompt.actionTitle)) {
                    portViewModel.confirmTermination(prompt)
                }
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let feedback = portViewModel.feedback {
                OperationFeedbackBar(feedback: feedback) {
                    portViewModel.dismissFeedback()
                }
            }
        }
    }

    private var sidebar: some View {
        List(SidebarScope.allCases, selection: $viewModel.scope) { item in
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
                    Text(String(viewModel.count(for: item)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } icon: {
                Image(systemName: item.symbol)
            }
            .tag(item)
            .accessibilityLabel("\(item.rawValue)，\(viewModel.count(for: item)) 条。\(item.explanation)")
        }
        .listStyle(.sidebar)
        .navigationTitle("Port Viewer")
        .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 270)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                portViewModel.togglePause()
            } label: {
                Label(portViewModel.isPaused ? "继续自动刷新" : "暂停自动刷新", systemImage: portViewModel.isPaused ? "play.fill" : "pause.fill")
            }
            .help(portViewModel.isPaused ? "继续自动刷新" : "暂停自动刷新")
            .accessibilityLabel(portViewModel.isPaused ? "继续自动刷新" : "暂停自动刷新")

            Button {
                portViewModel.refreshNow()
            } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
            .disabled(portViewModel.isRefreshing)
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
        if portViewModel.state == .loading && portViewModel.records.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在查询这台 Mac 的网络活动…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.displayedItems.isEmpty {
            ContentUnavailableView {
                Label(viewModel.emptyStateTitle, systemImage: viewModel.searchText.isEmpty ? "tray" : "magnifyingglass")
            } description: {
                Text(viewModel.emptyStateDescription)
            } actions: {
                if !viewModel.searchText.isEmpty || viewModel.hasActiveFilters {
                    Button("清除搜索与筛选") {
                        viewModel.clearSearchAndFilters()
                    }
                } else {
                    Button("重新查询") { portViewModel.refreshNow() }
                }
            }
        } else {
            PortTable(
                items: viewModel.displayedItems,
                allItems: viewModel.allItems,
                portViewModel: portViewModel,
                selectedID: $viewModel.selectedID,
                sortOrder: $viewModel.sortOrder
            )
        }
    }
}

private struct OverviewBar: View {
    let portViewModel: PortViewModel
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
            case .port: return "本机端口是应用在这台 Mac 上收发网络数据时使用的编号。服务端口用于等待连接；应用连接其他服务时也会使用本机连接端口。相同端口不一定是同一连接，多个连接端口也不代表应用对外开放了多个服务。"
            }
        }
    }

    var body: some View {
        HStack(spacing: 20) {
            metric(.waiting, value: portViewModel.listeningCount, symbol: "dot.radiowaves.left.and.right", color: .green)
            metric(.connections, value: portViewModel.activeConnectionCount, symbol: "arrow.left.arrow.right", color: .blue)
            metric(.other, value: portViewModel.otherNetworkActivityCount, symbol: "antenna.radiowaves.left.and.right", color: .secondary)
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
        guard let update = portViewModel.lastSuccessfulUpdate else { return "等待首次查询" }
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
                    text: "“本机端口”是应用在这台 Mac 上使用的编号；服务端口用于等待连接，连接端口用于连接其他服务。“正在做什么”把 TCP 状态转换成中文；“访问范围/连接到”说明谁可能访问监听端口，或当前连接的另一端。"
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
    let allItems: [ReadablePortItem]
    let portViewModel: PortViewModel
    @Binding var selectedID: ReadablePortItem.ID?
    @Binding var sortOrder: [ReadablePortSortComparator]
    @State private var expandedProcessGroups: Set<ReadablePortItem.ID> = []

    var body: some View {
        Table(items, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn("应用/服务", sortUsing: ReadablePortSortComparator(field: .process)) { item in
                HStack(alignment: .top, spacing: 7) {
                    if item.processCount > 1 {
                        Button {
                            if expandedProcessGroups.contains(item.id) {
                                expandedProcessGroups.remove(item.id)
                            } else {
                                expandedProcessGroups.insert(item.id)
                            }
                        } label: {
                            Image(systemName: expandedProcessGroups.contains(item.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 12, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help(expandedProcessGroups.contains(item.id) ? "收起组成此服务的进程" : "展开组成此服务的进程")
                        .accessibilityLabel(expandedProcessGroups.contains(item.id) ? "收起进程列表" : "展开进程列表")
                    }
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
                        ActivitySummaryBadges(
                            item: item,
                            listenerProcessCount: listenerProcessCount(for: item)
                        )
                        if expandedProcessGroups.contains(item.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(item.processSummaries) { process in
                                    HStack(spacing: 4) {
                                        Image(systemName: "person.crop.circle")
                                        Text(process.processName + " · PID " + String(process.pid))
                                            .lineLimit(1)
                                        if process.recordCount > 1 {
                                            Text("\(process.recordCount) 条")
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                            .transition(.opacity)
                        }
                    }
                }
            }
            .width(min: 180, ideal: 230)

            TableColumn("本机端口", sortUsing: ReadablePortSortComparator(field: .localPort)) { item in
                CompactPortClusterView(item: item)
                .help(localPortHelp(for: item))
                .accessibilityLabel(localPortHelp(for: item))
            }
            .width(min: 105, ideal: 135, max: 165)

            TableColumn("正在做什么", sortUsing: ReadablePortSortComparator(field: .status)) { item in
                PortStatusCell(item: item, portViewModel: portViewModel)
            }
            .width(min: 155, ideal: 205)

            TableColumn("访问范围/连接到", sortUsing: ReadablePortSortComparator(field: .connection)) { item in
                CompactTopologyView(
                    item: item,
                    listenerProcessCount: listenerProcessCount(for: item)
                )
            }
            .width(min: 230, ideal: 300)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityLabel("应用、本机端口和网络活动列表")
    }

    private func listenerProcessCount(for item: ReadablePortItem) -> Int {
        guard item.representative.isListening else { return 0 }
        let itemPorts = Set(item.localPorts)
        return Set(allItems.filter { candidate in
            candidate.representative.isListening
                && candidate.transport == item.transport
                && !Set(candidate.localPorts).isDisjoint(with: itemPorts)
        }.flatMap(\.rawRecords).map(\.pid)).count
    }

    private func localPortHelp(for item: ReadablePortItem) -> String {
        if item.representative.isListening {
            if item.localPorts.count > 1 {
                let ports = item.localPorts.map(String.init).joined(separator: "、")
                return "应用正在通过 \(item.localPorts.count) 个服务端口等待连接：\(ports)。同一应用可以为不同功能使用多个服务端口。"
            }
            return "服务端口 \(item.localPortText)：应用在这里等待其他程序连接。"
        }
        if item.isConnectionSummary {
            let ports = item.localPorts.map(String.init).joined(separator: "、")
            if item.localPorts.count > 1 {
                return "应用通过 \(item.localPorts.count) 个本机连接端口建立网络连接：\(ports)。这些端口不表示对外开放的服务。"
            }
            return "本机连接端口 \(item.localPortText)：它用于区分这组连接，不表示应用正在对外提供服务。"
        }
        return "\(item.localPortRoleText) \(item.localPortText)。"
    }
}

@MainActor
private final class ProcessIconCache {
    static let shared = ProcessIconCache()

    private let images = NSCache<NSString, NSImage>()

    private init() {
        images.countLimit = 256
    }

    func icon(forExecutablePath path: String) -> NSImage? {
        let key = path as NSString
        if let image = images.object(forKey: key) {
            return image
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        images.setObject(image, forKey: key)
        return image
    }
}

struct ProcessIconView: View {
    let record: PortRecord
    let size: CGFloat

    var body: some View {
        Group {
            if let path = record.executablePath,
               let icon = ProcessIconCache.shared.icon(forExecutablePath: path) {
                Image(nsImage: icon)
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

private struct PortStatusCell: View {
    let item: ReadablePortItem
    let portViewModel: PortViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activitySummary: ListenerActivitySummary? {
        portViewModel.listenerActivitySummary(for: item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            FriendlyStatusLabel(item: item)
            if let activitySummary, let description = activitySummary.inlineDescription {
                Label(description, systemImage: "arrow.left.arrow.right.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(activityColor(for: activitySummary))
                    .lineLimit(1)
                    .transition(.opacity)
                    .accessibilityLabel(activitySummary.accessibilityDescription)
            }
        }
        .frame(minHeight: 34, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: activitySummary)
    }

    private func activityColor(for summary: ListenerActivitySummary) -> Color {
        if case .ended = summary.recentChange?.kind, summary.connectionCount == 0 {
            return .secondary
        }
        return .blue
    }
}

private struct ActivitySummaryBadges: View {
    let item: ReadablePortItem
    let listenerProcessCount: Int

    var body: some View {
        HStack(spacing: 4) {
            if item.representative.isListening, item.localPorts.count > 1 {
                ActivityMetricBadge(
                    value: item.localPorts.count,
                    symbol: "rectangle.stack.fill",
                    color: .green,
                    accessibilityText: "\(item.localPorts.count) 个服务端口"
                )
            } else if item.isConnectionSummary, item.connectionCount > 1 {
                ActivityMetricBadge(
                    value: item.connectionCount,
                    symbol: "link",
                    color: .blue,
                    accessibilityText: "\(item.connectionCount) 条连接"
                )
                ActivityMetricBadge(
                    value: item.remoteTargetCount,
                    symbol: "network",
                    color: .blue,
                    accessibilityText: "\(item.remoteTargetCount) 个连接目标"
                )
            } else if item.rawRecords.count > 1, item.processCount == 1 {
                ActivityMetricBadge(
                    value: item.rawRecords.count,
                    symbol: "doc.on.doc",
                    color: .secondary,
                    accessibilityText: "\(item.rawRecords.count) 条技术记录"
                )
            }

            if listenerProcessCount > 1 {
                ActivityMetricBadge(
                    value: listenerProcessCount,
                    symbol: "person.2.fill",
                    color: .secondary,
                    accessibilityText: "共 \(listenerProcessCount) 个进程使用其中端口"
                )
            }
        }
    }
}

private struct ActivityMetricBadge: View {
    let value: Int
    let symbol: String
    let color: Color
    let accessibilityText: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(String(value))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.1), in: Capsule())
        .overlay { Capsule().stroke(color.opacity(0.22), lineWidth: 0.7) }
        .help(accessibilityText)
        .accessibilityLabel(accessibilityText)
    }
}

private struct CompactPortClusterView: View {
    let item: ReadablePortItem

    private var color: Color {
        if item.representative.isListening { return .green }
        if item.isConnectionSummary { return .blue }
        return .secondary
    }

    private var symbol: String {
        item.representative.isListening ? "rectangle.inset.filled.and.person.filled" : "point.3.connected.trianglepath.dotted"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                ForEach(Array(item.localPorts.prefix(2)), id: \.self) { port in
                    Text(":" + String(port))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(color.opacity(0.28), lineWidth: 0.8)
                        }
                }
                if item.localPorts.count > 2 {
                    Text("+\(item.localPorts.count - 2)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.12), in: Capsule())
                }
                if item.localPorts.isEmpty {
                    Text("*")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            Label(item.localPortRoleText, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
    }
}

private struct CompactTopologyView: View {
    let item: ReadablePortItem
    let listenerProcessCount: Int

    var body: some View {
        HStack(spacing: 6) {
            if item.representative.isListening {
                CompactTopologyNode(
                    symbol: sourceSymbol,
                    count: item.accessScope == .networkPossible ? 2 : 1,
                    label: sourceLabel,
                    color: sourceColor
                )
                CompactTopologyArrow(symbol: "arrow.right", color: sourceColor)
                CompactTopologyNode(
                    symbol: "rectangle.stack.fill",
                    count: item.localPorts.count,
                    label: item.localPorts.count > 1 ? "服务端口" : item.localPortText,
                    color: .green
                )
                if listenerProcessCount > 1 {
                    CompactTopologyArrow(symbol: "arrow.right", color: .secondary)
                    CompactTopologyNode(
                        symbol: "person.2.fill",
                        count: listenerProcessCount,
                        label: "进程共享",
                        color: .secondary
                    )
                }
            } else {
                CompactTopologyNode(
                    symbol: "rectangle.connected.to.line.below",
                    count: max(item.localPorts.count, 1),
                    label: item.localPorts.count > 1 ? "本机端口" : item.localPortText,
                    color: item.isConnectionSummary ? .blue : .secondary
                )
                CompactTopologyArrow(
                    symbol: item.transport == .udp ? "arrow.left.and.right" : "arrow.left.arrow.right",
                    color: item.isConnectionSummary ? .blue : .secondary
                )
                CompactTopologyNode(
                    symbol: item.remoteTargetCount > 0 ? "network" : "questionmark",
                    count: max(item.remoteTargetCount, 1),
                    label: targetLabel,
                    color: item.isConnectionSummary ? .blue : .secondary
                )
            }
        }
        .help(item.representative.isListening ? item.accessScope.explanation : item.textualRelationshipDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.textualRelationshipDescription)
    }

    private var sourceSymbol: String {
        switch item.accessScope {
        case .localOnly: return "laptopcomputer"
        case .networkPossible: return "network"
        case .unknown: return "questionmark"
        }
    }

    private var sourceLabel: String {
        switch item.accessScope {
        case .localOnly: return "仅本机"
        case .networkPossible: return "本机/网络"
        case .unknown: return "来源未知"
        }
    }

    private var sourceColor: Color { item.accessScope == .networkPossible ? .orange : .secondary }

    private var targetLabel: String {
        if item.remoteTargetCount > 1 { return "\(item.remoteTargetCount) 个目标" }
        if let endpoint = item.remoteEndpoints.first { return endpoint }
        return "对象不固定"
    }
}

private struct CompactTopologyNode: View {
    let symbol: String
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.opacity(0.1))
                    .frame(width: 28, height: 26)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(color.opacity(0.25), lineWidth: 0.8)
                    }
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 26)
                if count > 1 {
                    Text(String(count))
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 12, minHeight: 12)
                        .background(color, in: Circle())
                        .offset(x: 5, y: -5)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minWidth: 48, maxWidth: 100, alignment: .leading)
    }
}

private struct CompactTopologyArrow: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color.opacity(0.75))
            .accessibilityHidden(true)
    }
}

private struct RecordDetailView: View {
    let item: ReadablePortItem?
    let hasEnded: Bool
    let replacement: ReadablePortItem?
    let allItems: [ReadablePortItem]
    let allRecords: [PortRecord]
    let queryDuration: TimeInterval?
    let lastSuccessfulUpdate: Date?
    @Binding var technicalDetailsExpanded: Bool
    let portViewModel: PortViewModel
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

                        Label("活动关系", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)

                        ConnectionDiagramView(
                            item: item,
                            relatedListenerItems: relatedListenerItems(for: item)
                        )

                        Text(item.conclusion)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let activitySummary = portViewModel.listenerActivitySummary(for: item) {
                            ListenerPortActivityView(summary: activitySummary)
                        }

                        meaningSection(for: item)

                        TechnicalDetailsView(
                            item: item,
                            allItems: allItems,
                            allRecords: allRecords,
                            queryDuration: queryDuration,
                            lastSuccessfulUpdate: lastSuccessfulUpdate,
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

    private func relatedListenerItems(for item: ReadablePortItem) -> [ReadablePortItem] {
        guard item.representative.isListening else { return [] }
        let ports = Set(item.localPorts)
        return allItems.filter { candidate in
            candidate.representative.isListening
                && candidate.transport == item.transport
                && !Set(candidate.localPorts).isDisjoint(with: ports)
        }.sorted { left, right in
            if left.id == right.id { return false }
            if left.id == item.id { return true }
            if right.id == item.id { return false }
            if left.processName != right.processName {
                return left.processName.localizedStandardCompare(right.processName) == .orderedAscending
            }
            return left.pid < right.pid
        }
    }

    private func actionSection(for item: ReadablePortItem) -> some View {
        let record = item.representative
        let otherCount = allRecords.filter { $0.pid == record.pid && !item.rawRecords.contains($0) }.count
        let processRecords = item.processSummaries.compactMap { process in
            item.rawRecords.first { $0.pid == process.pid }
        }
        let isAllowed = processRecords.allSatisfy(\.belongsToCurrentUser) && !hasEnded

        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("操作影响")
                    .font(.callout.weight(.medium))
                Text(item.processCount > 1
                     ? "此服务由 \(item.processCount) 个进程共同提供；结束前需要选择具体进程，其他进程不会同时结束。"
                     : otherCount > 0
                        ? "结束后，这个应用使用的其他 \(otherCount) 个端口或连接也会关闭。"
                        : "结束的是整个进程；操作前会再次确认它仍在使用这个端口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.processCount > 1 {
                Menu("选择进程结束…") {
                    ForEach(processRecords) { processRecord in
                        Button(role: .destructive) {
                            portViewModel.prepareToTerminate(processRecord)
                        } label: {
                            Text(processRecord.processName + " · PID " + String(processRecord.pid))
                        }
                    }
                }
                .disabled(portViewModel.isRefreshing || !isAllowed)
                .help("选择要结束的具体进程；操作前仍会重新校验")
                .accessibilityHint("展开组成此服务的进程列表")
            } else {
                Button("结束进程…", role: .destructive) {
                    portViewModel.prepareToTerminate(record)
                }
                .disabled(portViewModel.isRefreshing || !isAllowed)
                .help(terminationHelp(for: record))
                .accessibilityHint(terminationHelp(for: record))
            }
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
    let relatedListenerItems: [ReadablePortItem]
    @State private var selectedNodeID: String?

    private var relatedListenerProcessCount: Int {
        Set(relatedListenerItems.flatMap(\.rawRecords).map(\.pid)).count
    }

    private var nodes: [RelationshipNode] {
        let record = item.representative
        if record.isListening {
            let sourceSubtitle: String
            let sourceItems: [String]
            switch item.accessScope {
            case .localOnly:
                sourceSubtitle = "仅本机应用"
                sourceItems = ["这台 Mac"]
            case .networkPossible:
                sourceSubtitle = "其他设备可能可访问"
                sourceItems = ["这台 Mac", "同一网络设备"]
            case .unknown:
                sourceSubtitle = "暂不确定"
                sourceItems = ["来源暂不确定"]
            }
            let relatedProcesses = Dictionary(
                grouping: relatedListenerItems.flatMap(\.rawRecords),
                by: \.pid
            ).map { pid, records in
                (pid: pid, name: records[0].processName)
            }.sorted { $0.pid < $1.pid }
            let processItems = relatedProcesses.map { process in
                "\(process.name) · PID \(process.pid)"
            }
            let processTitle = processItems.count > 1 ? "\(processItems.count) 个进程" : item.processName
            let processSubtitle = processItems.count > 1 ? "共同使用其中端口" : "应用/服务"
            return [
                .init(id: "source", title: "访问来源", subtitle: sourceSubtitle, symbol: "laptopcomputer.and.arrow.down", explanation: item.accessScope.explanation, items: sourceItems),
                .init(id: "port", title: item.localPorts.count > 1 ? "\(item.localPorts.count) 个服务端口" : "服务端口", subtitle: "等待连接", symbol: "rectangle.stack.fill", explanation: item.localPorts.count > 1 ? "这个应用正在通过多个服务端口等待连接；每个端口可以服务不同功能。" : "这是该应用在本机等待连接的服务端口。", items: item.localPorts.map { ":\($0)" }),
                .init(id: "app", title: processTitle, subtitle: processSubtitle, symbol: processItems.count > 1 ? "person.2.fill" : "app.dashed", explanation: processItems.count > 1 ? "这些进程使用了相同的服务端口；这可能来自共享监听、继承的 socket 或不同监听地址。" : "这个应用或后台服务正在使用该端口。", items: processItems.count > 1 ? processItems : [])
            ]
        }

        let target: String
        let targetSubtitle: String
        let targetExplanation: String
        if item.isConnectionSummary, item.remoteTargetCount > 1 {
            target = "\(item.remoteTargetCount) 个连接目标"
            targetSubtitle = "共 \(item.connectionCount) 条连接"
            targetExplanation = "这些连接的对方地址或端口不同。展开技术详情可以查看每一个连接对象。"
        } else {
            target = record.remoteAddress == nil ? "可能的通信对象" : record.remoteAddress ?? "连接对象未知"
            targetSubtitle = record.remotePort.map { "端口 \($0)" } ?? (record.remoteAddress == nil ? "无固定对象" : "端口未知")
            targetExplanation = record.remoteAddress == nil
                ? "系统没有提供固定的连接对象。"
                : "这是系统返回的另一端地址；不会据此推断网站、位置或安全性。"
        }
        let localPortExplanation: String
        if item.isConnectionSummary, item.connectionCount > 1 {
            localPortExplanation = item.localPorts.count == 1
                ? "多条连接可以共同使用这个本机端口，因为它们的连接对象不同。"
                : "应用通过这些本机连接端口区分多条连接；它们不表示对外开放的服务。"
        } else {
            localPortExplanation = "这是该应用当前在本机使用的端口。"
        }
        return [
            .init(id: "app", title: item.processName, subtitle: "应用/服务", symbol: "app.dashed", explanation: "这个应用或后台服务正在进行网络活动。"),
            .init(id: "port", title: item.isConnectionSummary ? "本机连接端口" : "这台 Mac 的端口", subtitle: item.localPorts.count > 1 ? "\(item.localPorts.count) 个" : item.localPortRelationshipText, symbol: "rectangle.connected.to.line.below", explanation: localPortExplanation, items: item.localPorts.map { ":\($0)" }),
            .init(id: "target", title: item.isConnectionSummary ? "连接目标" : target, subtitle: item.isConnectionSummary ? "\(item.remoteTargetCount) 个 · \(item.connectionCount) 条连接" : targetSubtitle, symbol: "network", explanation: targetExplanation, items: item.isConnectionSummary ? item.remoteEndpoints : [])
        ]
    }

    private var connectors: [RelationshipConnector] {
        let record = item.representative
        if record.isListening {
            return [
                .init(label: item.accessScope == .networkPossible ? "可能可访问" : "可以尝试连接", bidirectional: false, dashed: item.accessScope != .localOnly),
                .init(label: relatedListenerProcessCount > 1 ? "\(relatedListenerProcessCount) 个进程使用" : "等待连接", bidirectional: false, dashed: false)
            ]
        }
        if record.transport == .udp {
            return [
                .init(label: "发送或接收", bidirectional: true, dashed: false),
                .init(label: record.remoteAddress == nil ? "对象不固定" : "通信对象", bidirectional: true, dashed: record.remoteAddress == nil)
            ]
        }
        return [
            .init(label: item.connectionCount > 1 ? "\(item.connectionCount) 条连接" : "存在连接", bidirectional: true, dashed: false),
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

private struct ListenerPortActivityView: View {
    let summary: ListenerActivitySummary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("端口活动", systemImage: "arrow.left.arrow.right.circle")
                    .font(.headline)
                Spacer()
                Text(summary.currentDescription)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(summary.connectionCount > 0 ? Color.blue : Color.secondary)
            }

            if let recentChange = summary.recentChange {
                Label(recentChange.kind.shortDescription, systemImage: recentChangeSymbol(recentChange.kind))
                    .font(.callout)
                    .foregroundStyle(recentChangeColor(recentChange.kind))
                    .transition(.opacity)
            }

            if !summary.remoteEndpoints.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("当前连接对象")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(summary.remoteEndpoints.prefix(3)), id: \.self) { endpoint in
                        Label(endpoint, systemImage: "network")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if summary.remoteEndpoints.count > 3 {
                        Text("另有 \(summary.remoteEndpoints.count - 3) 个连接对象")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("这里显示最近一次系统查询观察到的连接关系，不代表此刻一定正在传输数据。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(activityBackground, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(summary.connectionCount > 0 ? Color.blue.opacity(0.25) : Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("端口活动。\(summary.accessibilityDescription)连接关系不代表此刻一定正在传输数据。")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: summary)
    }

    private var activityBackground: Color {
        summary.connectionCount > 0 ? Color.blue.opacity(0.07) : Color(nsColor: .windowBackgroundColor)
    }

    private func recentChangeSymbol(_ kind: PortActivityChangeKind) -> String {
        switch kind {
        case .appeared: return "plus.circle.fill"
        case .ended: return "checkmark.circle"
        case .changed: return "arrow.triangle.2.circlepath"
        }
    }

    private func recentChangeColor(_ kind: PortActivityChangeKind) -> Color {
        switch kind {
        case .appeared, .changed: return .blue
        case .ended: return .secondary
        }
    }
}

private struct RelationshipNode {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let explanation: String
    let items: [String]

    init(
        id: String,
        title: String,
        subtitle: String,
        symbol: String,
        explanation: String,
        items: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.explanation = explanation
        self.items = items
    }
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
            VStack(alignment: .leading, spacing: 7) {
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

                if !node.items.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(node.items.prefix(3)), id: \.self) { item in
                            BranchItemRow(text: item)
                        }
                        if node.items.count > 3 {
                            Text("另有 \(node.items.count - 3) 项")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tint)
                                .padding(.leading, 17)
                        }
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(width: 190, alignment: .leading)
            .frame(minHeight: 58, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(selectedNodeID == node.id ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selectedNodeID == node.id ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .help(node.explanation)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("显示这个节点的解释")
    }

    private var accessibilityText: String {
        let itemText = node.items.isEmpty ? "" : "包含：\(node.items.joined(separator: "、"))。"
        return "\(node.title)，\(node.subtitle)。\(itemText)\(node.explanation)"
    }
}

private struct BranchItemRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
            Rectangle()
                .fill(Color.accentColor.opacity(0.45))
                .frame(width: 9, height: 1)
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
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
    let lastSuccessfulUpdate: Date?
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
        var fields: [TechnicalField] = [
            .init(title: "应用/服务", value: record.processName, explanation: "正在使用网络的应用、后台服务或系统进程", monospaced: false),
            .init(title: "进程编号", value: item.processSummaries.map { String($0.pid) }.joined(separator: "、"), explanation: "系统分配的临时编号；多个编号表示这项服务由多个进程共同提供"),
            .init(title: "归属用户", value: record.user, explanation: "启动该进程的 macOS 用户", monospaced: false),
            .init(title: "启动来源", value: parentProcessDescription, explanation: "启动当前进程的上一级进程", monospaced: false),
            .init(title: "程序位置", value: record.executablePath ?? "无法获取", explanation: "当前进程对应程序文件在磁盘上的位置", monospaced: false)
        ]
        if item.processCount > 1 {
            fields.insert(
                .init(title: "组成进程", value: "\(item.processCount) 个", explanation: "这些进程使用了同一组服务端口", monospaced: false),
                at: 1
            )
        }
        return fields
    }

    private var connectionFields: [TechnicalField] {
        [
            .init(title: "传输与地址格式", value: record.protocolDisplay, explanation: "TCP/UDP 是传输方式，IPv4/IPv6 是地址格式", monospaced: false),
            .init(title: "这台 Mac 的地址和端口", value: endpointSummary(local: true), explanation: "当前进程在本机使用的原始网络地址与端口；完整列表见下方技术记录"),
            .init(title: "连接对象", value: endpointSummary(local: false), explanation: "另一端的原始地址与端口；不能据此判断此刻是否有数据传输"),
            .init(title: "原始 TCP 状态", value: stateSummary, explanation: record.friendlyStatusExplanation)
        ]
    }

    private func endpointSummary(local: Bool) -> String {
        let endpoints = Array(Set(item.rawRecords.compactMap { raw -> String? in
            if local { return raw.localEndpoint }
            return raw.remoteAddress == nil ? nil : raw.remoteEndpoint
        })).sorted()
        guard !endpoints.isEmpty else { return "—" }
        guard endpoints.count > 3 else { return endpoints.joined(separator: "、") }
        return "\(endpoints.count) 个端点：\(endpoints.prefix(3).joined(separator: "、"))…"
    }

    private var stateSummary: String {
        let states = Array(Set(item.rawRecords.compactMap(\.normalizedState))).sorted()
        if states.isEmpty { return "无（UDP 或系统未提供）" }
        return states.joined(separator: "、")
    }

    private var systemFields: [TechnicalField] {
        [
            .init(title: "系统连接编号", value: record.fileDescriptor, explanation: "进程内部标识这条网络资源的编号"),
            .init(
                title: "数据更新时间",
                value: (lastSuccessfulUpdate ?? record.updatedAt).formatted(date: .abbreviated, time: .standard),
                explanation: "应用上次通过完整查询确认这条记录存在的精确时间",
                monospaced: false
            ),
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
            Text("组成此活动的技术记录")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(item.rawRecords) { raw in
                Text([
                    "PID " + String(raw.pid), raw.ipVersion.rawValue, raw.transport.rawValue,
                    raw.localEndpoint, raw.remoteEndpoint, raw.normalizedState ?? "无状态",
                    "FD " + raw.fileDescriptor
                ].joined(separator: " · "))
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
                        Text("\(other.transport.rawValue) · \(other.localPortRelationshipText)")
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
                    text: "本机端口是应用在这台 Mac 上收发网络数据时使用的编号。服务端口用于等待连接；连接其他服务时，macOS 通常还会分配本机连接端口。相同端口不一定是同一连接，多个连接端口也不代表应用对外开放了多个服务。"
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
