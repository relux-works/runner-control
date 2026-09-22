import SwiftUI
import RunnerControlCore

@main
struct RunnerControl: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppRegistry.state
    private var hasError: Bool {
        state.runners.contains { [.failed, .missing, .needsSetup, .unknown].contains($0.status) }
    }
    var body: some Scene {
        MenuBarExtra {
            RunnerContainer(state: state)
        } label: {
            Image(systemName: hasError ? "exclamationmark.circle.fill" : (state.activeCount > 0 ? "bolt.circle.fill" : "bolt.circle"))
                .accessibilityLabel("Runner Control: \(state.activeCount) служб включено из \(state.runners.count)\(hasError ? ", есть ошибки" : "")")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var loginItemObserver: (any NSObjectProtocol)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppRegistry.start()
        // Honor a CLI-requested launch-at-login state (if any) and mirror
        // the actual registration for CLI status; keep applying while
        // running when the CLI asks.
        LaunchAtLoginModel.applyDesiredIfNeeded()
        loginItemObserver = DistributedNotificationCenter.default().addObserver(
            forName: LoginItemBridge.applyNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in LaunchAtLoginModel.applyDesiredIfNeeded() }
        }
        NotificationCenter.default.addObserver(
            forName: .openManagementWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showControls() }
        }
        if !UserDefaults.standard.bool(forKey: "hasShownWelcome") {
            showControls()
            UserDefaults.standard.set(true, forKey: "hasShownWelcome")
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return true
    }
    private func showControls() {
        if window == nil {
            let controller = NSHostingController(rootView: ManagementWindowContainer(
                runners: AppRegistry.state,
                github: AppRegistry.githubState,
                registration: AppRegistry.registrationState
            ))
            let value = NSWindow(contentViewController: controller)
            value.title = "Раннеры и настройки"
            value.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            value.isReleasedWhenClosed = false
            value.setContentSize(NSSize(width: 760, height: 540))
            value.minSize = NSSize(width: 700, height: 480)
            value.center()
            window = value
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
