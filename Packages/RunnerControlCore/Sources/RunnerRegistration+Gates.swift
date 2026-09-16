import Foundation

extension RunnerRegistration {
    /// Validation gates. Each gate refuses a concrete invalid class; negative
    /// tests narrow every one of them.
    public enum Gates {
        /// Refuses install/work paths containing spaces. GitHub's own setup has
        /// a known defect with spaced paths; the wizard never reproduces it.
        public static func validateNoSpace(installDirName: String, workFolder: String) throws {
            if installDirName.contains(" ") {
                throw RegistrationError.noSpacePath("Installation folder name must not contain spaces.")
            }
            if installDirName.contains("/") || installDirName.isEmpty {
                throw RegistrationError.invalidDraft("Installation folder name is invalid.")
            }
            if workFolder.contains(" ") {
                throw RegistrationError.noSpacePath("Work folder must not contain spaces.")
            }
            if workFolder.isEmpty || workFolder.contains("/") {
                throw RegistrationError.invalidDraft("Work folder name is invalid.")
            }
        }

        /// Validates the full draft before any network or filesystem mutation.
        public static func validateDraft(_ draft: Draft) throws {
            let name = draft.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw RegistrationError.invalidDraft("Runner name must not be empty.")
            }
            guard name.count <= 64 else {
                throw RegistrationError.invalidDraft("Runner name is too long (max 64 characters).")
            }
            let labels = draft.labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !labels.isEmpty else {
                throw RegistrationError.invalidDraft("At least one label is required.")
            }
            for label in labels {
                guard !label.isEmpty else {
                    throw RegistrationError.invalidDraft("Labels must not be empty.")
                }
                guard label.count <= 100 else {
                    throw RegistrationError.invalidDraft("Label '\(label)' is too long (max 100 characters).")
                }
            }
            try validateNoSpace(installDirName: draft.installDirName, workFolder: draft.workFolder)
            switch draft.scope {
            case .organization:
                let group = draft.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !group.isEmpty else {
                    throw RegistrationError.invalidDraft("Organization runners need a dedicated per-Mac group name.")
                }
            case .repository:
                break
            }
        }

        /// Picks the architecture-matched official asset. Refuses any
        /// substitute: both OS and architecture must match exactly.
        public static func selectDownload(
            osName: String, arch: String, from assets: [DownloadAsset]
        ) throws -> DownloadAsset {
            guard let match = assets.first(where: { $0.osName == osName && $0.architecture == arch }) else {
                throw RegistrationError.downloadMismatch(osName: osName, arch: arch)
            }
            return match
        }

        /// Authorizes a group mutation only when the UI explicitly scoped it
        /// AND the target is this run's resolved dedicated group. Never
        /// mutates unrelated or shared groups.
        public static func authorizeGroupMutation(
            targetGroupID: Int64, resolvedGroupID: Int64?, allowFlag: Bool
        ) throws {
            guard allowFlag else { throw RegistrationError.groupScopeNotConfirmed }
            guard let resolved = resolvedGroupID, resolved == targetGroupID else {
                throw RegistrationError.refusesSharedGroup(groupID: targetGroupID)
            }
        }

        /// Repository scope never touches groups: personal repos get separate
        /// installations without shared-group coupling.
        public static func requireOrganizationScope(_ scope: Scope) throws {
            if case .organization = scope { return }
            throw RegistrationError.groupNotApplicable
        }

        /// Ownership check for a pre-existing group with the requested name.
        /// A name match alone never authorizes adoption: the caller must show
        /// either a locally recorded ownership entry for the same group ID or
        /// an explicit UI takeover confirmation.
        public static func authorizeGroupTakeover(
            groupName: String, existingID: Int64, ownedID: Int64?, allowTakeover: Bool
        ) throws {
            if let owned = ownedID, owned == existingID { return }
            guard allowTakeover else {
                throw RegistrationError.groupNameTaken(name: groupName, groupID: existingID)
            }
        }

        /// Duplicate-name guard run before any registration token is minted.
        /// Without explicit replace consent a remote name match refuses the
        /// run so `config.sh` can never silently replace another machine.
        public static func rejectRemoteDuplicate(name: String, isTaken: Bool, allowReplace: Bool) throws {
            guard isTaken, !allowReplace else { return }
            throw RegistrationError.remoteNameTaken(name: name)
        }

        /// Verifies the local `.runner` identity belongs to this draft's
        /// operation on the authenticated server. Returns the verified local
        /// agent ID. Refuses anything else: an unconfigured directory, a
        /// missing or unreadable agent ID, a name mismatch, a server/scope
        /// mismatch, or a work-folder mismatch. Agent IDs belong to their
        /// server: a same-ID foreign host never authorizes writes on this
        /// session's server. A remote name match alone never authorizes
        /// writes to another runner.
        public static func verifiedLocalAgentID(
            local: LocalRegistration?, configured: Bool, draft: Draft, serverHost: String
        ) throws -> Int64 {
            guard configured else {
                throw RegistrationError.unverifiedRegistration(
                    "Directory '\(draft.installDirName)' was never configured by this wizard. Register it first; refusing a planted or foreign registration."
                )
            }
            guard let local, let agentID = local.agentID else {
                throw RegistrationError.unverifiedRegistration(
                    "No verified local registration for '\(draft.runnerName)': install and register this directory first; refusing to touch a runner that is not this installation."
                )
            }
            let wanted = draft.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name = local.agentName, name == wanted else {
                throw RegistrationError.unverifiedRegistration(
                    "Local registration is for '\(local.agentName ?? "unknown")', not '\(wanted)'. Refusing to use another registration's identity."
                )
            }
            guard let address = local.gitHubURL,
                  scopeMatches(address: address, scope: draft.scope, serverHost: serverHost) else {
                throw RegistrationError.unverifiedRegistration(
                    "Local registration points at '\(local.gitHubURL ?? "unknown")', not this draft's scope on \(OperationIdentity.normalizeServerHost(serverHost)). Refusing to use another registration's identity."
                )
            }
            let wantedWork = draft.workFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let work = local.workFolder, work == wantedWork else {
                throw RegistrationError.unverifiedRegistration(
                    "Local registration uses work folder '\(local.workFolder ?? "unknown")', not '\(wantedWork)'. Reconfigure for the new work folder instead of reusing the old configuration."
                )
            }
            return agentID
        }

        /// Matches a `.runner` gitHubUrl against a draft scope on the
        /// authenticated server. Host must equal the session server
        /// (`www.github.com` aliases `github.com`); path mirrors
        /// RunnerDiscovery's parsing (one component for an org, two for
        /// owner/repo). GitHub logins compare case-insensitively. Agent IDs
        /// are server-scoped, so a same-path foreign host never matches.
        public static func scopeMatches(address: String, scope: Scope, serverHost: String) -> Bool {
            guard let url = URL(string: address), url.scheme == "https" else { return false }
            guard let host = url.host,
                  OperationIdentity.normalizeServerHost(host)
                    == OperationIdentity.normalizeServerHost(serverHost) else { return false }
            let components = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
            switch scope {
            case .organization(let org):
                return components == [org.lowercased()]
            case .repository(let owner, let name):
                return components == [owner.lowercased(), name.lowercased()]
            }
        }

        /// True when an edit changes operation identity (server is bound
        /// separately via the authenticated session): scope, install folder,
        /// runner name, work folder, or the dedicated group for org scope.
        /// Labels, repository selections, and consent flags are editable and
        /// never invalidate an in-flight operation.
        public static func identityFieldsChanged(old: Draft, new: Draft) -> Bool {
            if old.scope != new.scope { return true }
            if old.installDirName != new.installDirName { return true }
            let oldName = old.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let newName = new.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
            if oldName != newName { return true }
            if old.workFolder != new.workFolder { return true }
            let oldIsOrg: Bool = if case .organization = old.scope { true } else { false }
            let newIsOrg: Bool = if case .organization = new.scope { true } else { false }
            if oldIsOrg || newIsOrg {
                let oldGroup = old.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                let newGroup = new.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if oldGroup != newGroup { return true }
            }
            return false
        }

        /// Binds the complete remote runner list to the verified local agent
        /// ID. Returns the bound runner ID, or nil when this agent is not
        /// listed yet (retryable convergence, never an error by itself).
        /// Throws when the list contradicts the local identity — a same-name
        /// foreign runner or a renamed local agent — instead of guessing.
        public static func boundRemoteRunnerID(
            localAgentID: Int64, name: String, runners: [RegisteredRunner]
        ) throws -> Int64? {
            if let exact = runners.first(where: { $0.id == localAgentID }) {
                guard exact.name == name else {
                    throw RegistrationError.remoteIdentityMismatch(
                        "GitHub lists agent \(localAgentID) as '\(exact.name)', not '\(name)'. Refusing to write to a mismatched registration."
                    )
                }
                return exact.id
            }
            if let foreign = runners.first(where: { $0.name == name }) {
                throw RegistrationError.remoteIdentityMismatch(
                    "This installation is agent \(localAgentID), but GitHub shows '\(name)' as agent \(foreign.id). Refusing to adopt another runner's identity."
                )
            }
            return nil
        }

        /// Confirms a repository-access write against the complete confirmed
        /// list. Any difference — missing or extra IDs — fails closed instead
        /// of reporting partial access as complete.
        public static func confirmRepositoryIDs(requested: Set<Int64>, confirmed: [Int64]) throws {
            guard Set(confirmed) == requested else {
                throw RegistrationError.confirmationMismatch(
                    "GitHub confirmed repositories \(confirmed.sorted()) but \(requested.sorted()) was requested. Refusing to report partial access as complete."
                )
            }
        }
    }

    /// Exact `config.sh` invocation inputs.
    public struct ConfigSpec: Sendable, Equatable {
        let scopeURL: String
        let token: String
        let name: String
        let workFolder: String
        let labels: [String]
        let runnerGroup: String?
        /// Explicit `--replace`. Production sets it only from
        /// `Draft.allowReplace`; default invocations omit the flag so a
        /// duplicate name fails instead of stealing another registration.
        let replace: Bool
    }

    /// Exact `config.sh` invocation builder. Argument order is fixed and
    /// covered by tests; production runs this exact array.
    public enum ConfigInvocation {
        public static func arguments(_ spec: ConfigSpec) -> [String] {
            var args = [
                "--url", spec.scopeURL,
                "--token", spec.token,
                "--name", spec.name,
                "--work", spec.workFolder,
                "--labels", spec.labels.joined(separator: ",")
            ]
            if let group = spec.runnerGroup, !group.isEmpty {
                args += ["--runnergroup", group]
            }
            args += ["--unattended"]
            if spec.replace {
                args += ["--replace"]
            }
            return args
        }
    }
}
