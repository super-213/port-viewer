import AppKit
import SwiftUI

private enum SidebarScope: String, CaseIterable, Identifiable {
    case all = "全部"
    case listening = "监听端口"
    case active = "活跃连接"
    case udp = "UDP"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .all: return "list.bullet"
        case .listening: return "dot.radiowaves.left.and.right"
        case .active: return "arrow.left.arrow.right"
        case .udp: return "antenna.radiowaves.left.and.right"
        }
    }
}

private enum ProtocolFilter: String, CaseIterable, Identifiable {
    case all = "全部协议"
    case tcp = "TCP"
    case udp = "UDP"
    var id: Self { self }
}

private enum IPFilter: String, CaseIterable, Identifiable {
    case all = "全部 IP"
    case v4 = "IPv4"
    case v6 = "IPv6"
    var id: Self { self }
}

private enum OwnerFilter: String, CaseIterable, Identifiable {
    case all = "全部用户"
    case current = "当前用户"
    case others = "其他用户"
    var id: Self { self }
}

struct MainWindowView: View {
    @ObservedObject var store: PortStore
    @State private var scope: SidebarScope = .all
    @State private var searchText = ""
    @State private var protocolFilter: ProtocolFilter = .all
    @State private var ipFilter: IPFilter = .all
    @State private var ownerFilter: OwnerFilter = .all
    @State private var stateFilter = ""
    @State private var selectedID: PortRecord.ID?
    @State private var sortOrder: [KeyPathComparator<PortRecord>] = [
        KeyPathComparator(\PortRecord.localPortSortValue),
        KeyPathComparator(\PortRecord.processName)
    ]
    @FocusState private var searchIsFocused: Bool

    private var selectedRecord: PortRecord? {
        guard let selectedID else { return nil }
        return store.records.first { $0.id == selectedID }
    }

    private var displayedRecords: [PortRecord] {
        var filtered = store.records.filter(matchesScope)
            .filter(matchesProtocol)
            .filter(matchesIPVersion)
            .filter(matchesOwner)
            .filter(matchesState)
            .filter { PortSearch.rank(of: $0, query: searchText) != nil }

        filtered.sort(using: sortOrder)

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return filtered }

        return filtered.enumerated().sorted { left, right in
            let leftRank = PortSearch.rank(of: left.element, query: query) ?? Int.max
            let rightRank = PortSearch.rank(of: right.element, query: query) ?? Int.max
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element)
    }

    private var stateOptions: [String] {
        Array(Set(store.records.compactMap(\.state))).sorted()
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
                    protocolFilter: $protocolFilter,
                    ipFilter: $ipFilter,
                    ownerFilter: $ownerFilter,
                    stateFilter: $stateFilter,
                    stateOptions: stateOptions,
                    hasActiveFilters: hasActiveFilters,
                    reset: resetFilters
                )
                Divider()

                tableOrState
                    .frame(minHeight: 280)

                Divider()
                RecordDetailView(record: selectedRecord, allRecords: store.records, store: store)
                    .frame(minHeight: 210, idealHeight: 230, maxHeight: 280)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 620)
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索端口、PID 或进程")
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
        .onChange(of: displayedRecords.map(\.id)) { _, visibleIDs in
            if let selectedID, !visibleIDs.contains(selectedID) {
                self.selectedID = nil
            }
        }
        .onExitCommand {
            if !searchText.isEmpty { searchText = "" }
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
                HStack {
                    Text(item.rawValue)
                    Spacer()
                    Text(String(count(for: item)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } icon: {
                Image(systemName: item.symbol)
            }
            .tag(item)
            .accessibilityLabel("\(item.rawValue)，\(count(for: item)) 条")
        }
        .listStyle(.sidebar)
        .navigationTitle("Port Viewer")
        .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 245)
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
            .accessibilityLabel("立即刷新端口列表")

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
                Text("正在查询本机端口…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedRecords.isEmpty {
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
            PortTable(records: displayedRecords, selectedID: $selectedID, sortOrder: $sortOrder)
        }
    }

    private var emptyStateTitle: String {
        if !searchText.isEmpty { return "没有匹配结果" }
        if hasActiveFilters { return "筛选条件下没有记录" }
        return "当前没有端口记录"
    }

    private var emptyStateDescription: String {
        if !searchText.isEmpty { return "没有记录匹配“\(searchText)”及当前筛选条件。" }
        if hasActiveFilters { return "尝试重置协议、IP、用户或状态筛选。" }
        return "lsof 没有返回 TCP 或 UDP 网络记录。"
    }

    private var hasActiveFilters: Bool {
        protocolFilter != .all || ipFilter != .all || ownerFilter != .all || !stateFilter.isEmpty
    }

    private func resetFilters() {
        protocolFilter = .all
        ipFilter = .all
        ownerFilter = .all
        stateFilter = ""
    }

    private func adoptRequestedSelection(_ id: String?) {
        guard let id, store.records.contains(where: { $0.id == id }) else { return }
        scope = .all
        searchText = ""
        resetFilters()
        selectedID = id
    }

    private func count(for scope: SidebarScope) -> Int {
        store.records.lazy.filter { record in
            switch scope {
            case .all: return true
            case .listening: return record.isListening
            case .active: return record.isActiveConnection
            case .udp: return record.transport == .udp
            }
        }.count
    }

    private func matchesScope(_ record: PortRecord) -> Bool {
        switch scope {
        case .all: return true
        case .listening: return record.isListening
        case .active: return record.isActiveConnection
        case .udp: return record.transport == .udp
        }
    }

    private func matchesProtocol(_ record: PortRecord) -> Bool {
        switch protocolFilter {
        case .all: return true
        case .tcp: return record.transport == .tcp
        case .udp: return record.transport == .udp
        }
    }

    private func matchesIPVersion(_ record: PortRecord) -> Bool {
        switch ipFilter {
        case .all: return true
        case .v4: return record.ipVersion == .v4
        case .v6: return record.ipVersion == .v6
        }
    }

    private func matchesOwner(_ record: PortRecord) -> Bool {
        switch ownerFilter {
        case .all: return true
        case .current: return record.belongsToCurrentUser
        case .others: return !record.belongsToCurrentUser
        }
    }

    private func matchesState(_ record: PortRecord) -> Bool {
        stateFilter.isEmpty || record.state == stateFilter
    }
}

private struct OverviewBar: View {
    @ObservedObject var store: PortStore

    var body: some View {
        HStack(spacing: 18) {
            Label("监听 \(store.listeningCount)", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
            Label("活跃连接 \(store.activeConnectionCount)", systemImage: "arrow.left.arrow.right")
                .foregroundStyle(.blue)
            Spacer()
            if let update = store.lastSuccessfulUpdate {
                Text("最后更新 \(update.formatted(date: .omitted, time: .standard))")
                    .foregroundStyle(.secondary)
            } else {
                Text("等待首次查询")
                    .foregroundStyle(.secondary)
            }
            if let duration = store.lastQueryDuration {
                Text(String(format: "%.0f ms", duration * 1_000))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .frame(height: 42)
        .accessibilityElement(children: .combine)
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

private struct FilterBar: View {
    @Binding var protocolFilter: ProtocolFilter
    @Binding var ipFilter: IPFilter
    @Binding var ownerFilter: OwnerFilter
    @Binding var stateFilter: String
    let stateOptions: [String]
    let hasActiveFilters: Bool
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("协议", selection: $protocolFilter) {
                ForEach(ProtocolFilter.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .labelsHidden()
            .frame(width: 120)
            .accessibilityLabel("协议筛选")

            Picker("IP 版本", selection: $ipFilter) {
                ForEach(IPFilter.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityLabel("IP 版本筛选")

            Picker("用户", selection: $ownerFilter) {
                ForEach(OwnerFilter.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .labelsHidden()
            .frame(width: 120)
            .accessibilityLabel("用户筛选")

            Picker("TCP 状态", selection: $stateFilter) {
                Text("全部状态").tag("")
                ForEach(stateOptions, id: \.self) { state in Text(state).tag(state) }
            }
            .labelsHidden()
            .frame(width: 145)
            .accessibilityLabel("TCP 状态筛选")

            Spacer()
            if hasActiveFilters {
                Button("重置筛选", action: reset)
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

private struct PortTable: View {
    let records: [PortRecord]
    @Binding var selectedID: PortRecord.ID?
    @Binding var sortOrder: [KeyPathComparator<PortRecord>]

    var body: some View {
        Table(records, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn("进程", value: \.processName) { record in
                HStack(spacing: 7) {
                    ProcessIconView(record: record, size: 18)
                    Text(record.processName).lineLimit(1)
                    if !record.belongsToCurrentUser {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("其他用户进程")
                    }
                }
            }
            .width(min: 135, ideal: 180)

            TableColumn("PID", value: \.pid) { record in
                Text(String(record.pid)).monospacedDigit()
            }
            .width(min: 58, ideal: 70, max: 90)

            TableColumn("协议", value: \.transportSortValue) { record in
                Text(record.transport.rawValue)
            }
            .width(min: 58, ideal: 68, max: 78)

            TableColumn("本地端点", value: \.localPortSortValue) { record in
                Text(record.localEndpoint).font(.system(.body, design: .monospaced))
            }
            .width(min: 135, ideal: 180)

            TableColumn("远端端点") { record in
                Text(record.remoteEndpoint)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(record.remoteAddress == nil ? .secondary : .primary)
            }
            .width(min: 135, ideal: 190)

            TableColumn("状态", value: \.statusSortValue) { record in
                StatusLabel(record: record)
            }
            .width(min: 88, ideal: 105, max: 130)

            TableColumn("用户", value: \.user) { record in
                Text(record.user).lineLimit(1)
            }
            .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityLabel("端口和网络连接列表")
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

private struct StatusLabel: View {
    let record: PortRecord

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2)
            Text(record.statusDisplay)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if record.isListening { return "circle.fill" }
        if record.isActiveConnection { return "arrow.left.arrow.right" }
        if record.transport == .udp { return "circle.dotted" }
        return "circle"
    }

    private var color: Color {
        if record.isListening { return .green }
        if record.isActiveConnection { return .blue }
        return .secondary
    }
}

private struct RecordDetailView: View {
    let record: PortRecord?
    let allRecords: [PortRecord]
    @ObservedObject var store: PortStore

    var body: some View {
        Group {
            if let record {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            ProcessIconView(record: record, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.processName).font(.headline)
                                Text("PID \(record.pid) · \(record.user)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusLabel(record: record)
                            Button("结束进程", role: .destructive) {
                                Task { await store.prepareToTerminate(record) }
                            }
                            .disabled(store.isRefreshing)
                            .accessibilityHint("操作前会重新校验进程和端口，并显示确认对话框")
                        }

                        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                            detailRow("本地端点", record.localEndpoint, "远端端点", record.remoteEndpoint)
                            detailRow("协议", record.protocolDisplay, "状态", record.statusDisplay)
                            detailRow("文件描述符", record.fileDescriptor, "更新时间", record.updatedAt.formatted(date: .omitted, time: .standard))
                            detailRow("可执行路径", record.executablePath ?? "无法获取", "父进程", parentProcessDescription(for: record))
                        }
                        .textSelection(.enabled)

                        if let endpoints = otherEndpointsDescription(for: record) {
                            Label("同进程其他端点：\(endpoints)", systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Label(riskMessage(for: record), systemImage: riskSymbol(for: record))
                            .font(.callout)
                            .foregroundStyle(riskColor(for: record))
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("选择一条记录查看详情")
                        .font(.headline)
                    Text("详情包含端点、文件描述符、父进程及安全的进程结束入口。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func detailRow(_ firstTitle: String, _ firstValue: String, _ secondTitle: String, _ secondValue: String) -> some View {
        GridRow {
            Text(firstTitle).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            Text(firstValue).lineLimit(1).truncationMode(.middle)
            Text(secondTitle).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            Text(secondValue).lineLimit(1).truncationMode(.middle)
        }
        .font(.callout)
    }

    private func parentProcessDescription(for record: PortRecord) -> String {
        guard let parentPID = record.parentPID else { return "无法获取" }
        if let parent = allRecords.first(where: { $0.pid == parentPID }) {
            return "\(parent.processName)（PID \(parentPID)）"
        }
        return "PID \(parentPID)"
    }

    private func otherEndpointsDescription(for record: PortRecord) -> String? {
        let endpoints = Array(Set(allRecords.filter {
            $0.pid == record.pid && $0.id != record.id
        }.map {
            "\($0.transport.rawValue) \($0.localEndpoint)"
        })).sorted()
        guard !endpoints.isEmpty else { return nil }

        let visible = endpoints.prefix(6).joined(separator: "、")
        return endpoints.count > 6 ? "\(visible) 等 \(endpoints.count) 条" : visible
    }

    private func riskMessage(for record: PortRecord) -> String {
        if ProcessProtectionPolicy.isCritical(record) {
            return "关键系统进程：普通结束仍需谨慎，强制结束已被禁用。"
        }
        if !record.belongsToCurrentUser {
            return "其他用户进程：当前版本只解释权限要求，不会申请管理员授权。"
        }
        return "结束进程会同时关闭该进程使用的其他端口；操作后将重新查询实际状态。"
    }

    private func riskSymbol(for record: PortRecord) -> String {
        ProcessProtectionPolicy.isCritical(record) || !record.belongsToCurrentUser
            ? "exclamationmark.triangle.fill" : "info.circle"
    }

    private func riskColor(for record: PortRecord) -> Color {
        ProcessProtectionPolicy.isCritical(record) || !record.belongsToCurrentUser ? .orange : .secondary
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
