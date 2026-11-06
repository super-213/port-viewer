import AppKit
import Charts
import SwiftUI

struct MainWindowView: View {
    @Bindable var portViewModel: PortViewModel
    @Bindable var viewModel: MainWindowViewModel
    @Bindable var networkScanViewModel: NetworkScanViewModel
    @State private var technicalDetailsExpanded = true
    @State private var searchIsFocused = false
    @State private var selectedPage: MainPage = .activity(.waiting)

    var body: some View {
        ZStack {
            PremiumCanvas()
            VStack(spacing: 0) {
                if selectedPage != .scanner, let issue = portViewModel.state.issueMessage {
                    QueryBanner(message: issue, symbol: "exclamationmark.triangle.fill", color: PVPalette.warning) {
                        portViewModel.refreshNow()
                    }
                } else if selectedPage != .scanner, portViewModel.isPaused {
                    QueryBanner(
                        message: "自动刷新已暂停，当前数据可能已过期。",
                        symbol: "pause.circle.fill",
                        color: PVPalette.neutral,
                        actionTitle: "继续刷新"
                    ) {
                        portViewModel.togglePause()
                    }
                }
                mainContent
            }
        }
        .containerBackground(PVPalette.canvasBase, for: .window)
        .frame(minWidth: 1_080, minHeight: 700)
        .toolbar { toolbarContent }
        .toolbarBackground(PVPalette.canvasBase, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .onAppear {
            if case .activity = selectedPage {
                selectedPage = .activity(viewModel.scope)
            }
            portViewModel.setMainWindowVisible(true)
            portViewModel.inspectDocker(for: viewModel.selectedItem)
        }
        .onDisappear {
            portViewModel.setMainWindowVisible(false)
            portViewModel.inspectDocker(for: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusPortSearch)) { _ in
            showActivity(.all)
            searchIsFocused = true
        }
        .onChange(of: selectedPage) { _, page in
            if case let .activity(scope) = page, viewModel.scope != scope {
                viewModel.scope = scope
            }
        }
        .onChange(of: viewModel.scope) { _, scope in
            if case .activity = selectedPage {
                selectedPage = .activity(scope)
            }
        }
        .onChange(of: viewModel.searchText) { _, searchText in
            if selectedPage == .overview,
               !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showActivity(.all)
            }
        }
        .onChange(of: viewModel.recordIDs) { _, _ in
            viewModel.reconcileSelectionAfterRefresh()
        }
        .onChange(of: viewModel.selectedItem, initial: true) { _, item in
            portViewModel.inspectDocker(for: item)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            portViewModel.interruptPortObservation(reason: L10n.string("采样中断 · 系统休眠"))
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

    private var pageNavigation: some View {
        HStack(spacing: 2) {
            navigationButton("总览", page: .overview)
            ForEach(SidebarScope.allCases) { scope in
                navigationButton(scope == .other ? "其他活动" : scope.rawValue, page: .activity(scope))
            }
            navigationButton("网络扫描", page: .scanner)
        }
        .padding(4)
        .background(PVPalette.surfaceContent, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("页面")
    }

    private func navigationButton(_ title: String, page: MainPage) -> some View {
        Button {
            selectedPage = page
        } label: {
            Text(L10n.string(title))
                .font(.system(size: 14, weight: selectedPage == page ? .semibold : .regular))
                .foregroundStyle(selectedPage == page ? PVPalette.textPrimary : PVPalette.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(
                    selectedPage == page ? PVPalette.textPrimary.opacity(0.09) : .clear,
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedPage == page ? .isSelected : [])
    }

    @ViewBuilder
    private var mainContent: some View {
        switch selectedPage {
        case .overview:
            ActivityOverview(
                snapshot: viewModel.overviewSnapshot,
                history: portViewModel.activityHistory,
                buckets: viewModel.portMapBuckets,
                selectedID: viewModel.selectedID,
                lastSuccessfulUpdate: portViewModel.lastSuccessfulUpdate,
                isRefreshing: portViewModel.isRefreshing,
                onSelectScope: showActivity,
                onSelectNetworkPossible: showNetworkPossibleActivity,
                onSelectItem: showActivity
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        case .activity:
            activityWorkspace

        case .scanner:
            NetworkScanView(viewModel: networkScanViewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var activityWorkspace: some View {
        HSplitView {
            VStack(spacing: 0) {
                activitySummary
                PremiumSeparator()

                PremiumSearchField(
                    text: $viewModel.searchText,
                    prompt: "搜索应用名称或端口，例如 3000",
                    focusRequest: $searchIsFocused
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityLabel("搜索应用名称或端口")

                FilterBar(
                    scope: $viewModel.scope,
                    accessFilter: $viewModel.accessFilter,
                    ownerFilter: $viewModel.ownerFilter,
                    connectionPhaseFilter: $viewModel.connectionPhaseFilter,
                    protocolFilter: $viewModel.protocolFilter,
                    ipFilter: $viewModel.ipFilter,
                    stateFilter: $viewModel.stateFilter,
                    tunnelOnly: $viewModel.tunnelOnly,
                    stateOptions: viewModel.stateOptions,
                    activeFilterLabels: viewModel.activeFilterLabels.filter { $0 != viewModel.scope.rawValue },
                    visibleCount: viewModel.displayedItems.count,
                    clearFilter: viewModel.clearFilter,
                    reset: viewModel.resetFilters
                )
                historicalListeners
                tableOrState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 740, idealWidth: 900, maxWidth: .infinity, maxHeight: .infinity)
            .background(PVPalette.surfaceContent)

            recordDetail
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 360, maxHeight: .infinity)
                .background(PVPalette.surfaceBento)
        }
    }

    private var historicalListeners: some View {
        let items = viewModel.historicalItems
        return Group {
            if !items.isEmpty {
                DisclosureGroup(L10n.format("最近监听记录 · %lld 项", items.count)) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(items) { item in
                                Button {
                                    viewModel.selectHistorical(item)
                                } label: {
                                    HStack {
                                        Text(item.processName)
                                        Text(item.localPorts.map { ":\($0)" }.joined(separator: ", "))
                                            .monospaced()
                                        Spacer()
                                        Text(item.representative.updatedAt, format: .dateTime.hour().minute().second())
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption)
                                    .padding(4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint(L10n.string("查看最后观察到的监听与端口事件"))
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private var activitySummary: some View {
        HStack(spacing: 12) {
            ForEach(SidebarScope.allCases) { scope in
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string(scope.metricTitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(String(viewModel.count(for: scope)))
                        .font(.system(size: 22, weight: .medium))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func showActivity(_ scope: SidebarScope) {
        viewModel.scope = scope
        selectedPage = .activity(scope)
    }

    private func showActivity(_ item: ReadablePortItem) {
        showActivity(.all)
        viewModel.select(item)
    }

    private func showNetworkPossibleActivity() {
        viewModel.resetFilters()
        viewModel.scope = .waiting
        viewModel.accessFilter = .networkPossible
        selectedPage = .activity(.waiting)
    }

    private var recordDetail: some View {
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
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if #available(macOS 26.0, *) {
            toolbarItems
                .sharedBackgroundVisibility(.hidden)
        } else {
            toolbarItems
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            pageNavigation
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if selectedPage != .scanner {
                Button {
                    portViewModel.togglePause()
                } label: {
                    Label(L10n.string(portViewModel.isPaused ? "继续自动刷新" : "暂停自动刷新"), systemImage: portViewModel.isPaused ? "play.fill" : "pause.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(QuietButtonStyle())
                .help(L10n.string(portViewModel.isPaused ? "继续自动刷新" : "暂停自动刷新"))
                .accessibilityLabel(L10n.string(portViewModel.isPaused ? "继续自动刷新" : "暂停自动刷新"))

                Button {
                    portViewModel.refreshNow()
                } label: {
                    Label("立即刷新", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(portViewModel.isRefreshing)
                .help("立即刷新（Command-R）")
                .accessibilityLabel("立即刷新网络活动列表")
            }

            SettingsLink {
                Label("设置", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(QuietButtonStyle())
            .help("设置")
            .accessibilityLabel("设置")
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
                    .buttonStyle(GlassButtonStyle())
                } else {
                    Button("重新查询") { portViewModel.refreshNow() }
                        .buttonStyle(AccentButtonStyle())
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

private struct ActivityOverview: View {
    let snapshot: OverviewSnapshot
    let history: [ActivityHistoryPoint]
    let buckets: [PortMapBucket]
    let selectedID: ReadablePortItem.ID?
    let lastSuccessfulUpdate: Date?
    let isRefreshing: Bool
    let onSelectScope: (SidebarScope) -> Void
    let onSelectNetworkPossible: () -> Void
    let onSelectItem: (ReadablePortItem) -> Void

    @State private var showsHelp = false
    @State private var selectedTimeRange = OverviewTimeRange.fifteenMinutes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PVSpacing.two) {
                        overviewHeading
                        Spacer(minLength: PVSpacing.three)
                        timeRangePicker
                        updateStatus
                        overviewHelpButton
                    }

                    VStack(alignment: .leading, spacing: PVSpacing.two) {
                        HStack(spacing: PVSpacing.two) {
                            overviewHeading
                            Spacer(minLength: PVSpacing.three)
                            updateStatus
                            overviewHelpButton
                        }
                        timeRangePicker
                    }
                }

                HStack(spacing: 8) {
                    metric(
                        title: "当前活动",
                        value: snapshot.itemCount,
                        detail: L10n.format("%lld 条系统记录", snapshot.recordCount),
                        symbol: "list.bullet",
                        color: PVPalette.accentPrimary,
                        help: "合并同一服务的重复底层记录后得到的活动项目数"
                    ) { onSelectScope(.all) }
                    metric(
                        title: "监听服务",
                        value: snapshot.waitingCount,
                        detail: "监听记录",
                        symbol: SidebarScope.waiting.symbol,
                        color: PVPalette.waiting,
                        help: SidebarScope.waiting.explanation
                    ) { onSelectScope(.waiting) }
                    metric(
                        title: "TCP 连接",
                        value: snapshot.connectionCount,
                        detail: "TCP 远端连接",
                        symbol: SidebarScope.connections.symbol,
                        color: PVPalette.connected,
                        help: SidebarScope.connections.explanation
                    ) { onSelectScope(.connections) }
                    metric(
                        title: "可能可访问",
                        value: snapshot.networkPossibleCount,
                        detail: "非本机监听",
                        symbol: "network",
                        color: PVPalette.warning,
                        help: "监听地址不是本机回环地址；同一网络设备可能具备访问条件"
                    ) { onSelectNetworkPossible() }
                }

                dashboardPrimaryRow
                dashboardSecondaryRow

                PremiumSeparator()

                PortActivityMap(
                    buckets: buckets,
                    itemCount: snapshot.itemCount,
                    selectedID: selectedID,
                    onSelect: onSelectItem
                )
            }
            .padding(14)
        }
        .background(PVPalette.surfaceContent)
        .popover(isPresented: $showsHelp) {
            VStack(alignment: .leading, spacing: 12) {
                Text("统计口径")
                    .font(.headline)
                helpRow(.waiting)
                helpRow(.connections)
                helpRow(.other)
                Text("“当前活动”按易读项目计数，其余分布按系统返回的底层网络记录计数。趋势只保存在本次运行期间，退出应用后清空。")
                    .font(.callout)
                    .foregroundStyle(PVPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 360, alignment: .leading)
            .frostedSurface(.floating, radius: PVRadius.floating)
        }
    }

    @ViewBuilder
    private var dashboardPrimaryRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                OverviewTrendPanel(history: filteredHistory)
                    .frame(minWidth: 400, maxWidth: .infinity)
                OverviewCompositionPanel(snapshot: snapshot)
                    .frame(width: 300)
            }

            VStack(spacing: 10) {
                OverviewTrendPanel(history: filteredHistory)
                OverviewCompositionPanel(snapshot: snapshot)
            }
        }
    }

    @ViewBuilder
    private var dashboardSecondaryRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                OverviewTopProcessesPanel(processes: snapshot.topProcesses)
                    .frame(minWidth: 400, maxWidth: .infinity)
                OverviewAccessPanel(items: snapshot.accessBreakdown, latest: filteredHistory.last)
                    .frame(width: 300)
            }

            VStack(spacing: 10) {
                OverviewTopProcessesPanel(processes: snapshot.topProcesses)
                OverviewAccessPanel(items: snapshot.accessBreakdown, latest: filteredHistory.last)
            }
        }
    }

    private var overviewHeading: some View {
        HStack(spacing: PVSpacing.two) {
            Text("活动概览")
                .font(.headline)
                .foregroundStyle(PVPalette.textPrimary)

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在刷新")
            }
        }
    }

    private var timeRangePicker: some View {
        Picker("趋势时间范围", selection: $selectedTimeRange) {
            ForEach(OverviewTimeRange.allCases) { range in
                Text(L10n.string(range.title)).tag(range)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .help("选择趋势图显示的时间范围")
    }

    private var updateStatus: some View {
        Text(updateDescription)
            .font(.callout)
            .foregroundStyle(PVPalette.textSecondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var overviewHelpButton: some View {
        Button {
            showsHelp = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(QuietButtonStyle(size: 28, horizontalPadding: 0))
        .help("查看统计口径")
        .accessibilityLabel("查看统计口径")
    }

    private var filteredHistory: [ActivityHistoryPoint] {
        guard let latestDate = history.last?.timestamp else { return [] }
        let cutoff = latestDate.addingTimeInterval(-selectedTimeRange.seconds)
        return history.filter { $0.timestamp >= cutoff }
    }

    private func metric(
        title: String,
        value: Int,
        detail: String,
        symbol: String,
        color: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        OverviewMetricButton(
            title: title,
            value: value,
            detail: detail,
            symbol: symbol,
            color: color,
            isSelected: false,
            help: help,
            action: action
        )
    }

    private var updateDescription: String {
        guard let update = lastSuccessfulUpdate else { return L10n.string("等待首次查询") }
        let elapsed = Date().timeIntervalSince(update)
        if elapsed < 10 { return L10n.string("刚刚更新") }
        return update.formatted(.relative(presentation: .named))
    }

    private func helpRow(_ item: SidebarScope) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.symbol)
                .foregroundStyle(item == .waiting ? PVPalette.waiting : item == .connections ? PVPalette.connected : PVPalette.neutral)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(item.rawValue))
                    .font(.callout.weight(.semibold))
                Text(item.explanation)
                    .font(.callout)
                    .foregroundStyle(PVPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private enum OverviewTimeRange: TimeInterval, CaseIterable, Identifiable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800

    var id: Self { self }
    var seconds: TimeInterval { rawValue }

    var title: String {
        switch self {
        case .fiveMinutes: return L10n.string("5 分钟")
        case .fifteenMinutes: return L10n.string("15 分钟")
        case .thirtyMinutes: return L10n.string("30 分钟")
        }
    }
}

private struct OverviewPanel<Content: View>: View {
    let title: String
    let symbol: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        symbol: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(L10n.string(title), systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(PVPalette.textPrimary)
                Spacer(minLength: 8)
                if let subtitle {
                    Text(L10n.string(subtitle))
                        .font(.caption)
                        .foregroundStyle(PVPalette.textTertiary)
                }
            }
            content
        }
        .padding(12)
        .background(PVPalette.surfaceControl, in: RoundedRectangle(cornerRadius: PVRadius.node, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PVRadius.node, style: .continuous)
                .strokeBorder(PVPalette.edgeOuter, lineWidth: 1)
        }
    }
}

private struct OverviewTrendPanel: View {
    let history: [ActivityHistoryPoint]

    var body: some View {
        OverviewPanel(
            title: "活动趋势",
            symbol: "chart.xyaxis.line",
            subtitle: history.count > 1 ? L10n.format("%lld 个采样点", history.count) : "正在积累样本"
        ) {
            HStack(spacing: 14) {
                trendLegend("全部", color: PVPalette.accentPrimary)
                trendLegend("等待", color: PVPalette.waiting)
                trendLegend("已建立", color: PVPalette.connected)
                Spacer()
            }

            if history.isEmpty {
                ContentUnavailableView(
                    "等待首次采样",
                    systemImage: "chart.xyaxis.line",
                    description: Text("完成一次查询后会在这里显示会话内趋势。")
                )
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                Chart(history) { point in
                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("全部", point.totalCount),
                        series: .value("序列", L10n.string("全部"))
                    )
                    .foregroundStyle(PVPalette.accentPrimary)
                    .lineStyle(StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("等待", point.waitingCount),
                        series: .value("序列", L10n.string("等待"))
                    )
                    .foregroundStyle(PVPalette.waiting)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("已建立", point.connectedCount),
                        series: .value("序列", L10n.string("已建立"))
                    )
                    .foregroundStyle(PVPalette.connected)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)

                    if history.count == 1 {
                        PointMark(
                            x: .value("时间", point.timestamp),
                            y: .value("全部", point.totalCount)
                        )
                        .foregroundStyle(PVPalette.accentPrimary)
                        .symbolSize(34)

                        PointMark(
                            x: .value("时间", point.timestamp),
                            y: .value("等待", point.waitingCount)
                        )
                        .foregroundStyle(PVPalette.waiting)
                        .symbolSize(26)

                        PointMark(
                            x: .value("时间", point.timestamp),
                            y: .value("已建立", point.connectedCount)
                        )
                        .foregroundStyle(PVPalette.connected)
                        .symbolSize(26)
                    }
                }
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(PVPalette.edgeSeparator)
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .foregroundStyle(PVPalette.textTertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(PVPalette.edgeSeparator)
                        AxisValueLabel()
                            .foregroundStyle(PVPalette.textTertiary)
                    }
                }
                .frame(minHeight: 170)
                .accessibilityLabel(trendAccessibilityLabel)
            }
        }
        .frame(minHeight: 250, alignment: .top)
    }

    private func trendLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(L10n.string(title))
                .font(.caption)
                .foregroundStyle(PVPalette.textSecondary)
        }
    }

    private var trendAccessibilityLabel: String {
        guard let latest = history.last else { return L10n.string("尚无活动趋势数据") }
        return L10n.format("活动趋势，最新共有 %lld 条记录，等待连接 %lld 条，连接已建立 %lld 条", latest.totalCount, latest.waitingCount, latest.connectedCount)
    }
}

private struct OverviewCompositionPanel: View {
    let snapshot: OverviewSnapshot

    var body: some View {
        OverviewPanel(title: "当前构成", symbol: "chart.bar.fill", subtitle: "系统记录") {
            breakdown(title: "活动状态", items: snapshot.activityBreakdown)
            PremiumSeparator()
            breakdown(title: "传输协议", items: snapshot.protocolBreakdown)
            PremiumSeparator()
            breakdown(title: "地址格式", items: snapshot.ipBreakdown)
        }
        .frame(minHeight: 250, alignment: .top)
    }

    private func breakdown(title: String, items: [OverviewBreakdownItem]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.string(title))
                .font(.callout.weight(.medium))
                .foregroundStyle(PVPalette.textSecondary)
            OverviewStackedBar(items: items)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 6)], alignment: .leading, spacing: 5) {
                ForEach(items.filter { $0.count > 0 }) { item in
                    OverviewLegendItem(item: item)
                }
            }
        }
    }
}

private struct OverviewTopProcessesPanel: View {
    let processes: [OverviewProcessUsage]

    var body: some View {
        OverviewPanel(title: "活动最多的应用", symbol: "chart.bar.xaxis", subtitle: "前 5 名") {
            if processes.isEmpty {
                ContentUnavailableView("暂无应用活动", systemImage: "app.dashed")
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart(processes) { process in
                    BarMark(
                        x: .value("系统记录", process.recordCount),
                        y: .value("应用", process.processName)
                    )
                    .foregroundStyle(PVPalette.accentPrimary.gradient)
                    .cornerRadius(4)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(String(process.recordCount))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(PVPalette.textSecondary)
                    }
                }
                .chartYScale(domain: processes.map(\.processName))
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel()
                            .foregroundStyle(PVPalette.textSecondary)
                    }
                }
                .frame(minHeight: 170)
                .accessibilityLabel(processAccessibilityLabel)
            }
        }
        .frame(minHeight: 226, alignment: .top)
    }

    private var processAccessibilityLabel: String {
        let values = processes.map { L10n.format("%@ %lld 条", $0.processName, $0.recordCount) }.joined(separator: "，")
        return L10n.format("活动最多的应用：%@", values)
    }
}

private struct OverviewAccessPanel: View {
    let items: [OverviewBreakdownItem]
    let latest: ActivityHistoryPoint?

    var body: some View {
        OverviewPanel(title: "监听访问范围", symbol: "network", subtitle: "仅基于监听地址") {
            OverviewStackedBar(items: items)
                .frame(height: 12)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    OverviewLegendItem(item: item, expands: true)
                }
            }

            PremiumSeparator()

            HStack(spacing: 8) {
                changeMetric(
                    title: "本轮新增",
                    value: latest?.appearedCount ?? 0,
                    symbol: "plus",
                    color: PVPalette.waiting
                )
                changeMetric(
                    title: "本轮结束",
                    value: latest?.endedCount ?? 0,
                    symbol: "minus",
                    color: PVPalette.neutral
                )
            }

            if let latest {
                Text(L10n.format("最近查询耗时 %.2f 秒", latest.queryDuration))
                    .font(.caption)
                    .foregroundStyle(PVPalette.textTertiary)
                    .monospacedDigit()
            }
        }
        .frame(minHeight: 226, alignment: .top)
    }

    private func changeMetric(title: String, value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(value))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PVPalette.textPrimary)
                Text(L10n.string(title))
                    .font(.caption)
                    .foregroundStyle(PVPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: PVRadius.small, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewStackedBar: View {
    let items: [OverviewBreakdownItem]

    private var visibleItems: [OverviewBreakdownItem] { items.filter { $0.count > 0 } }
    private var total: Int { visibleItems.reduce(0) { $0 + $1.count } }

    var body: some View {
        GeometryReader { geometry in
            if total == 0 {
                Capsule()
                    .fill(PVPalette.surfaceRaised.opacity(0.65))
                    .overlay { Capsule().strokeBorder(PVPalette.edgeOuter, lineWidth: 1) }
            } else {
                let spacing = CGFloat(max(visibleItems.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(visibleItems) { item in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(item.kind.color)
                            .frame(width: max(3, (geometry.size.width - spacing) * CGFloat(item.count) / CGFloat(total)))
                    }
                }
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        visibleItems.map { L10n.format("%@ %lld 条", $0.kind.title, $0.count) }.joined(separator: "，")
    }
}

private struct OverviewLegendItem: View {
    let item: OverviewBreakdownItem
    var expands = false

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(item.kind.color)
                .frame(width: 9, height: 9)
            Text(item.kind.title)
                .font(.caption)
                .foregroundStyle(PVPalette.textSecondary)
                .lineLimit(1)
            if expands { Spacer(minLength: 4) }
            Text(String(item.count))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(PVPalette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension OverviewBreakdownKind {
    var color: Color {
        switch self {
        case .waiting, .localOnly: return PVPalette.waiting
        case .connected, .tcp, .ipv4: return PVPalette.connected
        case .transitioning, .networkPossible: return PVPalette.warning
        case .udp, .ipv6: return PVPalette.accentIndigo
        case .other, .unknownIP, .unknownAccess: return PVPalette.neutral
        }
    }
}

private enum MainPage: Hashable {
    case overview
    case activity(SidebarScope)
    case scanner
}

private struct OverviewMetricButton: View {
    let title: String
    let value: Int
    let detail: String
    let symbol: String
    let color: Color
    let isSelected: Bool
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(value))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(PVPalette.textPrimary)
                        .monospacedDigit()

                    Text(L10n.string(title))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(isSelected ? color : PVPalette.textSecondary)
                        .lineLimit(1)

                    Text(L10n.string(detail))
                        .font(.caption)
                        .foregroundStyle(PVPalette.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PVPalette.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .premiumControlSurface(
                radius: PVRadius.node,
                isHovered: isHovered,
                isSelected: isSelected,
                accent: color,
                raised: isSelected
            )
            .contentShape(RoundedRectangle(cornerRadius: PVRadius.node, style: .continuous))
        }
        .buttonStyle(OverviewMetricButtonStyle())
        .onHover { hovering in
            isHovered = hovering
        }
        .help(L10n.string(help))
        .accessibilityLabel(L10n.format("%@，%lld，%@", L10n.string(title), value, L10n.string(detail)))
        .accessibilityHint(L10n.string(isSelected ? "当前正在显示此类活动" : "筛选并显示此类活动"))
    }
}

private struct OverviewMetricButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let isPressed: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            label
                .scaleEffect(isPressed && !reduceMotion ? 0.985 : 1)
                .opacity(isPressed ? 0.88 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isPressed)
        }
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
    @Binding var tunnelOnly: Bool
    let stateOptions: [String]
    let activeFilterLabels: [String]
    let visibleCount: Int
    let clearFilter: (String) -> Void
    let reset: () -> Void

    @State private var showsMoreFilters = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PremiumPicker(
                    "访问范围",
                    options: AccessFilter.allCases,
                    selection: $accessFilter,
                    optionText: \.rawValue
                )
                .frame(width: 170)

                PremiumPicker(
                    "归属",
                    options: OwnerFilter.allCases,
                    selection: $ownerFilter,
                    optionText: \.rawValue
                )
                .frame(width: 140)

                if scope == .connections {
                    PremiumPicker(
                        "连接状态",
                        symbol: "arrow.left.arrow.right",
                        options: ConnectionPhaseFilter.allCases,
                        selection: $connectionPhaseFilter,
                        optionText: \.rawValue
                    )
                    .frame(width: 145)
                }

                Button {
                    showsMoreFilters.toggle()
                } label: {
                    Label("更多筛选", systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(GlassButtonStyle())
                .popover(isPresented: $showsMoreFilters, arrowEdge: .bottom) {
                    MoreFiltersPopover(
                        protocolFilter: $protocolFilter,
                        ipFilter: $ipFilter,
                        stateFilter: $stateFilter,
                        tunnelOnly: $tunnelOnly,
                        stateOptions: stateOptions
                    )
                }

                Spacer()
                Text(L10n.format("%lld 个服务 / 活动组", visibleCount))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(PVPalette.textSecondary)
                    .monospacedDigit()
            }

            if !activeFilterLabels.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(activeFilterLabels, id: \.self) { label in
                            Button {
                                clearFilter(label)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(L10n.string(label))
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                }
                            }
                            .buttonStyle(FilterChipButtonStyle())
                            .accessibilityLabel(L10n.format("移除筛选：%@", L10n.string(label)))
                        }
                        Button("清除全部", action: reset)
                            .buttonStyle(QuietButtonStyle(size: 26, horizontalPadding: 7))
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(PVPalette.surfaceBento)
        .overlay(alignment: .bottom) {
            PremiumSeparator()
        }
    }
}

private struct MoreFiltersPopover: View {
    @Binding var protocolFilter: ProtocolFilter
    @Binding var ipFilter: IPFilter
    @Binding var stateFilter: String
    @Binding var tunnelOnly: Bool
    let stateOptions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("技术筛选")
                .font(.headline)

            Toggle(L10n.string("有 Cloudflare 映射"), isOn: $tunnelOnly)

            technicalPicker(
                title: "传输方式",
                explanation: "TCP 会建立可靠连接；UDP 不保持固定连接状态。"
            ) {
                PremiumPicker(
                    "传输方式",
                    options: ProtocolFilter.allCases,
                    selection: $protocolFilter,
                    optionText: \.rawValue
                )
            }

            technicalPicker(
                title: "地址格式",
                explanation: "IPv4 和 IPv6 是两种网络地址格式，通常不需要手动处理。"
            ) {
                PremiumPicker(
                    "地址格式",
                    options: IPFilter.allCases,
                    selection: $ipFilter,
                    optionText: \.rawValue
                )
            }

            technicalPicker(
                title: "原始 TCP 状态",
                explanation: "中文在前，括号中保留系统返回的原始状态代码。"
            ) {
                PremiumPicker(
                    "原始 TCP 状态",
                    options: [""] + stateOptions,
                    selection: $stateFilter,
                    optionText: { state in
                        state.isEmpty ? "全部状态" : "\(PortRecord.friendlyStatusTitle(for: state))（\(state)）"
                    }
                )
            }
        }
        .padding(18)
        .frame(width: 330)
        .frostedSurface(.floating, radius: PVRadius.floating)
    }

    private func technicalPicker<Content: View>(
        title: String,
        explanation: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string(title)).font(.callout.weight(.medium))
            content()
                .frame(maxWidth: .infinity)
            Text(L10n.string(explanation))
                .font(.caption)
                .foregroundStyle(PVPalette.textSecondary)
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
    @State private var expandedServices: Set<ReadablePortItem.ID> = []

    private var tableItems: [ReadablePortItem] {
        items.flatMap { item in
            expandedServices.contains(item.id) ? [item] + item.connectionChildren : [item]
        }
    }

    var body: some View {
        Table(tableItems, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn("应用/服务", sortUsing: ReadablePortSortComparator(field: .process)) { item in
                HStack(alignment: .top, spacing: 6) {
                    if !item.serviceConnections.isEmpty {
                        Button {
                            if expandedServices.contains(item.id) {
                                expandedServices.remove(item.id)
                                if item.connectionChildren.contains(where: { $0.id == selectedID }) { selectedID = item.id }
                            } else {
                                expandedServices.insert(item.id)
                            }
                        } label: {
                            Image(systemName: expandedServices.contains(item.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 16, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string(expandedServices.contains(item.id) ? "收起客户端连接" : "展开客户端连接"))
                        .accessibilityLabel(L10n.string(expandedServices.contains(item.id) ? "收起客户端连接" : "展开客户端连接"))
                    } else if item.processCount > 1 {
                        ProcessGroupDisclosureButton(isExpanded: expandedProcessGroups.contains(item.id)) {
                            if expandedProcessGroups.contains(item.id) {
                                expandedProcessGroups.remove(item.id)
                            } else {
                                expandedProcessGroups.insert(item.id)
                            }
                        }
                    } else {
                        Color.clear.frame(width: 16, height: 20)
                    }
                    ProcessIconView(record: item.clientRecord ?? item.representative, size: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(item.isConnectionChild ? (item.clientRecord?.displayName ?? L10n.string("客户端")) : item.processName)
                                .lineLimit(1).help(item.processName)
                            if item.processCount > 1 {
                                Text("(\(item.processCount))")
                                    .foregroundStyle(.secondary)
                            }
                            if !item.representative.belongsToCurrentUser {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("其他用户的应用/服务")
                            }
                            if ProcessProtectionPolicy.isCritical(item.representative) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("关键系统进程")
                            }
                        }
                        if item.isConnectionChild {
                            Text(item.clientRecord.map { "PID \($0.pid)" } ?? item.representative.remoteEndpoint)
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let serviceName = item.serviceName {
                            Text(L10n.format("接入 %@ · %@", serviceName, item.localPortText))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        TunnelSummaryView(portViewModel: portViewModel, records: item.rawRecords)
                        if expandedProcessGroups.contains(item.id) {
                            ForEach(item.processSummaries) { process in
                                Text(process.processName + " · PID " + String(process.pid))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.vertical, 3)
                .padding(.leading, item.isConnectionChild ? 20 : 0)
            }
            .width(min: 145, ideal: 180)

            TableColumn("本机端口", sortUsing: ReadablePortSortComparator(field: .localPort)) { item in
                Text(item.isConnectionChild ? "—" : portSummary(for: item))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .help(localPortHelp(for: item))
                    .accessibilityLabel(localPortHelp(for: item))
            }
            .width(min: 85, ideal: 110, max: 160)

            TableColumn("协议") { item in
                Text(item.transport.rawValue)
                    .foregroundStyle(.secondary)
            }
            .width(48)

            TableColumn("正在做什么", sortUsing: ReadablePortSortComparator(field: .status)) { item in
                VStack(alignment: .leading, spacing: 3) {
                    if item.representative.isListening {
                        Label("正在监听", systemImage: "circle.fill")
                            .font(.callout).foregroundStyle(PVPalette.waiting)
                    } else {
                        FriendlyStatusLabel(item: item)
                    }
                }
                    .help(portViewModel.listenerActivitySummary(for: item)?.accessibilityDescription
                          ?? item.representative.friendlyStatusExplanation)
            }
            .width(min: 105, ideal: 125, max: 160)

            TableColumn("当前连接") { item in
                Text(item.representative.isListening
                     ? L10n.format("%lld 条", item.serviceConnections.count)
                     : item.isConnectionChild || item.transport == .udp ? "—" : L10n.format("%lld 条", item.connectionCount))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(65)

            TableColumn("连接流程", sortUsing: ReadablePortSortComparator(field: .connection)) { item in
                CompactTopologyView(item: item, listenerProcessCount: listenerProcessCount(for: item))
                    .padding(.vertical, 5)
            }
            .width(min: 270, ideal: 330)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .background(NativeTableBackgroundBridge())
        .accessibilityLabel("应用、本机端口和网络活动列表")
    }

    private func listenerProcessCount(for item: ReadablePortItem) -> Int {
        guard item.representative.isListening else { return 0 }
        let ports = Set(item.localPorts)
        return Set(allItems.filter { candidate in
            candidate.representative.isListening
                && candidate.transport == item.transport
                && !Set(candidate.localPorts).isDisjoint(with: ports)
        }.flatMap(\.rawRecords).map(\.pid)).count
    }

    private func portSummary(for item: ReadablePortItem) -> String {
        guard !item.localPorts.isEmpty else { return "*" }
        let ports = item.localPorts.prefix(2).map(String.init).joined(separator: ", ")
        return item.localPorts.count > 2 ? ports + " +\(item.localPorts.count - 2)" : ports
    }

    private func localPortHelp(for item: ReadablePortItem) -> String {
        if item.representative.isListening {
            if item.localPorts.count > 1 {
                let ports = item.localPorts.map(String.init).joined(separator: "、")
                return L10n.format("应用正在通过 %lld 个服务端口等待连接：%@。同一应用可以为不同功能使用多个服务端口。", item.localPorts.count, ports)
            }
            return L10n.format("服务端口 %@：应用在这里等待其他程序连接。", item.localPortText)
        }
        if item.serviceName != nil {
            return L10n.format("服务端口 %@", item.localPortText)
        }
        if item.isConnectionSummary {
            let ports = item.localPorts.map(String.init).joined(separator: "、")
            if item.localPorts.count > 1 {
                return L10n.format("应用通过 %lld 个本机连接端口建立网络连接：%@。这些端口不表示对外开放的服务。", item.localPorts.count, ports)
            }
            return L10n.format("本机连接端口 %@：它用于区分这组连接，不表示应用正在对外提供服务。", item.localPortText)
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
                .font(.system(size: 8))
                .foregroundStyle(color)
                .frame(width: 10)
            Text(item.friendlyStatusTitle)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("正在做什么：%@", item.friendlyStatusTitle))
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
        case .waiting: return PVPalette.waiting
        case .connected: return PVPalette.connected
        case .transitioning: return PVPalette.neutral
        case .other: return PVPalette.neutral
        }
    }
}

private struct ProcessGroupDisclosureButton: View {
    let isExpanded: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.10) : Color.clear)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .frame(width: 16, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(L10n.string(isExpanded ? "收起组成此服务的进程" : "展开组成此服务的进程"))
        .accessibilityLabel(L10n.string(isExpanded ? "收起进程列表" : "展开进程列表"))
        .accessibilityValue(L10n.string(isExpanded ? "已展开" : "已折叠"))
        .accessibilityHint("显示或隐藏组成此服务的具体进程")
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

                        HStack(spacing: 8) {
                            ProcessIconView(record: item.representative, size: 22)
                            Text(item.processName)
                                .font(.headline)
                            Text(item.localPorts.map(String.init).joined(separator: ", "))
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }

                        Text(L10n.string("局部拓扑"))
                            .font(.callout.weight(.semibold))
                        ConnectionDiagramView(
                            item: item,
                            relatedListenerItems: relatedListenerItems(for: item)
                        )
                        if item.representative.isListening {
                            ServiceClientsView(item: item, onSelectItem: onSelectItem)
                                .id(item.id)
                        }
                        PortMappingTopologyView(portViewModel: portViewModel, item: item, historical: hasEnded || portViewModel.state.issueMessage != nil || portViewModel.isPaused)
                        Divider()

                        PortStatusOverview(
                            item: item,
                            listenerActivity: portViewModel.listenerActivitySummary(for: item),
                            hasEnded: hasEnded,
                            observationUncertain: portViewModel.state.issueMessage != nil || portViewModel.isPaused
                        )

                        ForEach(warnings(for: item), id: \.self) { warning in
                            Label(L10n.string(warning.text), systemImage: warning.symbol)
                                .font(.caption)
                                .foregroundStyle(warning.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !hasEnded {
                            TunnelDetailsView(portViewModel: portViewModel, records: item.rawRecords)
                        }

                        if let service = item.representative.context.managedService, service.kind == .docker {
                            DockerStatusDetailsView(portViewModel: portViewModel, service: service)
                            Divider()
                        }
                        PortEventTimelineView(history: portViewModel.eventHistory, item: item)
                        Divider()

                        TechnicalDetailsView(
                            item: item,
                            allItems: allItems,
                            allRecords: allRecords,
                            queryDuration: hasEnded ? nil : queryDuration,
                            queryDiagnostics: hasEnded ? nil : portViewModel.lastQueryDiagnostics,
                            lastSuccessfulUpdate: hasEnded ? item.representative.updatedAt : lastSuccessfulUpdate,
                            isExpanded: $technicalDetailsExpanded,
                            onSelectItem: onSelectItem
                        )

                        Divider()
                        actionSection(for: item)
                    }
                    .padding(16)
                }
                .id(item.id)
            } else {
                TeachingEmptyDetail()
            }
        }
        .background(Color.clear)
    }

    private func endedBanner(for item: ReadablePortItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(portViewModel.state.issueMessage != nil || portViewModel.isPaused
                                 ? "当前无法确认这项活动的状态" : "当前未再观察到这项网络活动"))
                    .font(.headline)
                if let replacement {
                    Text(L10n.format("最近一次采样中，端口由 %@ 使用。", replacement.processName))
                        .font(.callout)
                } else {
                    Text(L10n.string("下方保留最后观察到的信息，可继续查看端口事件。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onDismissEnded) {
                Image(systemName: "xmark")
            }
            .buttonStyle(QuietButtonStyle(size: 28, horizontalPadding: 0))
            .accessibilityLabel("关闭已结束活动的详情")
        }
        .padding(12)
        .frostedSurface(.raised, radius: PVRadius.control)
    }

    private func warnings(for item: ReadablePortItem) -> [MeaningExplanation] {
        var values: [MeaningExplanation] = []
        let record = item.representative
        if !record.belongsToCurrentUser {
            values.append(.init(text: "其他用户的进程，不能直接结束。", symbol: "lock.fill"))
        }
        if ProcessProtectionPolicy.isCritical(record) {
            values.append(.init(text: "关键系统进程，强制结束已禁用。", symbol: "exclamationmark.shield.fill"))
        }
        return values
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
        let isAllowed = processRecords.allSatisfy {
            $0.belongsToCurrentUser && $0.context.identity != nil
                && ($0.context.managedService != nil || !ProcessProtectionPolicy.isSharedServiceHost($0))
        } && !hasEnded
        let impactDescription: String
        if let service = record.context.managedService {
            impactDescription = service.kind == .docker
                ? L10n.string("停止整个容器及其全部发布端口；不会结束 Docker 共享后台进程。")
                : L10n.string("通过 Homebrew 停止整个服务，并取消登录时自动启动。")
        } else if item.processCount > 1 {
            impactDescription = L10n.format(
                "此服务由 %lld 个进程共同提供；结束前需要选择具体进程，其他进程不会同时结束。",
                item.processCount
            )
        } else if otherCount > 0 {
            impactDescription = L10n.format(
                "结束后，这个应用使用的其他 %lld 个端口或连接也会关闭。",
                otherCount
            )
        } else {
            impactDescription = L10n.string("结束的是整个进程；操作前会再次确认它仍在使用这个端口。")
        }

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("操作影响")
                    .font(.callout.weight(.medium))
                Text(impactDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.processCount > 1 && record.context.managedService == nil {
                Menu(L10n.string("选择进程结束…")) {
                    ForEach(processRecords) { processRecord in
                        Button(role: .destructive) {
                            portViewModel.prepareToTerminate(processRecord)
                        } label: {
                            Text(processRecord.processName + " · PID " + String(processRecord.pid))
                        }
                    }
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(portViewModel.isRefreshing || portViewModel.isPerformingOperation || !isAllowed)
                .help(L10n.string("选择要结束的具体进程；操作前仍会重新校验"))
                .accessibilityHint(L10n.string("展开组成此服务的进程列表"))
            } else {
                Button(record.context.managedService?.stopTitle ?? L10n.string("结束进程…"), role: .destructive) {
                    portViewModel.prepareToTerminate(record)
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(portViewModel.isRefreshing || portViewModel.isPerformingOperation || !isAllowed)
                .help(terminationHelp(for: record))
                .accessibilityHint(terminationHelp(for: record))
            }
        }
        .padding(.top, 2)
    }

    private func terminationHelp(for record: PortRecord) -> String {
        if hasEnded { return L10n.string("这项活动已经结束") }
        if !record.belongsToCurrentUser { return L10n.string("该进程属于其他用户，当前版本不会申请管理员权限") }
        if record.context.identity == nil { return L10n.string("无法读取进程启动时间，无法安全结束该进程。") }
        if record.context.managedService == nil, ProcessProtectionPolicy.isSharedServiceHost(record) {
            return L10n.string("未确认容器归属，不能结束共享后台进程。请确认 Docker 正在运行后刷新。")
        }
        return L10n.string("操作前会重新校验进程和端口，并显示确认对话框")
    }
}

private struct ServiceClientsView: View {
    let item: ReadablePortItem
    let onSelectItem: (ReadablePortItem) -> Void
    @State private var expandedClients: Set<String> = []

    private var clientGroups: [(id: String, connections: [ServiceConnection])] {
        Dictionary(grouping: item.serviceConnections) { connection in
            connection.client.map { "pid|\($0.pid)" } ?? "endpoint|" + connection.record.remoteEndpoint
        }.map { (id: $0.key, connections: $0.value) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已接入客户端").font(.callout.weight(.semibold))
                Spacer()
                Text(L10n.format("%lld 条连接", item.serviceConnections.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if item.serviceConnections.isEmpty {
                Text("正在监听，暂未发现连接").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(clientGroups, id: \.id) { group in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedClients.contains(group.id) },
                    set: { if $0 { expandedClients.insert(group.id) } else { expandedClients.remove(group.id) } }
                )) {
                    ForEach(group.connections) { connection in
                        Button {
                            if let child = item.connectionChildren.first(where: { $0.representative.id == connection.id }) {
                                onSelectItem(child)
                            }
                        } label: {
                            HStack {
                                Text(connection.record.remoteEndpoint).monospaced()
                                Spacer()
                                Text(connection.record.friendlyStatusTitle)
                            }
                            .font(.caption)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.connections[0].clientName).lineLimit(1)
                            Text(group.connections[0].client.map { "PID \($0.pid)" } ?? group.connections[0].record.remoteEndpoint)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(L10n.format("%lld 条", group.connections.count)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

private struct MeaningExplanation: Hashable {
    let text: String
    let symbol: String
    var color: Color { PVPalette.warning }
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
                sourceSubtitle = L10n.string("回环直接监听")
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
            let processTitle = processItems.count > 1 ? L10n.format("%lld 个进程", processItems.count) : item.processName
            let processSubtitle = processItems.count > 1 ? "共同使用其中端口" : "应用/服务"
            return [
                .init(id: "source", title: item.serviceConnections.isEmpty ? "访问来源" : "已接入客户端", subtitle: item.serviceConnections.isEmpty ? sourceSubtitle : L10n.format("%lld 条连接", item.serviceConnections.count), symbol: "laptopcomputer.and.arrow.down", explanation: item.accessScope.explanation, items: item.serviceConnections.isEmpty ? sourceItems : Array(Set(item.serviceConnections.map { $0.record.remoteEndpoint })).sorted()),
                .init(id: "port", title: item.localPorts.count > 1 ? L10n.format("%lld 个服务端口", item.localPorts.count) : "服务端口", subtitle: "等待连接", symbol: "rectangle.stack.fill", explanation: item.localPorts.count > 1 ? "这个应用正在通过多个服务端口等待连接；每个端口可以服务不同功能。" : "这是该应用在本机等待连接的服务端口。", items: item.localPorts.map { ":\($0)" }),
                .init(id: "app", title: processTitle, subtitle: processSubtitle, symbol: processItems.count > 1 ? "person.2.fill" : "app.dashed", explanation: processItems.count > 1 ? "这些进程使用了相同的服务端口；这可能来自共享监听、继承的 socket 或不同监听地址。" : "这个应用或后台服务正在使用该端口。", items: processItems.count > 1 ? processItems : [])
            ]
        }

        let target: String
        let targetSubtitle: String
        let targetExplanation: String
        if item.isConnectionSummary, item.remoteTargetCount > 1 {
            target = L10n.format("%lld 个连接目标", item.remoteTargetCount)
            targetSubtitle = L10n.format("共 %lld 条连接", item.connectionCount)
            targetExplanation = "这些连接的对方地址或端口不同。展开技术详情可以查看每一个连接对象。"
        } else {
            target = record.remoteAddress == nil ? "可能的通信对象" : record.remoteAddress ?? "连接对象未知"
            targetSubtitle = record.remotePort.map { L10n.format("端口 %lld", $0) } ?? (record.remoteAddress == nil ? "无固定对象" : "端口未知")
            targetExplanation = record.remoteAddress == nil
                ? "系统没有提供固定的连接对象。"
                : "这是系统返回的另一端地址；不会据此推断网站、位置或安全性。"
        }
        let localPortExplanation: String
        if item.serviceName != nil {
            localPortExplanation = L10n.string("这些连接由服务端接受，客户端通过不同的地址或端口连接到同一服务端口。")
        } else if item.isConnectionSummary, item.connectionCount > 1 {
            localPortExplanation = item.localPorts.count == 1
                ? "多条连接可以共同使用这个本机端口，因为它们的连接对象不同。"
                : "应用通过这些本机连接端口区分多条连接；它们不表示对外开放的服务。"
        } else {
            localPortExplanation = "这是该应用当前在本机使用的端口。"
        }
        return [
            .init(id: "app", title: item.processName, subtitle: "应用/服务", symbol: "app.dashed", explanation: "这个应用或后台服务正在进行网络活动。"),
            .init(id: "port", title: item.serviceName != nil ? "服务端口" : item.isConnectionSummary ? "本机连接端口" : "这台 Mac 的端口", subtitle: item.localPorts.count > 1 ? L10n.format("%lld 个", item.localPorts.count) : item.localPortRelationshipText, symbol: "rectangle.connected.to.line.below", explanation: localPortExplanation, items: item.localPorts.map { ":\($0)" }),
            .init(id: "target", title: item.serviceName != nil ? "客户端" : item.isConnectionSummary ? "连接目标" : target, subtitle: item.isConnectionSummary ? L10n.format("%lld 个 · %lld 条连接", item.remoteTargetCount, item.connectionCount) : targetSubtitle, symbol: "network", explanation: targetExplanation, items: item.isConnectionSummary ? item.remoteEndpoints : [])
        ]
    }

    private var connectors: [RelationshipConnector] {
        let record = item.representative
        if record.isListening {
            return [
                .init(label: item.serviceConnections.isEmpty ? (item.accessScope == .networkPossible ? "可能可访问" : "可以尝试连接") : L10n.format("%lld 条连接", item.serviceConnections.count), bidirectional: !item.serviceConnections.isEmpty, dashed: item.serviceConnections.isEmpty && item.accessScope != .localOnly),
                .init(label: relatedListenerProcessCount > 1 ? L10n.format("%lld 个进程使用", relatedListenerProcessCount) : "等待连接", bidirectional: false, dashed: false)
            ]
        }
        if record.transport == .udp {
            return [
                .init(label: "发送或接收", bidirectional: true, dashed: false),
                .init(label: record.remoteAddress == nil ? "对象不固定" : "通信对象", bidirectional: true, dashed: record.remoteAddress == nil)
            ]
        }
        return [
            .init(label: item.connectionCount > 1 ? L10n.format("%lld 条连接", item.connectionCount) : "存在连接", bidirectional: true, dashed: false),
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
                Label(L10n.string(node.explanation), systemImage: node.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.conclusion)\(item.textualRelationshipDescription)")
    }
}

private struct PortStatusOverview: View {
    let item: ReadablePortItem
    let listenerActivity: ListenerActivitySummary?
    let hasEnded: Bool
    let observationUncertain: Bool

    private var record: PortRecord { item.representative }

    private var statusColor: Color {
        if hasEnded || observationUncertain { return PVPalette.neutral }
        switch item.activityKind {
        case .waiting: return PVPalette.waiting
        case .connected: return PVPalette.connected
        case .transitioning: return PVPalette.warning
        case .other: return PVPalette.neutral
        }
    }

    private var statusTitle: String {
        if observationUncertain { return L10n.string("当前状态待确认") }
        if hasEnded { return L10n.string("当前未再观察到监听") }
        if record.isListening { return L10n.string("正在监听") }
        return item.friendlyStatusTitle
    }

    private var statusSubtitle: String {
        if hasEnded || observationUncertain { return L10n.string("最后一次观察到的端口信息") }
        if let listenerActivity {
            return listenerActivity.connectionCount == 0
                ? L10n.string("正在监听，暂未发现连接")
                : L10n.format("当前观察到 %lld 条连接", listenerActivity.connectionCount)
        }
        switch item.activityKind {
        case .waiting: return L10n.string(item.accessScope.rawValue)
        case .connected: return L10n.string("两端已具备交换数据的条件")
        case .transitioning: return L10n.string("连接正在建立或关闭")
        case .other where item.transport == .udp: return L10n.string("UDP 不保持 TCP 式连接状态")
        case .other: return L10n.string("系统返回了其他网络状态")
        }
    }

    private var statusSymbol: String {
        if observationUncertain { return "questionmark.circle" }
        if hasEnded { return "clock" }
        if let listenerActivity, listenerActivity.connectionCount > 0 { return "arrow.down.left.circle.fill" }
        switch item.activityKind {
        case .waiting: return "dot.radiowaves.left.and.right"
        case .connected: return "link.circle.fill"
        case .transitioning: return "arrow.triangle.2.circlepath.circle.fill"
        case .other: return item.transport == .udp ? "wave.3.right.circle.fill" : "questionmark.circle.fill"
        }
    }

    private var connectionMetric: PortStatusMetricValue {
        if hasEnded || observationUncertain {
            return .init(symbol: "questionmark.circle", title: L10n.string("当前连接"), value: "—")
        }
        if let listenerActivity {
            return .init(
                symbol: listenerActivity.connectionCount > 0 ? "arrow.down.left" : "hourglass",
                title: L10n.string("当前连接"),
                value: String(listenerActivity.connectionCount)
            )
        }
        if item.transport == .udp {
            return .init(symbol: "arrow.left.arrow.right", title: L10n.string("通信方式"), value: L10n.string("无连接"))
        }
        return .init(
            symbol: "link",
            title: L10n.string("连接数量"),
            value: item.connectionCount > 0 ? String(item.connectionCount) : "—"
        )
    }

    private var reachabilityMetric: PortStatusMetricValue {
        if record.isListening {
            switch item.accessScope {
            case .localOnly:
                return .init(symbol: "laptopcomputer", title: L10n.string("访问范围"), value: L10n.string("仅本机"))
            case .networkPossible:
                return .init(symbol: "wifi", title: L10n.string("访问范围"), value: L10n.string("局域网可能"))
            case .unknown:
                return .init(symbol: "questionmark.circle", title: L10n.string("访问范围"), value: L10n.string("暂不确定"))
            }
        }
        return .init(symbol: "arrow.up.right", title: L10n.string("端口角色"), value: item.localPortRoleText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    statusHeading
                    Spacer(minLength: 12)
                    metricStrip
                }
                VStack(alignment: .leading, spacing: 10) {
                    statusHeading
                    metricStrip
                }
            }
            if !hasEnded && !observationUncertain, let recentChange = listenerActivity?.recentChange {
                Label(recentChange.kind.shortDescription, systemImage: recentChangeSymbol(recentChange.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var statusHeading: some View {
        HStack(spacing: PVSpacing.two) {
            Image(systemName: statusSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(PVPalette.textPrimary)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(PVPalette.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    private var metricStrip: some View {
        let metrics = [
            PortStatusMetricValue(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "协议",
                value: record.protocolDisplay
            ),
            connectionMetric,
            reachabilityMetric
        ]

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                    if index > 0 {
                        Divider()
                            .frame(height: 28)
                            .padding(.horizontal, PVSpacing.three)
                    }
                    PortStatusMetric(metric: metric, color: statusColor)
                }
            }

            VStack(alignment: .leading, spacing: PVSpacing.two) {
                ForEach(metrics) { metric in
                    PortStatusMetric(metric: metric, color: statusColor)
                }
            }
        }
    }

    private func recentChangeSymbol(_ kind: PortActivityChangeKind) -> String {
        switch kind {
        case .appeared: return "plus.circle.fill"
        case .ended: return "checkmark.circle"
        case .changed: return "arrow.triangle.2.circlepath"
        }
    }

    private var accessibilityDescription: String {
        let ports = item.localPorts.isEmpty
            ? L10n.string("端口未知")
            : L10n.format("本机%@%@", item.localPortRoleText, item.localPorts.map(String.init).joined(separator: L10n.string("、")))
        let activity = listenerActivity.map { "。\($0.accessibilityDescription)" } ?? ""
        return L10n.format("%@。状态：%@。协议：%@%@", ports, statusTitle, record.protocolDisplay, activity)
    }
}

private struct PortStatusMetricValue: Identifiable {
    let symbol: String
    let title: String
    let value: String

    var id: String { title }
}

private struct PortStatusMetric: View {
    let metric: PortStatusMetricValue
    let color: Color

    var body: some View {
        HStack(spacing: PVSpacing.two) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string(metric.title))
                    .font(.caption2)
                    .foregroundStyle(PVPalette.textTertiary)
                Text(L10n.string(metric.value))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PVPalette.textPrimary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 92, alignment: .leading)
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
    @State private var isHovered = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    var body: some View {
        Button {
            selectedNodeID = node.id
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: node.symbol)
                        .font(.title3)
                        .foregroundStyle(PVPalette.accentPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string(node.title))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(L10n.string(node.subtitle))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if selectedNodeID == node.id || differentiateWithoutColor {
                        Image(systemName: selectedNodeID == node.id ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(selectedNodeID == node.id ? PVPalette.accentPrimary : PVPalette.neutral)
                            .accessibilityHidden(true)
                    }
                }

                if !node.items.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(node.items.prefix(3)), id: \.self) { item in
                            BranchItemRow(text: item)
                        }
                        if node.items.count > 3 {
                            Text(L10n.format("另有 %lld 项", node.items.count - 3))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(PVPalette.accentPrimary)
                                .padding(.leading, 17)
                        }
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(width: 190, alignment: .leading)
            .frame(minHeight: 64, alignment: .leading)
            .premiumControlSurface(
                radius: PVRadius.node,
                isHovered: isHovered,
                isSelected: selectedNodeID == node.id,
                accent: PVPalette.accentPrimary,
                raised: true
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(L10n.string(node.explanation))
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("显示这个节点的解释")
    }

    private var accessibilityText: String {
        let itemText = node.items.isEmpty ? "" : L10n.format("包含：%@。", node.items.map { L10n.string($0) }.joined(separator: L10n.string("、")))
        return L10n.format("%@，%@。%@%@", L10n.string(node.title), L10n.string(node.subtitle), itemText, L10n.string(node.explanation))
    }
}

private struct BranchItemRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(PVPalette.accentPrimary)
                .frame(width: 5, height: 5)
            Rectangle()
                .fill(PVPalette.accentPrimary.opacity(0.45))
                .frame(width: 9, height: 1)
            Text(L10n.string(text))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(PVPalette.accentPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: PVRadius.micro))
        }
    }
}

private struct HorizontalConnectorView: View {
    let connector: RelationshipConnector

    var body: some View {
        VStack(spacing: 3) {
            Text(L10n.string(connector.label))
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
                    .stroke(PVPalette.neutral, style: StrokeStyle(lineWidth: 1.4, dash: connector.dashed ? [5, 4] : []))
                }
                .frame(height: 8)
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 6))
            }
            .foregroundStyle(PVPalette.neutral)
        }
        .frame(minWidth: 70, idealWidth: 100, maxWidth: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string(connector.label) + (connector.dashed ? L10n.string("，虚线表示可能关系") : ""))
    }
}

private struct VerticalConnectorView: View {
    let connector: RelationshipConnector

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: connector.bidirectional ? "arrow.up.arrow.down" : "arrow.down")
            Text(L10n.string(connector.label))
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
    let queryDiagnostics: PortCollectionDiagnostics?
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

                if item.technicalRecords.count > 1 {
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
                .foregroundStyle(PVPalette.textPrimary)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(PVPalette.surfaceControl.opacity(0.46), in: RoundedRectangle(cornerRadius: PVRadius.small))
        }
        .accessibilityHint(L10n.string(isExpanded ? "折叠完整技术参数" : "展开 PID、协议、地址、路径等完整技术参数"))
    }

    private var processFields: [TechnicalField] {
        var fields: [TechnicalField] = [
            .init(title: "应用/服务", value: record.processName, explanation: "正在使用网络的应用、后台服务或系统进程", monospaced: false),
            .init(title: "进程编号", value: item.processSummaries.map { String($0.pid) }.joined(separator: "、"), explanation: "系统分配的临时编号；多个编号表示这项服务由多个进程共同提供"),
            .init(title: "归属用户", value: record.user, explanation: "启动该进程的 macOS 用户", monospaced: false),
            .init(title: "启动来源", value: parentProcessDescription, explanation: "启动当前进程的上一级进程", monospaced: false),
            .init(title: "程序位置", value: record.executablePath ?? "无法获取", explanation: "当前进程对应程序文件在磁盘上的位置", monospaced: false)
        ]
        if let project = record.context.projectName {
            fields.append(.init(title: "所属项目", value: project, explanation: "根据工作目录中的项目清单识别", monospaced: false))
        }
        if let root = record.context.projectRoot {
            fields.append(.init(title: "项目目录", value: root, explanation: "最近的项目清单或 Git 根目录", monospaced: false))
        }
        if let directory = record.context.workingDirectory {
            fields.append(.init(title: "工作目录", value: directory, explanation: "该进程当前所在的目录", monospaced: false))
        }
        if let framework = record.context.framework {
            fields.append(.init(title: "服务类型", value: framework, explanation: "根据启动参数或程序名识别，不按端口猜测", monospaced: false))
        }
        if !record.context.arguments.isEmpty {
            fields.append(.init(title: "启动参数", value: record.context.arguments.joined(separator: " "),
                                explanation: "仅显示进程参数；常见密钥参数已隐藏，不展示或保存环境变量", monospaced: false))
        }
        if let identity = record.context.identity {
            fields.append(.init(title: "启动时间", value: Date(timeIntervalSince1970: Double(identity.startSeconds)).formatted(),
                                explanation: "操作前结合 PID 核对进程身份", monospaced: false))
        }
        if let service = record.context.managedService {
            fields.append(.init(title: "服务管理", value: service.kind.rawValue + " · " + service.name,
                                explanation: "通过对应管理器停止整个服务", monospaced: false))
        }
        if item.processCount > 1 {
            fields.insert(
                .init(title: "组成进程", value: L10n.format("%lld 个", item.processCount), explanation: "这些进程使用了同一组服务端口", monospaced: false),
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
        let endpoints = Array(Set(item.technicalRecords.compactMap { raw -> String? in
            if local { return raw.localEndpoint }
            return raw.remoteAddress == nil ? nil : raw.remoteEndpoint
        })).sorted()
        guard !endpoints.isEmpty else { return "—" }
        guard endpoints.count > 3 else { return endpoints.joined(separator: "、") }
        return L10n.format("%lld 个端点：%@…", endpoints.count, endpoints.prefix(3).joined(separator: L10n.string("、")))
    }

    private var stateSummary: String {
        let states = Array(Set(item.technicalRecords.compactMap(\.normalizedState))).sorted()
        if states.isEmpty { return L10n.string("无（UDP 或系统未提供）") }
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
            .init(title: "底层记录数量", value: String(item.technicalRecords.count), explanation: "当前易读项目包含的原始系统记录数量"),
            .init(title: "采集来源", value: collectionSource, explanation: "最近一次端口快照使用的采集方式"),
            .init(title: "本次查询耗时", value: queryDuration.map { String(format: "%.0f ms", $0 * 1_000) } ?? "无法获取", explanation: "包含端口采集和项目、服务信息补全的总耗时")
        ]
    }

    private var collectionSource: String {
        switch queryDiagnostics?.source {
        case .darwin: L10n.string("macOS 原生 API")
        case .lsof: "lsof"
        case .lsofFallback: L10n.string("lsof（原生采集回退）")
        case nil: L10n.string("无法获取")
        }
    }

    private var parentProcessDescription: String {
        guard let parentPID = record.parentPID else { return L10n.string("无法获取") }
        if let parent = allRecords.first(where: { $0.pid == parentPID }) {
            return "\(parent.processName)（PID \(parentPID)）"
        }
        return "PID \(parentPID)"
    }

    private func technicalGroup(_ title: String, fields: [TechnicalField]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string(title))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(fields) { field in
                    HStack(alignment: .top, spacing: 12) {
                        Text(L10n.string(field.title))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(L10n.string(field.value))
                            .font(field.monospaced ? .system(.caption, design: .monospaced) : .caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help(L10n.string(field.explanation))
                }
            }
        }
    }

    private var rawRecordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("组成此活动的技术记录")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(item.technicalRecords) { raw in
                Text([
                    "PID " + String(raw.pid), raw.ipVersion.rawValue, raw.transport.rawValue,
                    raw.localEndpoint, raw.remoteEndpoint, raw.normalizedState ?? "无状态",
                    "FD " + raw.fileDescriptor
                ].joined(separator: " · "))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(PVPalette.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: PVRadius.small))
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
                .buttonStyle(QuietButtonStyle(size: 30, horizontalPadding: 8))
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
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("选择一项查看详情")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("了解端口") {
                showsPortHelp = true
            }
            .buttonStyle(QuietButtonStyle(size: 28, horizontalPadding: 8))
            .popover(isPresented: $showsPortHelp) {
                HelpPopover(
                    title: "什么是端口？",
                    text: "本机端口是应用在这台 Mac 上收发网络数据时使用的编号。服务端口用于等待连接；连接其他服务时，macOS 通常还会分配本机连接端口。相同端口不一定是同一连接，多个连接端口也不代表应用对外开放了多个服务。"
                )
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PVPalette.surfaceBento.opacity(0.55))
    }
}

private struct HelpPopover: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.string(title))
                .font(.headline)
            Text(L10n.string(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .frostedSurface(.floating, radius: PVRadius.floating)
    }
}

private struct QueryBanner: View {
    let message: String
    let symbol: String
    let color: Color
    var actionTitle = "重试"
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(L10n.string(message))
                .lineLimit(2)
            Spacer()
            Button(L10n.string(actionTitle), action: action)
                .buttonStyle(GlassButtonStyle(height: 28, horizontalPadding: 9))
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(color.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(color.opacity(0.28))
                .frame(height: 1)
        }
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
            .buttonStyle(QuietButtonStyle(size: 28, horizontalPadding: 0))
            .accessibilityLabel("关闭操作结果")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 42)
        .frostedSurface(.floating, radius: PVRadius.panel)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        case .success: return PVPalette.waiting
        case .warning: return PVPalette.warning
        case .error: return PVPalette.danger
        case .information: return PVPalette.connected
        }
    }
}
