import Foundation
import RunnerControlCore

/// Resolves a user-supplied runner reference to a snapshot. Accepts, in
/// order: service label (the GUI row id), catalog localID, agent name,
/// display title. Ambiguous names fail with the candidate list instead of
/// guessing — control commands must never hit the wrong runner.
public enum RunnerMatching {
    public static func resolve(_ reference: String, in snapshots: [Runners.Snapshot]) throws -> Runners.Snapshot {
        if let exact = snapshots.first(where: { $0.id == reference }) {
            return exact
        }
        if let byLocalID = snapshots.first(where: { $0.definition.localID == reference }) {
            return byLocalID
        }
        let folded = reference.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        // `title` is the registration (agent) name; `displayTitle` honors the
        // user's alias override. No other name field exists on Definition.
        let named = snapshots.filter {
            $0.definition.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == folded
                || $0.definition.displayTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == folded
        }
        if named.count == 1, let single = named.first {
            return single
        }
        if named.count > 1 {
            let ids = named.map(\.id).sorted().joined(separator: ", ")
            throw CLIFailure(.failed, "“\(reference)” matches several runners: \(ids). Use the service label.")
        }
        let known = snapshots.map(\.id).sorted().joined(separator: ", ")
        throw CLIFailure(.failed, "Unknown runner “\(reference)”. Known: \(known.isEmpty ? "(none)" : known).")
    }

    /// Resolves several references, failing on the first unknown one.
    public static func resolveMany(_ references: [String], in snapshots: [Runners.Snapshot]) throws -> [Runners.Snapshot] {
        try references.map { try resolve($0, in: snapshots) }
    }
}
