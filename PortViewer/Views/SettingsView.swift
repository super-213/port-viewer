import SwiftUI

struct SettingsView: View {
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

            Section("自动刷新") {
                settingPickerRow(
                    title: "主窗口可见时",
                    detail: "保持更快的数据反馈",
                    options: [3.0, 5.0, 10.0, 30.0],
                    selection: $foregroundRefreshInterval,
                    text: { "\(Int($0)) 秒" }
                )
                settingPickerRow(
                    title: "窗口和菜单均收起时",
                    detail: "降低后台查询频率",
                    options: [0.0, 10.0, 30.0, 60.0],
                    selection: $backgroundRefreshInterval,
                    text: { $0 == 0 ? "仅按需刷新" : "\(Int($0)) 秒" }
                )
                Text("展开菜单栏面板时会立即刷新。连续多次没有变化时会自动降低查询频率；检测到变化或重新展开窗口后恢复快速刷新。暂停后不会保留后台定时唤醒。")
                    .font(.caption)
                    .foregroundStyle(PVPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background { PremiumCanvas() }
        .frame(width: 480, height: 380)
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
                Text(title)
                    .foregroundStyle(PVPalette.textPrimary)
                Text(detail)
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
            Text(text)
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
