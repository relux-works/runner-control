import Foundation

extension RunnerRegistration {
    /// Pure wizard-input builder. Maps raw MainActor-owned UI field text to
    /// the exact `Draft` the wizard sends on Begin (and on later edits).
    ///
    /// The container calls this with values captured on the MainActor and
    /// passes the resulting `Sendable` snapshot across the Relux dispatcher
    /// boundary: the `action { }` factory runs off-main and must never read
    /// UI state. Every helper here is a pure function of its arguments, so it
    /// is safely callable from any actor; the snapshot tests pin the mapping.
    public enum DraftSnapshot {
        /// Splits a comma-separated labels field, trims each entry, and drops
        /// empties. `"a, ,b"` yields `["a", "b"]`.
        public static func parseLabels(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        /// Builds the exact `Draft` for raw wizard field values. Trims every
        /// text field and maps the scope selector; flags and the repository
        /// selection pass through unchanged.
        public static func make(
            organizationScope: Bool,
            org: String,
            repoOwner: String,
            repoName: String,
            runnerName: String,
            labelsText: String,
            installDirName: String,
            workFolder: String,
            groupName: String,
            selectedRepositoryIDs: Set<Int64>,
            allowGroupMutation: Bool,
            allowGroupTakeover: Bool,
            allowReplace: Bool
        ) -> Draft {
            let scope: Scope
            if organizationScope {
                scope = .organization(org: org.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                scope = .repository(
                    owner: repoOwner.trimmingCharacters(in: .whitespacesAndNewlines),
                    name: repoName.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return Draft(
                scope: scope,
                runnerName: runnerName.trimmingCharacters(in: .whitespacesAndNewlines),
                labels: parseLabels(labelsText),
                installDirName: installDirName.trimmingCharacters(in: .whitespacesAndNewlines),
                workFolder: workFolder.trimmingCharacters(in: .whitespacesAndNewlines),
                groupName: groupName.trimmingCharacters(in: .whitespacesAndNewlines),
                selectedRepositoryIDs: selectedRepositoryIDs,
                allowGroupMutation: allowGroupMutation,
                allowGroupTakeover: allowGroupTakeover,
                allowReplace: allowReplace
            )
        }
    }

    /// Click-time capture boundary for Begin. The new-runner sheet crashed
    /// because the Relux `action { }` factory runs off-main while
    /// MainActor-owned form state was read inside it (dispatch
    /// actor-isolation trap, Begin 2026-09-16). This factory closes that
    /// boundary in production code: it invokes the MainActor form getter
    /// synchronously at click time, stores the immutable `Sendable` draft,
    /// and returns a `Sendable` action factory holding only that value.
    /// The getter is non-escaping, so delaying any field read across the
    /// dispatcher boundary does not compile.
    public enum BeginDraftCapture {
        @MainActor
        public static func makeBeginDraftAction(
            readDraft: @MainActor () -> Draft
        ) -> @Sendable () -> Effect {
            let draft = readDraft()
            return { .beginDraft(draft) }
        }
    }
}
