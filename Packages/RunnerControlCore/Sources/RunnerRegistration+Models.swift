import Foundation

extension RunnerRegistration {
    /// Registration scope. One wizard run registers exactly one scope:
    /// an organization (shared, via a dedicated per-Mac group) or a single
    /// personal repository (separate installation, no group).
    public enum Scope: Sendable, Equatable, Hashable {
        case organization(org: String)
        case repository(owner: String, name: String)

        /// REST path prefix below the API base URL, e.g. `orgs/acme` or `repos/acme/app`.
        public var apiPrefix: String {
            switch self {
            case .organization(let org): "orgs/\(org)"
            case .repository(let owner, let name): "repos/\(owner)/\(name)"
            }
        }

        /// Short key for token-store accounts and markers. Never contains secrets.
        public var scopeKey: String {
            switch self {
            case .organization(let org): "org:\(org)"
            case .repository(let owner, let name): "repo:\(owner)/\(name)"
            }
        }

        /// URL passed to `config.sh --url`. Enterprise hosts keep their own server.
        public func configURL(serverHost: String) -> String {
            let host = serverHost == "github.com" || serverHost == "www.github.com"
                ? "https://github.com"
                : "https://\(serverHost)"
            switch self {
            case .organization(let org): return "\(host)/\(org)"
            case .repository(let owner, let name): return "\(host)/\(owner)/\(name)"
            }
        }

        /// Detail line shown in UI, e.g. `acme` or `acme/app`.
        public var detail: String {
            switch self {
            case .organization(let org): org
            case .repository(let owner, let name): "\(owner)/\(name)"
            }
        }
    }

    /// User-editable wizard input. Holds no tokens.
    public struct Draft: Sendable, Equatable {
        public var scope: Scope
        public var runnerName: String
        public var labels: [String]
        public var installDirName: String
        public var workFolder: String
        /// Dedicated per-Mac group name for org scope. Ignored for repo scope.
        public var groupName: String
        public var selectedRepositoryIDs: Set<Int64>
        /// Explicit UI scope: user confirmed that group mutations apply only
        /// to the resolved dedicated group. Never implied.
        public var allowGroupMutation: Bool
        /// Explicit takeover: user confirmed that a pre-existing group with
        /// the same name is this Mac's dedicated group. Name alone never
        /// authorizes adopting or editing a shared group.
        public var allowGroupTakeover: Bool
        /// Explicit replace: user confirmed that config may replace an
        /// existing GitHub registration with the same runner name. Without
        /// it the wizard refuses remote duplicates instead of silently
        /// stealing another machine's registration via `--replace`.
        public var allowReplace: Bool

        public init(
            scope: Scope,
            runnerName: String,
            labels: [String] = ["self-hosted", "macOS"],
            installDirName: String,
            workFolder: String = "_work",
            groupName: String = "",
            selectedRepositoryIDs: Set<Int64> = [],
            allowGroupMutation: Bool = false,
            allowGroupTakeover: Bool = false,
            allowReplace: Bool = false
        ) {
            self.scope = scope
            self.runnerName = runnerName
            self.labels = labels
            self.installDirName = installDirName
            self.workFolder = workFolder
            self.groupName = groupName
            self.selectedRepositoryIDs = selectedRepositoryIDs
            self.allowGroupMutation = allowGroupMutation
            self.allowGroupTakeover = allowGroupTakeover
            self.allowReplace = allowReplace
        }

        /// Default per-Mac group name derived from the Mac name.
        public static func defaultGroupName(hostName: String) -> String {
            let trimmed = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty ? "Mac" : trimmed
            return "RunnerControl-\(base)"
        }
    }

    /// Immutable operation identity. Every async step captures it at start
    /// and binds its completion to it: a draft edit that changes any field,
    /// or an authenticated-server change, abandons the in-flight completion
    /// instead of attributing stale success to the new identity. Labels,
    /// selected repositories, and consent flags are editable selections, not
    /// identity: they re-target pending retries to the visible values.
    public struct OperationIdentity: Sendable, Equatable {
        public let serverHost: String
        public let scope: Scope
        public let installDirName: String
        public let runnerName: String
        public let workFolder: String
        public let groupName: String

        public init(
            serverHost: String, scope: Scope, installDirName: String,
            runnerName: String, workFolder: String, groupName: String
        ) {
            self.serverHost = Self.normalizeServerHost(serverHost)
            self.scope = scope
            self.installDirName = installDirName
            self.runnerName = runnerName
            self.workFolder = workFolder
            self.groupName = groupName
        }

        /// Canonical server comparison. `www.github.com` is the same
        /// deployment as `github.com`; every other host compares lowercased.
        public static func normalizeServerHost(_ host: String) -> String {
            let lowered = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered == "www.github.com" { return "github.com" }
            return lowered
        }

        public static func make(draft: Draft, serverHost: String) -> Self {
            let group: String
            switch draft.scope {
            case .organization:
                group = draft.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            case .repository:
                group = ""
            }
            return Self(
                serverHost: serverHost,
                scope: draft.scope,
                installDirName: draft.installDirName,
                runnerName: draft.runnerName.trimmingCharacters(in: .whitespacesAndNewlines),
                workFolder: draft.workFolder,
                groupName: group
            )
        }
    }

    /// Official runner download asset as returned by the downloads endpoint.
    public struct DownloadAsset: Sendable, Equatable {
        public let osName: String
        public let architecture: String
        public let downloadURL: URL
        public let filename: String
        public let sha256Checksum: String?
        public init(osName: String, architecture: String, downloadURL: URL, filename: String, sha256Checksum: String?) {
            self.osName = osName; self.architecture = architecture
            self.downloadURL = downloadURL; self.filename = filename
            self.sha256Checksum = sha256Checksum
        }
    }

    /// Runner group summary. Repository access is fetched separately.
    /// `allowsPublicRepositories` mirrors GitHub's `allows_public_repositories`
    /// flag: without it a `selected`-visibility group silently denies every
    /// selected public repository.
    public struct RunnerGroup: Sendable, Equatable {
        public let id: Int64
        public let name: String
        public let visibility: String
        public let allowsPublicRepositories: Bool
        public init(id: Int64, name: String, visibility: String, allowsPublicRepositories: Bool = false) {
            self.id = id; self.name = name; self.visibility = visibility
            self.allowsPublicRepositories = allowsPublicRepositories
        }
    }

    /// Registered runner identity fetched from GitHub after config.
    /// `status` is `online`/`offline` when the API reports it; `busy`
    /// mirrors the API busy flag. Registration matching uses only the ID
    /// and name; observation uses status/busy.
    public struct RegisteredRunner: Sendable, Equatable {
        public let id: Int64
        public let name: String
        public let labels: [String]
        public let status: String?
        public let busy: Bool?
        public init(id: Int64, name: String, labels: [String], status: String? = nil, busy: Bool? = nil) {
            self.id = id; self.name = name; self.labels = labels
            self.status = status; self.busy = busy
        }
    }

    /// Local `.runner` identity, read without touching credentials.
    /// Every field is optional because a missing, corrupt, or foreign file
    /// must fail verification explicitly instead of crashing the wizard.
    public struct LocalRegistration: Sendable, Equatable {
        public let agentID: Int64?
        public let agentName: String?
        public let gitHubURL: String?
        public let workFolder: String?
        public init(agentID: Int64?, agentName: String?, gitHubURL: String?, workFolder: String?) {
            self.agentID = agentID; self.agentName = agentName
            self.gitHubURL = gitHubURL; self.workFolder = workFolder
        }
    }
}

extension RunnerRegistration {
    public enum RegistrationError: LocalizedError, Sendable, Equatable {
        case notAuthenticated
        case missingPermission(String)
        case invalidDraft(String)
        case noSpacePath(String)
        case downloadMismatch(osName: String, arch: String)
        case integrityMismatch
        case groupScopeNotConfirmed
        case refusesSharedGroup(groupID: Int64)
        case groupNameTaken(name: String, groupID: Int64)
        case groupNotApplicable
        case alreadyInstalled(path: String)
        case alreadyRegistered(name: String)
        case remoteNameTaken(name: String)
        case unverifiedRegistration(String)
        case remoteIdentityMismatch(String)
        case remoteRunnerNotFound(String)
        case confirmationMismatch(String)
        case network(String)
        /// The login session that authorized a mutating operation changed
        /// (logout, account/server switch, or a new login incarnation)
        /// before the side effect began. The unstarted side effect is
        /// refused; nothing was undone because nothing ran yet.
        case sessionInvalidated
        case unauthorized
        case forbidden(String)
        case rateLimited
        case configFailed(String)
        case cancelled
        /// Installer mutation refused while another operation holds the
        /// installer-wide lease. Retryable: the owner releases the lease
        /// when it settles, independently of UI generation abandonment.
        /// Deliberate product behavior: the wizard runs ONE active installer
        /// mutation per app instance, for any directory.
        case installerBusy(path: String)

        public var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                "Sign in with GitHub first. Registration needs an authenticated session."
            case .missingPermission(let text):
                text.isEmpty ? "Missing GitHub permission for this step." : text
            case .invalidDraft(let text):
                text
            case .noSpacePath(let text):
                text
            case .downloadMismatch(let osName, let arch):
                "No official runner package for os=\(osName) arch=\(arch). Refusing substitute builds."
            case .integrityMismatch:
                "Download integrity check failed (SHA-256 mismatch). Refusing to install."
            case .groupScopeNotConfirmed:
                "Repository access changes need explicit confirmation for the dedicated group."
            case .refusesSharedGroup(let groupID):
                "Refusing to change group \(groupID): it is not this Mac's dedicated group."
            case .groupNameTaken(let name, let groupID):
                "Group '\(name)' already exists (id \(groupID)) and is not this Mac's dedicated group. Choose a different name or explicitly confirm takeover."
            case .groupNotApplicable:
                "Runner groups apply to organization runners only. Repository runners use separate installations."
            case .alreadyInstalled(let path):
                "Installation already exists at \(path). Resume or remove it before retrying."
            case .alreadyRegistered(let name):
                "Runner '\(name)' is already registered here. Reuse it instead of creating a duplicate."
            case .remoteNameTaken(let name):
                "Runner '\(name)' already exists in GitHub. Choose a different name or explicitly allow replace; refusing to silently replace another registration."
            case .unverifiedRegistration(let text):
                text.isEmpty ? "No verified local registration for this installation. Refusing to touch a runner that is not this Mac's installation." : text
            case .remoteIdentityMismatch(let text):
                text.isEmpty ? "GitHub's runner list contradicts this installation's identity. Refusing to adopt another runner." : text
            case .remoteRunnerNotFound(let text):
                text.isEmpty ? "GitHub does not list this installation yet. Refusing to guess by name." : text
            case .confirmationMismatch(let text):
                text.isEmpty ? "GitHub confirmed different repositories than requested. Refusing to report partial access as complete." : text
            case .network(let text):
                text
            case .sessionInvalidated:
                "GitHub session changed before the removal began. Sign in again and retry; nothing was removed."
            case .unauthorized:
                "Session expired or revoked (401). Sign in again."
            case .forbidden(let text):
                text.isEmpty ? "Access forbidden (403)." : text
            case .rateLimited:
                "GitHub rate limit reached. Retry later; local runners keep working."
            case .configFailed(let text):
                text.isEmpty ? "Runner configuration failed." : text
            case .cancelled:
                "Registration cancelled."
            case .installerBusy(let path):
                "Installer is busy with another registration operation. '\(path)' was not started. Retry after it settles; no second operation was started."
            }
        }
    }
}
