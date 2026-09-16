import AppKit
import Combine
import Sparkle

/// AppKit-bound adapter: one Sparkle controller for the application's lifetime.
@MainActor final class AppUpdater: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var automaticallyDownloads = true
    private var controller: SPUStandardUpdaterController!
    private var started = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
    }
    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
    }
    func check() { controller.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled }
}
