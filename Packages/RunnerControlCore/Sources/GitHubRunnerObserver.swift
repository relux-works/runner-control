import Foundation

/// Maps local catalog registrations to GitHub API runners by
/// server + scope + remote ID, never by name. On ambiguity no runner is
/// attached. Observations older than 60s are explicitly stale; a stale
/// `busy=false` is never proof of an idle runner.
public enum GitHubRunnerObserver {
    public static let staleAfter: TimeInterval = 60

    /// Matches one local definition against a complete remote list.
    /// Returns nil when the agent is absent or the list contradicts the
    /// local identity (same-name foreign runner or renamed agent): the
    /// caller reports unknown/stale instead of attaching a random runner.
    public static func match(
        definition: Runners.Definition,
        runners: [RunnerRegistration.RegisteredRunner],
        now: Date = Date()
    ) -> Runners.RemoteObservation? {
        guard let agentID = definition.remoteAgentID else { return nil }
        guard let exact = runners.first(where: { $0.id == agentID }) else {
            // Absent: do not fall back to a same-name foreign runner.
            return Runners.RemoteObservation(
                online: nil, busy: nil, busyKnown: false,
                updatedAt: now, stale: false,
                syncError: "Runner not listed"
            )
        }
        guard exact.name == definition.title else {
            // Contradiction: same ID renamed, or ID reused. Fail closed.
            return nil
        }
        let online: Bool? = {
            guard let status = exact.status?.lowercased() else { return nil }
            if status == "online" { return true }
            if status == "offline" { return false }
            return nil
        }()
        let busyKnown = exact.busy != nil && online != nil
        return Runners.RemoteObservation(
            online: online, busy: exact.busy, busyKnown: busyKnown,
            labels: exact.labels, updatedAt: now, stale: false
        )
    }

    /// True when an observation is too old to trust. Stale busy=false is
    /// not idle proof; stop confirmation must warn.
    public static func isStale(_ observation: Runners.RemoteObservation?, now: Date = Date()) -> Bool {
        guard let observation, let updated = observation.updatedAt else { return true }
        if observation.stale { return true }
        return now.timeIntervalSince(updated) > staleAfter
    }

    /// Marks an observation stale when it exceeds the freshness bound.
    public static func withFreshness(_ observation: Runners.RemoteObservation, now: Date = Date()) -> Runners.RemoteObservation {
        var next = observation
        if let updated = observation.updatedAt, now.timeIntervalSince(updated) > staleAfter {
            next.stale = true
            next.busyKnown = false
        } else if observation.updatedAt == nil {
            next.stale = true
            next.busyKnown = false
        }
        return next
    }
}
