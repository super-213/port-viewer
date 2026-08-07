import SwiftUI

struct NetworkScanView: View {
    @Bindable var viewModel: NetworkScanViewModel

    var body: some View {
        HSplitView {
            configurationPanel
                .frame(minWidth: 330, idealWidth: 370, maxWidth: 420)

            resultsPanel
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: PVRadius.panel, style: .continuous))
        .frostedSurface(.content, radius: PVRadius.panel)
        .padding(10)
    }

    private var configurationPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("网络端口扫描", systemImage: "dot.radiowaves.left.and.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(PVPalette.textPrimary)
                    Text("主动建立 TCP 连接，检查另一台设备或局域网主机的端口是否响应。")
                        .font(.callout)
                        .foregroundStyle(PVPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Form {
                    Section("扫描目标") {
                        Picker("范围", selection: $viewModel.scope) {
                            ForEach(NetworkScanScope.allCases) { scope in
                                Text(scope.rawValue).tag(scope)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("扫描范围")

                        TextField(viewModel.scope.targetPrompt, text: $viewModel.target)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isRunning)
                            .accessibilityLabel(viewModel.scope == .host ? "目标主机" : "目标 IPv4 网段")
                    }

                    Section("TCP 端口") {
                        Picker("端口范围", selection: $viewModel.portPreset) {
                            ForEach(ScanPortPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .disabled(viewModel.isRunning)

                        if viewModel.portPreset == .custom {
                            TextField("例如 22,80,443,8000-8100", text: $viewModel.customPorts)
                                .textFieldStyle(.roundedBorder)
                                .disabled(viewModel.isRunning)
                                .accessibilityLabel("自定义 TCP 端口")
                        }
                    }

                    Section("响应等待") {
                        Picker("每个端口超时", selection: $viewModel.timeoutOption) {
                            ForEach(ScanTimeoutOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .disabled(viewModel.isRunning)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(minHeight: viewModel.portPreset == .custom ? 345 : 305)

                if let validationMessage = viewModel.validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(PVPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("输入错误：\(validationMessage)")
                }

                HStack(spacing: 8) {
                    if viewModel.isRunning {
                        Button("取消扫描") { viewModel.cancelScan() }
                            .buttonStyle(DangerButtonStyle())
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button {
                            viewModel.startScan()
                        } label: {
                            Label("开始扫描", systemImage: "play.fill")
                        }
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    }

                    if viewModel.report != nil {
                        Button("清除结果") { viewModel.clearResults() }
                            .buttonStyle(GlassButtonStyle())
                    }
                }

                Label(
                    "仅扫描你拥有或获准测试的设备。扫描使用 TCP connect，不发送 UDP 数据，也不会修改目标设备、防火墙或路由器。",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(PVPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .background(PVPalette.surfaceBento)
    }

    private var resultsPanel: some View {
        VStack(spacing: 0) {
            statusHeader
            PremiumSeparator()

            if viewModel.isRunning {
                runningState
            } else if let report = viewModel.report {
                reportContent(report)
            } else {
                ContentUnavailableView {
                    Label(viewModel.stateTitle, systemImage: stateSymbol)
                } description: {
                    Text(viewModel.stateDescription)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: stateSymbol)
                .foregroundStyle(stateColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.stateTitle)
                    .font(.headline)
                    .foregroundStyle(PVPalette.textPrimary)
                Text(viewModel.stateDescription)
                    .font(.caption)
                    .foregroundStyle(PVPalette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if viewModel.isRunning {
                Text(viewModel.progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PVPalette.textPrimary)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 68)
        .accessibilityElement(children: .combine)
    }

    private var runningState: some View {
        VStack(spacing: 16) {
            ProgressView(value: viewModel.progress.fractionCompleted)
                .progressViewStyle(.linear)
                .frame(maxWidth: 460)
                .accessibilityLabel("扫描进度")
                .accessibilityValue("已完成 \(viewModel.progress.completedCount) / \(viewModel.progress.totalCount)")

            if let endpoint = viewModel.progress.currentEndpoint {
                Text("正在处理 \(endpoint)")
                    .font(.callout.monospaced())
                    .foregroundStyle(PVPalette.textSecondary)
                    .lineLimit(1)
            }

            Label("已发现 \(viewModel.progress.openCount) 个开放端口", systemImage: "checkmark.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(PVPalette.waiting)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func reportContent(_ report: NetworkScanReport) -> some View {
        if report.openPorts.isEmpty {
            ContentUnavailableView {
                Label("未探测到开放端口", systemImage: "network.slash")
            } description: {
                Text(viewModel.stateDescription)
            } actions: {
                Button("调整目标或端口") { viewModel.clearResults() }
                    .buttonStyle(GlassButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(report.openPorts) {
                TableColumn("主机") { result in
                    Text(result.host)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                .width(min: 180, ideal: 260)

                TableColumn("端口") { result in
                    Text(String(result.port))
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(PVPalette.textPrimary)
                        .textSelection(.enabled)
                }
                .width(min: 72, ideal: 90, max: 120)

                TableColumn("状态") { _ in
                    Label("开放", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(PVPalette.waiting)
                }
                .width(min: 90, ideal: 110, max: 130)

                TableColumn("连接耗时") { result in
                    Text(latencyDescription(result.latency))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(PVPalette.textSecondary)
                }
                .width(min: 100, ideal: 120, max: 150)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .accessibilityLabel("开放端口扫描结果，共 \(report.openPorts.count) 条")
        }
    }

    private var stateSymbol: String {
        switch viewModel.state {
        case .idle: return "dot.radiowaves.left.and.right"
        case .running: return "antenna.radiowaves.left.and.right"
        case .finished where viewModel.openPorts.isEmpty: return "network.slash"
        case .finished: return "checkmark.circle.fill"
        case .cancelled: return "stop.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var stateColor: Color {
        switch viewModel.state {
        case .finished where !viewModel.openPorts.isEmpty: return PVPalette.waiting
        case .failed: return PVPalette.danger
        case .cancelled: return PVPalette.warning
        default: return PVPalette.accentPrimary
        }
    }

    private func latencyDescription(_ latency: TimeInterval) -> String {
        let milliseconds = max(0, latency * 1_000)
        if milliseconds < 1 { return "< 1 ms" }
        return "\(Int(milliseconds.rounded())) ms"
    }
}
