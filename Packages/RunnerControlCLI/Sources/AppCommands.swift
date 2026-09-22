import AppKit
import ArgumentParser
import Foundation
import RunnerControlCore

public struct AppCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Runner Control app itself: version, updates, login item, CLI install.",
        subcommands: [
            AppVersion.self, AppCheckUpdates.self, AppLaunchAtLogin.self,
            AppAutoCheck.self, AppAutoUpdate.self, AppInstallCLI.self, AppUninstallCLI.self,
        ]
    )
    public init() {}
}

public struct AppVersion: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "version", abstract: "Show app and CLI versions.")
    @OptionGroup public var globals: GlobalOptions
    public init() {}

    public func run() throws {
        let exe = CLIInstallerService.currentExecutableURL()
        let app = CLIConfig.hostAppURL().map(\.path)
        let version = CLIConfig.appVersion()
        let payload: [String: String] = [
            "app": version.map { "\($0.short) (\($0.build))" } ?? "unknown (standalone CLI copy)",
            "cli": exe.path,
            "bundle": app ?? "—",
        ]
        if globals.json {
            Output.json(payload)
        } else {
            Output.text(Output.table(rows: payload.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }))
        }
    }
}

public struct AppCheckUpdates: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "check-updates",
        abstract: "Compare the installed app against the Sparkle feed (read-only; installing stays with the GUI/Sparkle)."
    )
    @OptionGroup public var globals: GlobalOptions
    public init() {}

    public func run() async throws {
        let feed = AppSettings.feedURL()
        let (data, _) = try await URLSession.shared.data(from: feed)
        guard let latest = AppSettings.parseShortVersion(from: data) else {
            throw CLIFailure(.failed, "Could not parse the appcast at \(feed.absoluteString).")
        }
        let current = CLIConfig.appVersion()?.short ?? AppSettings.installedAppVersion()?.short
        let available = current.map { AppSettings.isNewer(latest, than: $0) } ?? true
        if globals.json {
            Output.json(UpdateCheckDTO(current: current ?? "unknown", latest: latest, updateAvailable: available, feed: feed.absoluteString))
        } else if available {
            Output.text("Update available: \(current ?? "?") → \(latest). Install it from the GUI app.")
        } else {
            Output.text("Up to date (\(current ?? "?")).")
        }
    }
}

public struct AppLaunchAtLogin: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "launch-at-login",
        abstract: "The GUI toggle's launch-at-login setting, applied by the app itself (same registration, no prompts)."
    )
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "on, off, or status.")
    public var state: String
    public init() {}

    public func run() async throws {
        let defaults = CLIConfig.appDefaults
        switch state.lowercased() {
        case "status":
            emit(LoginItemBridge.read(defaults: defaults))
        case "on":
            try await apply(enabled: true, defaults: defaults)
        case "off":
            try await apply(enabled: false, defaults: defaults)
        default:
            throw CLIFailure(.usage, "State must be on, off, or status.")
        }
    }

    /// Records the request, wakes the app to apply it through its own
    /// SMAppService registration, and waits for confirmation. When the app
    /// cannot be reached the request stays recorded and applies on the next
    /// app launch; the payload says pending explicitly instead of claiming
    /// success.
    private func apply(enabled: Bool, defaults: UserDefaults) async throws {
        LoginItemBridge.request(enabled, defaults: defaults)
        if AppSettings.isAppRunning() {
            DistributedNotificationCenter.default().post(name: LoginItemBridge.applyNotification, object: nil)
        } else if let appURL = AppSettings.appURL() {
            try AppSettings.launchHidden(appURL: appURL)
        } else {
            Output.warn("RunnerControl.app is not running and was not found: the request is recorded and applies on the next app launch.")
        }
        emit(await AppSettings.waitForApplied(defaults: defaults, desired: enabled, timeout: 15))
    }

    private func emit(_ status: LoginItemBridge.Status) {
        if globals.json {
            Output.json(LoginItemDTO(status: status))
            return
        }
        switch LoginItemBridge.effective(status) {
        case .on:
            Output.text(status.pending ? "Login item: on (change pending)." : "Login item: on.")
        case .off:
            Output.text(status.pending ? "Login item: off (change pending)." : "Login item: off.")
        case .pending(let desired):
            Output.text("Login item: change to \(desired ? "on" : "off") pending — the app applies it on launch.")
        case .unknown:
            Output.text("Login item: unknown — open the GUI app once to establish it.")
        }
    }
}

public struct AppAutoCheck: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "auto-check",
        abstract: "Sparkle automatic update checks (same key the GUI toggle writes)."
    )
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "on, off, or status.")
    public var state: String
    public init() {}

    public func run() throws {
        try AppSettings.runToggle(
            state: state, key: "SUEnableAutomaticChecks", label: "Automatic checks", json: globals.json
        )
    }
}

public struct AppAutoUpdate: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "auto-update",
        abstract: "Sparkle automatic update installs (same key the GUI toggle writes)."
    )
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "on, off, or status.")
    public var state: String
    public init() {}

    public func run() throws {
        try AppSettings.runToggle(
            state: state, key: "SUAutomaticallyUpdate", label: "Automatic installs", json: globals.json
        )
    }
}

public struct AppInstallCLI: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "install-cli",
        abstract: "Symlink this binary into PATH (self-install; same entry the GUI button creates)."
    )
    @OptionGroup public var globals: GlobalOptions
    @Option(name: .long, help: "Link path (default /usr/local/bin/runner-control).")
    public var location: String?
    public init() {}

    public func run() throws {
        let target = CLIInstallerService.currentExecutableURL()
        let link = location ?? CLIInstallerService.primaryLinkPath
        do {
            try CLIInstallerService.install(target: target, linkPath: link)
        } catch let error as CLIInstallerService.InstallError {
            switch error {
            case .needsAdmin:
                throw CLIFailure(
                    .failed,
                    "Cannot write \(link) without administrator rights. Re-run with sudo, or use --location \(CLIInstallerService.fallbackLinkURL.path) (add ~/.local/bin to PATH)."
                )
            default:
                throw CLIFailure(.failed, error.localizedDescription)
            }
        }
        if globals.json {
            Output.json(["link": link, "target": target.path])
        } else {
            Output.text("Installed \(link) → \(target.path)")
        }
    }
}

public struct AppUninstallCLI: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "uninstall-cli",
        abstract: "Remove a PATH symlink, but only when it points at this binary."
    )
    @OptionGroup public var globals: GlobalOptions
    @Option(name: .long, help: "Link path (default /usr/local/bin/runner-control).")
    public var location: String?
    public init() {}

    public func run() throws {
        let target = CLIInstallerService.currentExecutableURL()
        let link = location ?? CLIInstallerService.primaryLinkPath
        do {
            try CLIInstallerService.uninstall(target: target, linkPath: link)
        } catch let error as CLIInstallerService.InstallError {
            switch error {
            case .needsAdmin:
                throw CLIFailure(.failed, "Cannot remove \(link) without administrator rights. Re-run with sudo.")
            default:
                throw CLIFailure(.failed, error.localizedDescription)
            }
        }
        if globals.json {
            Output.json(["removed": link])
        } else {
            Output.text("Removed \(link).")
        }
    }
}

/// App-domain settings shared with the GUI via the suite defaults and
/// standard macOS mechanisms. No tokens or secrets pass through here.
public enum AppSettings {
    public static let defaultFeedURL = URL(string: "https://github.com/relux-works/runner-control/releases/latest/download/appcast.xml")!

    public static func feedURL() -> URL {
        if let app = CLIConfig.hostAppURL(),
           let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
           let raw = plist["SUFeedURL"] as? String,
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url
        }
        return defaultFeedURL
    }

    /// Minimal appcast parse: first `sparkle:shortVersionString`. The feed
    /// is generated by `generate_appcast`; a regex keeps the CLI free of an
    /// XML dependency for one field.
    public static func parseShortVersion(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let pattern = "<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Numeric dot-separated version compare.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    public static func appURL() -> URL? {
        if let host = CLIConfig.hostAppURL() { return host }
        if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CLIConfig.appBundleID) { return found }
        for base in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let candidate = URL(fileURLWithPath: base).appendingPathComponent("RunnerControl.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public static func installedAppVersion() -> (short: String, build: String)? {
        guard let app = appURL(),
              let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let short = plist["CFBundleShortVersionString"] as? String else { return nil }
        return (short, (plist["CFBundleVersion"] as? String) ?? "?")
    }

    public static func runToggle(state: String, key: String, label: String, json: Bool) throws {
        let defaults = CLIConfig.appDefaults
        switch state.lowercased() {
        case "status":
            emitToggle(label: label, enabled: effectiveBool(defaults: defaults, key: key), json: json)
        case "on":
            defaults.set(true, forKey: key)
            emitToggle(label: label, enabled: true, json: json)
        case "off":
            defaults.set(false, forKey: key)
            emitToggle(label: label, enabled: false, json: json)
        default:
            throw CLIFailure(.usage, "State must be on, off, or status.")
        }
    }

    private static func emitToggle(label: String, enabled: Bool, json: Bool) {
        if json {
            Output.json(["enabled": enabled])
        } else {
            Output.text("\(label): \(enabled ? "on" : "off").")
        }
    }

    /// Stored value wins; otherwise the shipped Info.plist default; Sparkle
    /// itself defaults checks to on when nothing is set anywhere.
    static func effectiveBool(defaults: UserDefaults, key: String) -> Bool {
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        if let app = CLIConfig.hostAppURL(),
           let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
           let stored = plist[key] as? Bool {
            return stored
        }
        return key == "SUEnableAutomaticChecks"
    }

    // MARK: - Login item (applied by the app itself, never here)

    public static func isAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == CLIConfig.appBundleID }
    }

    /// Launches the app hidden in the background so it can apply a
    /// requested login-item state at startup. No activation, no prompt.
    public static func launchHidden(appURL: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-gj", appURL.path]
        do {
            try task.run()
        } catch {
            throw CLIFailure(.failed, "Could not launch \(appURL.path): \(error.localizedDescription)")
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw CLIFailure(.failed, "Could not launch \(appURL.path) (open exited \(task.terminationStatus)).")
        }
    }

    /// Polls the applied mirror until the GUI confirms `desired` or the
    /// timeout expires. Reads re-resolve through cfprefsd each pass, so a
    /// write from the app process shows up here.
    public static func waitForApplied(defaults: UserDefaults, desired: Bool, timeout: TimeInterval) async -> LoginItemBridge.Status {
        let deadline = Date().addingTimeInterval(timeout)
        var status = LoginItemBridge.read(defaults: defaults)
        while Date() < deadline {
            if !status.pending, status.applied != nil {
                return status
            }
            try? await Task.sleep(for: .milliseconds(250))
            status = LoginItemBridge.read(defaults: defaults)
        }
        return status
    }
}
