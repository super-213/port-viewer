import AppKit
import SwiftUI

extension Notification.Name {
    static let focusPortSearch = Notification.Name("PortViewer.focusPortSearch")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationHandler?()
    }
}

@main
@MainActor
struct PortViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var portViewModel: PortViewModel
    @State private var mainWindowViewModel: MainWindowViewModel
    @State private var menuBarViewModel: MenuBarViewModel

    init() {
        let portViewModel = PortViewModel(
            queryService: LsofService(),
            processService: ProcessService()
        )
        _portViewModel = State(initialValue: portViewModel)
        _mainWindowViewModel = State(
            initialValue: MainWindowViewModel(portViewModel: portViewModel)
        )
        _menuBarViewModel = State(
            initialValue: MenuBarViewModel(portViewModel: portViewModel)
        )
    }

    var body: some Scene {
        WindowGroup("Port Viewer", id: "main") {
            MainWindowView(
                portViewModel: portViewModel,
                viewModel: mainWindowViewModel
            )
            .task {
                appDelegate.terminationHandler = portViewModel.stop
                portViewModel.start()
            }
        }
        .defaultSize(width: 1_180, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            PortViewerCommands(portViewModel: portViewModel)
        }

        MenuBarExtra {
            MenuBarPanel(
                portViewModel: portViewModel,
                viewModel: menuBarViewModel,
                mainWindowViewModel: mainWindowViewModel
            )
            .task {
                appDelegate.terminationHandler = portViewModel.stop
                portViewModel.start()
            }
        } label: {
            StatusItemLabel(portViewModel: portViewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

struct PortViewerCommands: Commands {
    let portViewModel: PortViewModel

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("查找应用或端口…") {
                NotificationCenter.default.post(name: .focusPortSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button("立即刷新") {
                portViewModel.refreshNow()
            }
            .keyboardShortcut("r", modifiers: .command)

            Button(portViewModel.isPaused ? "继续自动刷新" : "暂停自动刷新") {
                portViewModel.togglePause()
            }
        }
    }
}
