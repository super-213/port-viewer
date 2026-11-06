import SwiftUI

struct SettingsView: View {
    let portViewModel: PortViewModel
    @AppStorage("cloudflareTunnelEnabled") private var tunnelEnabled = true
    @AppStorage("cloudflareTunnelEndpoint") private var tunnelEndpoint = TunnelDefaults.endpoint
    @State private var endpointDraft = TunnelDefaults.endpoint
    @AppStorage("menuBarShowsCount") private var menuBarShowsCount = true
    @AppStorage("foregroundRefreshInterval") private var foregroundRefreshInterval = 3.0
    @AppStorage("backgroundRefreshInterval") private var backgroundRefreshInterval = 30.0

    var body: some View {
        Form {
            Section("菜单栏") {
                HStack(spacing: 12) {
                    Label("显示等待连接数量", systemImage: "menubar.rectangle")
                        .foregroundStyle(PVPalette.textPrimary)
                    Spacer()
                    Toggle("在图标旁显示等待连接数量", isOn: $menuBarShowsCount)
                        .labelsHidden()
                }
            }
            .listRowBackground(PVPalette.surfaceBento)

            Section("自动刷新") {
                settingPickerRow(
                    title: "主窗口可见时",
                    detail: "保持更快的数据反馈",
                    options: [3.0, 5.0, 10.0, 30.0],
                    selection: $foregroundRefreshInterval,
                    text: { L10n.format("%lld 秒", Int($0)) }
                )
                settingPickerRow(
                    title: "窗口和菜单均收起时",
                    detail: "降低后台查询频率",
                    options: [0.0, 10.0, 30.0, 60.0],
                    selection: $backgroundRefreshInterval,
                    text: { $0 == 0 ? L10n.string("仅按需刷新") : L10n.format("%lld 秒", Int($0)) }
                )
                Text("展开菜单栏面板时会立即刷新。连续多次没有变化时会自动降低查询频率；检测到变化或重新展开窗口后恢复快速刷新。暂停后不会保留后台定时唤醒。")
                    .font(.caption)
                    .foregroundStyle(PVPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(PVPalette.surfaceBento)

            Section("Cloudflare Tunnel") {
                Toggle(L10n.string("检测本机 Cloudflare Tunnel"), isOn: $tunnelEnabled)
                Text(L10n.string("自动读取本机连接器的域名映射，不需要 API Token。"))
                    .font(.caption).foregroundStyle(PVPalette.textSecondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("连接器地址"))
                    TextField(L10n.string("连接器地址"), text: $endpointDraft,
                              prompt: Text(L10n.string("输入本机连接器地址")))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyTunnelEndpoint)
                        .disabled(!tunnelEnabled)
                }
                Button(L10n.string(endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                   ? "恢复默认地址" : "应用地址"), action: applyTunnelEndpoint)
                .disabled(!tunnelEnabled)
                Text(L10n.format("当前已应用：%@", TunnelDefaults.resolvedEndpoint(tunnelEndpoint)))
                    .font(.caption).foregroundStyle(PVPalette.textSecondary)
                if tunnelEnabled {
                    if portViewModel.isCheckingTunnels {
                        Text(L10n.string("正在读取隧道信息…")).font(.caption)
                    } else if portViewModel.tunnelSnapshot.connectors.isEmpty {
                        Text(L10n.string("未发现可确认的本机隧道端点，可手动指定回环地址。"))
                            .font(.caption).foregroundStyle(PVPalette.textSecondary)
                    }
                    if let issue = portViewModel.tunnelIssue {
                        Text(L10n.string(issue)).font(.caption).foregroundStyle(PVPalette.warning)
                    }
                    ForEach(portViewModel.tunnelSnapshot.connectors) { connector in
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(connector.endpoint.absoluteString).font(.caption.monospaced())
                                Text(connector.isStale(at: context.date, maximumAge: 120)
                                     ? L10n.string("数据已过期") : connector.state.title).font(.caption)
                                if connector.identity == nil && (connector.observedAt != nil || connector.routesObservedAt != nil) {
                                    Text(L10n.string("端点可读，进程归属未确认")).font(.caption)
                                }
                                if let issue = connector.issue {
                                    Text(L10n.string(issue)).font(.caption).foregroundStyle(PVPalette.warning)
                                }
                            }
                        }
                    }
                }
            }
            .listRowBackground(PVPalette.surfaceBento)

            Section("隐私与权限") {
                VStack(spacing: 0) {
                    privacyRow(
                        "所有查询均在本机完成，不上传端口或进程信息。",
                        symbol: "hand.raised.fill"
                    )
                    PremiumSeparator()
                    privacyRow(
                        "当前版本不会请求管理员权限。",
                        symbol: "person.badge.key.fill"
                    )
                }
                .padding(.horizontal, 12)
                .premiumControlSurface(radius: PVRadius.control)
            }
            .listRowBackground(PVPalette.surfaceBento)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background { PremiumCanvas() }
        .tint(PVPalette.accentPrimary)
        .frame(width: 520, height: 580)
        .onAppear {
            tunnelEndpoint = TunnelDefaults.resolvedEndpoint(tunnelEndpoint)
            endpointDraft = tunnelEndpoint
            syncTunnels()
        }
        .onChange(of: tunnelEnabled) { _, _ in syncTunnels() }
        .onChange(of: tunnelEndpoint) { _, _ in syncTunnels() }
    }

    private func syncTunnels() {
        portViewModel.configureTunnels(enabled: tunnelEnabled, endpoint: tunnelEndpoint)
    }

    private func applyTunnelEndpoint() {
        tunnelEndpoint = TunnelDefaults.resolvedEndpoint(endpointDraft)
        endpointDraft = tunnelEndpoint
        portViewModel.configureTunnels(enabled: tunnelEnabled, endpoint: tunnelEndpoint, refresh: true)
    }

    private func settingPickerRow(
        title: String,
        detail: String,
        options: [Double],
        selection: Binding<Double>,
        text: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(title))
                    .foregroundStyle(PVPalette.textPrimary)
                Text(L10n.string(detail))
                    .font(.caption)
                    .foregroundStyle(PVPalette.textTertiary)
            }
            Spacer()
            PremiumPicker(
                title,
                options: options,
                selection: selection,
                optionText: text
            )
            .frame(width: 142)
        }
    }

    private func privacyRow(_ text: String, symbol: String) -> some View {
        Label {
            Text(L10n.string(text))
                .font(.callout)
                .foregroundStyle(PVPalette.textSecondary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(PVPalette.accentPrimary)
                .frame(width: 20)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }
}
