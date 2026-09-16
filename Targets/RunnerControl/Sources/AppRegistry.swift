import Foundation
import RunnerControlCore

@MainActor enum AppRegistry {
    static let state = Runners.State()
    static let updater = AppUpdater()
    private static var task: Task<Void, Never>?
    static func start() {
        guard task == nil else { return }
        updater.start()
        // One composition root for every MenuBarExtra presentation.
        task = Task {
            _ = await RunnerRuntime.make(state: state)
            while !Task.isCancelled {
                await action { Runners.Effect.refresh }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
