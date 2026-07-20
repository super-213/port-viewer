import AppKit
import SwiftUI

struct StatusItemLabel: View {
    @ObservedObject var store: PortStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarShowsCount") private var showsCount = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: store.statusSymbolName)
                .symbolVariant(.fill)
            if showsCount {
                Text(store.listeningCount > 999 ? "999+" : String(store.listeningCount))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .task {
            guard store.claimInitialWindowRequest() else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApplication.shared.setActivationPolicy(.regular)
            if !NSApplication.shared.windows.contains(where: { $0.title == "Port Viewer" }) {
                openWindow(id: "main")
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private var accessibilityLabel: String {
        if store.isPaused { return "Port Viewer，自动刷新已暂停" }
        if store.state.issueMessage != nil { return "Port Viewer，查询异常" }
        return "Port Viewer，监听端口 \(store.listeningCount) 个"
    }
}

struct MenuBarPanel: View {
    @ObservedObject var store: PortStore
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""

    private var displayedRecords: [PortRecord] {
        let listeners = store.records.filter(\.isListening)
        let sorted = listeners.sorted {
            if $0.localPortSortValue != $1.localPortSortValue {
                return $0.localPortSortValue < $1.localPortSortValue
            }
            return $0.processName.localizedStandardCompare($1.processName) == .orderedAscending
        }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(sorted.prefix(10))
        }
        return Array(sorted.filter { PortSearch.rank(of: $0, query: searchText) != nil }.prefix(10))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            metrics
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            Divider()
            recordList
            Divider()
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Port Viewer")
                    .font(.headline)
                Text(updateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("立即刷新")
            .accessibilityLabel("立即刷新端口列表")
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索端口或进程", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("菜单栏端口搜索")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            metric(title: "监听", value: store.listeningCount, symbol: "dot.radiowaves.left.and.right", color: .green)
            Divider().frame(height: 28)
            metric(title: "活跃连接", value: store.activeConnectionCount, symbol: "arrow.left.arrow.right", color: .blue)
        }
        .frame(maxWidth: .infinity)
    }

    private func metric(title: String, value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(value)).font(.headline).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value) 个")
    }

    @ViewBuilder
    private var recordList: some View {
        if displayedRecords.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: searchText.isEmpty ? "checkmark.circle" : "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(searchText.isEmpty ? "当前没有 TCP 监听端口" : "没有匹配的监听端口")
                    .font(.callout)
                if !searchText.isEmpty {
                    Button("清除搜索") { searchText = "" }
                        .buttonStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 128)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(displayedRecords) { record in
                        Button {
                            openMainWindow(selecting: record)
                        } label: {
                            HStack(spacing: 10) {
                                Text(":\(record.localPortText)")
                                    .font(.system(.body, design: .monospaced, weight: .medium))
                                    .frame(width: 72, alignment: .leading)
                                ProcessIconView(record: record, size: 18)
                                Text(record.processName)
                                    .lineLimit(1)
                                Spacer()
                                Text("监听")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("端口 \(record.localPortText)，\(record.processName)，监听中")
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 340)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("打开主窗口") { openMainWindow(selecting: nil) }
                .buttonStyle(.link)
            Spacer()
            SettingsLink {
                Text("设置")
            }
            .buttonStyle(.link)
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var updateDescription: String {
        if store.isPaused { return "自动刷新已暂停" }
        if let issue = store.state.issueMessage { return issue }
        if let date = store.lastSuccessfulUpdate {
            return "已更新 \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "等待首次查询"
    }

    private func openMainWindow(selecting record: PortRecord?) {
        if let record { store.selectFromMenuBar(record) }
        if let existingWindow = NSApplication.shared.windows.first(where: { $0.title == "Port Viewer" }) {
            existingWindow.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
