import Foundation

/// Launch-at-login bridge between the CLI and the GUI app's SMAppService
/// registration. A bare CLI tool cannot use SMAppService.mainApp (it
/// reports `.notFound`: no containing app bundle), and driving the legacy
/// System Events login-items list instead would create a SECOND, divergent
/// registration plus a TCC Automation prompt. So both surfaces share one
/// persisted setting through the app defaults domain:
///
/// - The CLI writes `desired`, wakes the app (distributed notification
///   when running, hidden `open` otherwise), and polls `applied`.
/// - The GUI applies `desired` via its own SMAppService.mainApp at launch
///   and on notification, clears the request, and mirrors the actual
///   SMAppService state to `applied` on every change — so CLI status reads
///   the same setting the GUI toggle shows.
/// - Changes made outside both surfaces (toggled in System Settings)
///   surface on the next GUI refresh/launch; CLI status is last-known and
///   says so via `appliedAt`.
public enum LoginItemBridge {
    /// Outstanding CLI request (nil = none). Cleared by the GUI on apply.
    public static let desiredKey = "cli.loginItem.desired"
    /// Last SMAppService state the GUI confirmed (nil = never confirmed).
    public static let appliedKey = "cli.loginItem.applied"
    /// When `applied` was mirrored (nil when never).
    public static let appliedAtKey = "cli.loginItem.appliedAt"
    /// Posted by the CLI; observed by a running GUI to apply now.
    public static let applyNotification = Notification.Name("works.relux.runnercontrol.applyLoginItem")

    public struct Status: Sendable, Equatable {
        public var applied: Bool?
        public var desired: Bool?
        public var appliedAt: Date?
        public var pending: Bool { desired != nil && desired != applied }
    }

    /// Effective display state for CLI status.
    public enum EffectiveState: Sendable, Equatable {
        case on(appliedAt: Date?)
        case off(appliedAt: Date?)
        /// Requested via CLI; the GUI has not applied it yet (not running,
        /// or the change is in flight).
        case pending(desired: Bool)
        /// Never set from either surface; open the GUI once to establish it.
        case unknown
    }

    public static func read(defaults: UserDefaults) -> Status {
        Status(
            applied: defaults.object(forKey: appliedKey) == nil ? nil : defaults.bool(forKey: appliedKey),
            desired: defaults.object(forKey: desiredKey) == nil ? nil : defaults.bool(forKey: desiredKey),
            appliedAt: defaults.object(forKey: appliedAtKey) as? Date
        )
    }

    public static func effective(_ status: Status) -> EffectiveState {
        if let desired = status.desired, desired != status.applied {
            return .pending(desired: desired)
        }
        if let applied = status.applied {
            return applied ? .on(appliedAt: status.appliedAt) : .off(appliedAt: status.appliedAt)
        }
        return .unknown
    }

    public static func request(_ enabled: Bool, defaults: UserDefaults) {
        defaults.set(enabled, forKey: desiredKey)
    }

    public static func clearRequest(defaults: UserDefaults) {
        defaults.removeObject(forKey: desiredKey)
    }

    public static func mirror(applied: Bool, defaults: UserDefaults) {
        defaults.set(applied, forKey: appliedKey)
        defaults.set(Date(), forKey: appliedAtKey)
    }
}
