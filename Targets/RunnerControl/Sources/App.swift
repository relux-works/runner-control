import SwiftUI
import RunnerControlCore

@main
struct RunnerControl: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppRegistry.state
    var body: some Scene {
        MenuBarExtra {
            RunnerContainer(state: state)
        } label: {
            Image(systemName: state.activeCount > 0 ? "bolt.circle.fill" : "bolt.circle")
                .accessibilityLabel("Runner Control: \(state.activeCount) включено")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppRegistry.start()
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
            let controller = NSHostingController(rootView: RunnerContainer(state: AppRegistry.state))
            let value = NSWindow(contentViewController: controller)
            value.title = "Runner Control"
            value.styleMask = [.titled, .closable]
            value.isReleasedWhenClosed = false
            value.center()
            window = value
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
