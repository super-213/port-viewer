import SwiftUI

struct SettingsView: View {
    @AppStorage("menuBarShowsCount") private var menuBarShowsCount = true
    @AppStorage("foregroundRefreshInterval") private var foregroundRefreshInterval = 3.0
    @AppStorage("backgroundRefreshInterval") private var backgroundRefreshInterval = 30.0

    var body: some View {
        Form {
            Section("菜单栏") {
                Toggle("在图标旁显示等待连接数量", isOn: $menuBarShowsCount)
            }

            Section("自动刷新") {
                Picker("主窗口可见时", selection: $foregroundRefreshInterval) {
                    Text("3 秒").tag(3.0)
                    Text("5 秒").tag(5.0)
                    Text("10 秒").tag(10.0)
                    Text("30 秒").tag(30.0)
                }
                Picker("窗口和菜单均收起时", selection: $backgroundRefreshInterval) {
                    Text("仅按需刷新").tag(0.0)
                    Text("10 秒").tag(10.0)
                    Text("30 秒").tag(30.0)
                    Text("60 秒").tag(60.0)
                }
                Text("展开菜单栏面板时会立即刷新，并临时使用 5 秒间隔。暂停后不会保留后台定时唤醒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("隐私与权限") {
                Label("所有查询均在本机完成，不上传端口或进程信息。", systemImage: "hand.raised")
                    .foregroundStyle(.secondary)
                Label("当前版本不会请求管理员权限。", systemImage: "person.badge.key")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 380)
    }

}
