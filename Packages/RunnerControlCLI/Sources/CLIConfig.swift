import Foundation
import RunnerControlCore

/// Shared constants and host-bundle resolution for the CLI.
///
/// The CLI deliberately shares every persistence location with the GUI app:
/// the same Keychain service/account (see `GitHubKeychainStore`), the same
/// catalog file, and the app's own defaults domain below. Logging in either
/// surface signs in both; no migration or export step exists.
public enum CLIConfig {
    /// GUI app bundle identifier. Used as the shared defaults suite name so
    /// the CLI reads the exact plist the app maintains via `.standard`.
    public static let appBundleID = "works.relux.runnercontrol"

    /// The app's defaults domain. Writable without entitlements: both
    /// processes run unsandboxed as the same user.
    public static var appDefaults: UserDefaults {
        // swiftlint:disable:next force_unwrapping
        UserDefaults(suiteName: appBundleID)!
    }

    /// Session-identity store bound to the shared domain. Same key the GUI
    /// uses; only the defaults instance differs (a bare tool has no bundle
    /// domain of its own).
    public static func sessionIdentityStore() -> UserDefaultsGitHubSessionIdentityStore {
        UserDefaultsGitHubSessionIdentityStore(defaults: appDefaults)
    }

    /// Public GitHub App client_id fallback. Must equal
    /// `macos.info_plist.GitHubAppClientID` in ios-app-manager.json (checked
    /// by Scripts/tests/test_cli_parity.py). Public by design: the same value
    /// ships in the app's Info.plist and in git history.
    public static let embeddedClientID = "Iv23ligBUam7vZitsE1G"

    /// Resolves the client_id from the shipped app bundle sitting above this
    /// binary (`RunnerControl.app/Contents/Info.plist`), so an installed CLI
    /// can never drift from the app it shipped with. Standalone copies
    /// (outside an app bundle) use the embedded public value. The default
    /// executable comes from the process image, never argv[0] (bare via
    /// PATH); the parameter exists so tests can inject layouts.
    public static func clientID(executablePath: String = CLIInstallerService.currentExecutableURL().path) -> String {
        if let fromBundle = infoValue("GitHubAppClientID", executablePath: executablePath),
           !fromBundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fromBundle
        }
        return embeddedClientID
    }

    /// `GitHubAppSlug` from the same bundle plist, for grant-access URLs.
    public static func appSlug(executablePath: String = CLIInstallerService.currentExecutableURL().path) -> String {
        infoValue("GitHubAppSlug", executablePath: executablePath) ?? "relux-runner-control"
    }

    /// Marketing version of the shipped app, for `app version`.
    public static func appVersion(executablePath: String = CLIInstallerService.currentExecutableURL().path) -> (short: String, build: String)? {
        guard let short = infoValue("CFBundleShortVersionString", executablePath: executablePath) else { return nil }
        return (short, infoValue("CFBundleVersion", executablePath: executablePath) ?? "?")
    }

    /// Locates the host app bundle above the CLI binary: the resolved
    /// executable path must spell `*.app/Contents/...`.
    public static func hostAppURL(executablePath: String = CLIInstallerService.currentExecutableURL().path) -> URL? {
        let resolved = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        var cursor = resolved.deletingLastPathComponent()
        for _ in 0 ..< 4 {
            if cursor.pathExtension == "app" { return cursor }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return nil }
            cursor = parent
        }
        return nil
    }

    private static func infoValue(_ key: String, executablePath: String) -> String? {
        guard let app = hostAppURL(executablePath: executablePath),
              let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let raw = plist[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Config provider injected into every flow: same client_id the GUI uses,
    /// without requiring a host bundle Info.plist on `Bundle.main`.
    public static func configProvider(executablePath: String = CLIInstallerService.currentExecutableURL().path) -> @Sendable (String?) throws -> GitHubAuth.AppConfig {
        let clientID = clientID(executablePath: executablePath)
        return { host in GitHubAuth.AppConfig(clientID: clientID, serverHost: host ?? "github.com") }
    }
}
