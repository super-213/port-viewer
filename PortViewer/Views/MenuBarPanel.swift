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
        ZStack {
            PremiumCanvas()

            VStack(spacing: 0) {
                header
                searchField
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                metrics
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                PremiumSeparator()
                recordList
                PremiumSeparator()
                footer
            }
            .frostedSurface(.chrome, radius: PVRadius.floating)
            .padding(8)
        }
        .frame(width: 396)
        .onAppear {
            portViewModel.setMenuBarPanelVisible(true)
        }
        .onDisappear {
            portViewModel.setMenuBarPanelVisible(false)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(PVPalette.accentGradient)
                Image(systemName: "network")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Port Viewer")
                    .font(.headline)
                Text(viewModel.updateDescription)
                    .font(.caption)
                    .foregroundStyle(PVPalette.textTertiary)
            }
            Spacer()
            Button {
                portViewModel.refreshNow()
            } label: {
                if portViewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(portViewModel.isRefreshing)
            .help("立即刷新")
            .accessibilityLabel("立即刷新端口列表")
        }
        .padding(16)
    }

    private var searchField: some View {
        PremiumSearchField(
            text: $viewModel.searchText,
            prompt: "搜索应用名称或端口，例如 3000",
            compact: true
        )
        .accessibilityLabel("菜单栏端口搜索")
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            metric(title: "等待连接", value: portViewModel.listeningCount, symbol: "dot.radiowaves.left.and.right", color: PVPalette.waiting)
            railSeparator
            metric(title: "连接活动", value: portViewModel.activeConnectionCount, symbol: "arrow.left.arrow.right", color: PVPalette.connected)
            railSeparator
            metric(title: "其他网络活动", value: portViewModel.otherNetworkActivityCount, symbol: "antenna.radiowaves.left.and.right", color: PVPalette.neutral)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 52)
        .premiumControlSurface(radius: PVRadius.node)
    }

    private func metric(title: String, value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(value)).font(.headline).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(PVPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value) 个")
    }

    private var railSeparator: some View {
        Rectangle()
            .fill(PVPalette.edgeSeparator)
            .frame(width: 1, height: 28)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var recordList: some View {
        if viewModel.displayedRecords.isEmpty {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(PVPalette.surfaceControl)
                        .frame(width: 42, height: 42)
                    Image(systemName: viewModel.searchText.isEmpty ? "checkmark.circle" : "magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(PVPalette.neutral)
                }
                Text(viewModel.searchText.isEmpty ? "当前没有应用在等待连接" : "没有匹配的等待连接活动")
                    .font(.callout)
                if !viewModel.searchText.isEmpty {
                    Button("清除搜索") { viewModel.clearSearch() }
                        .buttonStyle(GlassButtonStyle(height: 28))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 128)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.displayedRecords) { record in
                        MenuBarRecordButton(record: record) {
                            openMainWindow(selecting: record)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 340)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                openMainWindow(selecting: nil)
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
            }
            .buttonStyle(GlassButtonStyle(height: 30))
            Spacer()
            SettingsLink {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(QuietButtonStyle(size: 30, horizontalPadding: 7))
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(QuietButtonStyle(size: 30, horizontalPadding: 7))
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
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

private struct MenuBarRecordButton: View {
    let record: PortRecord
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(":\(record.localPortText)")
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .foregroundStyle(PVPalette.waiting)
                    .frame(width: 72, alignment: .leading)
                    .padding(.vertical, 3)
                    .background(PVPalette.waiting.opacity(0.09), in: RoundedRectangle(cornerRadius: PVRadius.micro))
                ProcessIconView(record: record, size: 18)
                Text(record.processName)
                    .foregroundStyle(PVPalette.textPrimary)
                    .lineLimit(1)
                Spacer()
                Label("等待连接", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(PVPalette.waiting)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(
                PVPalette.accentPrimary.opacity(isHovered ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: PVRadius.small)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(PVMotion.hover) { isHovered = hovering }
        }
        .accessibilityLabel("端口 \(record.localPortText)，\(record.processName)，正在等待连接")
    }
}
