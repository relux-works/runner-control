import AppKit
import Foundation
import RunnerControlCore

@MainActor enum AppRegistry {
    static let state = Runners.State()
    static let githubState = GitHubAuth.State()
    static let registrationState = RunnerRegistration.State()
    static let updater = AppUpdater()
    private static var task: Task<Void, Never>?
    private static var githubTask: Task<Void, Never>?
    static func start() {
        guard task == nil else { return }
        updater.start()
        // One composition root for every MenuBarExtra presentation.
        task = Task {
            _ = await RunnerRuntime.make(state: state, githubState: githubState, registrationState: registrationState)
            await action { GitHubAuth.Effect.restoreSession }
            // Migrate existing installs once (read-only, preserves policies),
            // then list candidates for the management window.
            await action { Runners.Effect.loadCatalog }
            await action { Runners.Effect.discover }
            // Local observation every 3s; GitHub best-effort every 30s.
            // Immediate refresh after wake; commands refresh on completion.
            let center = NSWorkspace.shared.notificationCenter
            let observer = center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { _ in
                Task { await action { Runners.Effect.refresh } }
            }
            defer { center.removeObserver(observer) }
            while !Task.isCancelled {
                await action { Runners.Effect.refresh }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        githubTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                // GitHub sync is best-effort and never blocks local control.
                if case .connected = githubState.connection {
                    await action { GitHubAuth.Effect.refreshInstallations }
                    await action { Runners.Effect.refreshRemote }
                }
            }
        }
    }

    static func openManagementWindow() {
        NotificationCenter.default.post(name: .openManagementWindow, object: nil)
    }
}

extension Notification.Name {
    static let openManagementWindow = Notification.Name("works.relux.runnercontrol.openManagementWindow")
}
