import AppKit
import SwiftUI

extension Notification.Name {
    static let focusPortSearch = Notification.Name("PortViewer.focusPortSearch")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct PortViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = PortStore()

    var body: some Scene {
        WindowGroup("Port Viewer", id: "main") {
            MainWindowView(store: store)
                .task { store.start() }
        }
        .defaultSize(width: 1_140, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            PortViewerCommands(store: store)
        }

        MenuBarExtra {
            MenuBarPanel(store: store)
                .task { store.start() }
        } label: {
            StatusItemLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

struct PortViewerCommands: Commands {
    @ObservedObject var store: PortStore

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("查找端口或进程…") {
                NotificationCenter.default.post(name: .focusPortSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button("立即刷新") {
                store.refreshNow()
            }
            .keyboardShortcut("r", modifiers: .command)

            Button(store.isPaused ? "继续自动刷新" : "暂停自动刷新") {
                store.togglePause()
            }
        }
    }
}
