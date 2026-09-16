import SwiftUI
import ServiceManagement
import RunnerControlCore

/// Launch-at-login adapter (app to open at login, distinct from CI autostart).
@MainActor final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var enabled: Bool = false
    init() {
        enabled = SMAppService.mainApp.status == .enabled
    }
    func setEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            enabled = value
        } catch {
            enabled = SMAppService.mainApp.status == .enabled
        }
    }
    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
    }
}
