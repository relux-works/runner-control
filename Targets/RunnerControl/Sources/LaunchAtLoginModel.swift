import SwiftUI
import ServiceManagement
import RunnerControlCore

/// Launch-at-login adapter (app to open at login, distinct from CI autostart).
@MainActor final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var enabled: Bool = false
    init() {
        enabled = SMAppService.mainApp.status == .enabled
        Self.mirrorActual()
    }
    func setEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            enabled = value
        } catch {
            enabled = SMAppService.mainApp.status == .enabled
        }
        // A GUI toggle supersedes any outstanding CLI request.
        LoginItemBridge.clearRequest(defaults: .standard)
        Self.mirrorActual()
    }
    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
        Self.mirrorActual()
    }

    /// Applies a CLI-requested state (if any) via this app's own
    /// SMAppService registration, then mirrors the actual state for CLI
    /// status. Called at launch and on distributed notification while
    /// running. A bare CLI tool cannot touch SMAppService.mainApp itself
    /// (`.notFound`: no containing bundle), so the app is the only writer.
    static func applyDesiredIfNeeded(defaults: UserDefaults = .standard) {
        if let desired = LoginItemBridge.read(defaults: defaults).desired {
            do {
                if desired { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                // Leave the request for the next attempt; mirror actual.
                mirrorActual(defaults: defaults)
                return
            }
            LoginItemBridge.clearRequest(defaults: defaults)
        }
        mirrorActual(defaults: defaults)
    }

    /// Mirrors the live SMAppService state so CLI status reads the same
    /// setting this toggle shows (last-known for external changes).
    static func mirrorActual(defaults: UserDefaults = .standard) {
        LoginItemBridge.mirror(applied: SMAppService.mainApp.status == .enabled, defaults: defaults)
    }
}
