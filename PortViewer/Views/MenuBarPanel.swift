import AppKit
import SwiftUI

struct StatusItemLabel: View {
    let portViewModel: PortViewModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarShowsCount") private var showsCount = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: portViewModel.statusSymbolName)
                .symbolVariant(.fill)
            if showsCount {
                Text(portViewModel.listeningCount > 999 ? "999+" : String(portViewModel.listeningCount))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .task {
            guard portViewModel.claimInitialWindowRequest() else { return }
            try? await Task.sleep(for: .milliseconds(300))
            NSApplication.shared.setActivationPolicy(.regular)
            if !NSApplication.shared.windows.contains(where: { $0.title == "Port Viewer" }) {
                openWindow(id: "main")
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private var accessibilityLabel: String {
        if portViewModel.isPaused { return "Port Viewer，自动刷新已暂停" }
        if portViewModel.state.issueMessage != nil { return "Port Viewer，查询异常" }
        return "Port Viewer，等待连接 \(portViewModel.listeningCount) 条"
    }
}

struct MenuBarPanel: View {
    let portViewModel: PortViewModel
    @Bindable var viewModel: MenuBarViewModel
    let mainWindowViewModel: MainWindowViewModel
    @Environment(\.openWindow) private var openWindow

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
        .onAppear {
            portViewModel.setMenuBarPanelVisible(true)
        }
        .onDisappear {
            portViewModel.setMenuBarPanelVisible(false)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Port Viewer")
                    .font(.headline)
                Text(viewModel.updateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                portViewModel.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(portViewModel.isRefreshing)
            .help("立即刷新")
            .accessibilityLabel("立即刷新端口列表")
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索应用名称或端口，例如 3000", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("菜单栏端口搜索")
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.clearSearch()
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
            metric(title: "等待连接", value: portViewModel.listeningCount, symbol: "dot.radiowaves.left.and.right", color: .green)
            Divider().frame(height: 28)
            metric(title: "连接活动", value: portViewModel.activeConnectionCount, symbol: "arrow.left.arrow.right", color: .blue)
            Divider().frame(height: 28)
            metric(title: "其他网络活动", value: portViewModel.otherNetworkActivityCount, symbol: "antenna.radiowaves.left.and.right", color: .secondary)
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
        if viewModel.displayedRecords.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: viewModel.searchText.isEmpty ? "checkmark.circle" : "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(viewModel.searchText.isEmpty ? "当前没有应用在等待连接" : "没有匹配的等待连接活动")
                    .font(.callout)
                if !viewModel.searchText.isEmpty {
                    Button("清除搜索") { viewModel.clearSearch() }
                        .buttonStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 128)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.displayedRecords) { record in
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
                                Text("等待连接")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("端口 \(record.localPortText)，\(record.processName)，正在等待连接")
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

    private func openMainWindow(selecting record: PortRecord?) {
        if let record { mainWindowViewModel.selectFromMenuBar(record) }
        if let existingWindow = NSApplication.shared.windows.first(where: { $0.title == "Port Viewer" }) {
            existingWindow.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
