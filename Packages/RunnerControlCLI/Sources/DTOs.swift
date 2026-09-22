import Foundation
import RunnerControlCore

/// Process exit codes. Stable contract for agent harnesses: 0 is success,
/// 1 is a CLI usage error (thrown by ArgumentParser), anything else is a
/// failed operation with a human message on stderr (and a JSON error doc
/// on stdout when `--json` is set).
public enum CLIExit: Int32, Sendable {
    case success = 0
    case usage = 1
    case failed = 2
    case needsLogin = 3
}

/// A failed command. Carries the exit code so `main` stays a thin mapper.
public struct CLIFailure: Error, Sendable {
    public let code: CLIExit
    public let message: String
    public init(_ code: CLIExit, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// Stable JSON envelope. Every `--json` invocation prints exactly one doc:
/// either `{status,data}` or `{status,error}`.
public struct CLIEnvelope<Payload: Encodable>: Encodable {
    public let status: String
    public let data: Payload?
    public let error: String?
    public init(status: String, data: Payload? = nil, error: String? = nil) {
        self.status = status
        self.data = data
        self.error = error
    }
}

public struct EmptyPayload: Encodable {}

/// Output DTOs. Field names are the CLI's JSON contract; Core models stay
/// untouched. No DTO ever carries a token, device code secret, or Keychain
/// payload: only the user-visible device `userCode`, which the GUI shows too.
public struct RunnerDTO: Codable, Sendable, Equatable {
    public var id: String
    public var localID: String?
    public var title: String
    public var displayTitle: String
    public var detail: String
    public var directory: String
    public var plist: String
    public var status: String
    public var message: String?
    public var controller: String
    public var runAtLoad: Bool?
    public var loginEnabled: Bool?
    public var serverHost: String?
    public var remoteAgentID: Int64?
    public var workFolder: String?
    public var githubURL: String
    public var remote: RemoteDTO?

    public init(snapshot: Runners.Snapshot) {
        let def = snapshot.definition
        id = snapshot.id
        localID = def.localID
        title = def.title
        displayTitle = def.displayTitle
        detail = def.detail
        directory = def.directory.path
        plist = def.plist.path
        status = snapshot.status.rawValue
        message = snapshot.message
        controller = def.controllerKind.rawValue
        runAtLoad = def.runAtLoad
        loginEnabled = def.loginEnabled
        serverHost = def.serverHost
        remoteAgentID = def.remoteAgentID
        workFolder = def.workFolder
        githubURL = def.githubURL.absoluteString
        remote = snapshot.remote.map(RemoteDTO.init)
    }
}

public struct RemoteDTO: Codable, Sendable, Equatable {
    public var online: Bool?
    public var busy: Bool?
    public var busyKnown: Bool
    public var labels: [String]
    public var group: String?
    public var updatedAt: Date?
    public var stale: Bool
    public var syncError: String?
    public var signature: String

    public init(_ remote: Runners.RemoteObservation) {
        online = remote.online
        busy = remote.busy
        busyKnown = remote.busyKnown
        labels = remote.labels
        group = remote.group
        updatedAt = remote.updatedAt
        stale = remote.stale
        syncError = remote.syncError
        signature = remote.signature
    }
}

/// `runners remove` payload: the remaining catalog plus the "service keeps
/// running" note text mode prints (key omitted when nothing was reported).
public struct RemoveDTO: Codable, Sendable, Equatable {
    public var runners: [RunnerDTO]
    public var note: String?
}

/// `app check-updates` payload. Booleans are real JSON booleans, like
/// every other DTO — never "true"/"false" strings.
public struct UpdateCheckDTO: Codable, Sendable, Equatable {
    public var current: String
    public var latest: String
    public var updateAvailable: Bool
    public var feed: String
}

/// `app launch-at-login` payload: last state the GUI confirmed via
/// SMAppService (`enabled`, nil when never confirmed) plus whether a CLI
/// request is still outstanding.
public struct LoginItemDTO: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var pending: Bool
    public var appliedAt: Date?

    public init(status: LoginItemBridge.Status) {
        enabled = status.applied
        pending = status.pending
        appliedAt = status.appliedAt
    }
}

public struct CandidateDTO: Codable, Sendable, Equatable {
    public var directory: String
    public var agentName: String?
    public var scope: String?
    public var serverHost: String?
    public var controller: String
    public var runAtLoad: Bool?
    public var noSpacePath: Bool
    public var isImportable: Bool
    public var issues: [String]

    public init(_ candidate: RunnerDiscovery.Candidate) {
        directory = candidate.directory.path
        agentName = candidate.agentName
        scope = candidate.scope
        serverHost = candidate.serverHost
        controller = candidate.controllerKind.rawValue
        runAtLoad = candidate.runAtLoad
        noSpacePath = candidate.noSpacePath
        isImportable = candidate.isImportable
        issues = candidate.issues
    }
}

public struct AuthStatusDTO: Codable, Sendable, Equatable {
    public var connected: Bool
    public var username: String?
    public var userID: Int64?
    public var serverHost: String
    public var phase: String
    public var installations: [InstallationDTO]
    public var selectedInstallationID: Int64?
    public var repositories: [RepositoryDTO]
    public var selectedRepositoryIDs: [Int64]
    public var syncError: String?
    public var lastSyncAt: Date?

    @MainActor public init(state: GitHubAuth.State) {
        switch state.connection {
        case .connected(let name, _):
            connected = true
            phase = "connected"
            username = name
        case .disconnected: connected = false; phase = "disconnected"
        case .requestingCode: connected = false; phase = "requestingCode"
        case .awaitingUser: connected = false; phase = "awaitingUser"
        case .verifyingAccount: connected = false; phase = "verifyingAccount"
        case .verifyingInstallations: connected = false; phase = "verifyingInstallations"
        case .failed(let message, _): connected = false; phase = "failed:\(message)"
        }
        if username == nil { username = state.username }
        userID = state.userID
        serverHost = state.serverHost
        installations = state.installations.map(InstallationDTO.init)
        selectedInstallationID = state.selectedInstallationID
        repositories = state.repositories.map(RepositoryDTO.init)
        selectedRepositoryIDs = Array(state.selectedRepositoryIDs).sorted()
        syncError = state.syncError
        lastSyncAt = state.lastSyncAt
    }
}

public struct InstallationDTO: Codable, Sendable, Equatable {
    public var id: Int64
    public var account: String
    public var accountType: String
    public init(_ installation: GitHubAuth.Installation) {
        id = installation.id
        account = installation.account
        accountType = installation.accountType
    }
}

public struct RepositoryDTO: Codable, Sendable, Equatable {
    public var id: Int64
    public var fullName: String
    public var isPrivate: Bool
    public init(_ repo: GitHubAuth.Repository) {
        id = repo.id
        fullName = repo.fullName
        isPrivate = repo.isPrivate
    }
}

public struct GroupAccessDTO: Codable, Sendable, Equatable {
    public var groupID: Int64?
    public var groupName: String?
    public var visibility: String?
    public var allowsPublicRepositories: Bool?
    public var repositoryIDs: [Int64]
    public var owned: Bool
    public var updatedAt: Date?

    public init(_ access: Runners.GroupAccess) {
        groupID = access.group?.id
        groupName = access.group?.name
        visibility = access.group?.visibility
        allowsPublicRepositories = access.group?.allowsPublicRepositories
        repositoryIDs = access.repoIDs
        owned = access.owned
        updatedAt = access.updatedAt
    }
}

public struct RegistrationDTO: Codable, Sendable, Equatable {
    public var phase: String
    public var steps: [String]
    public var groupID: Int64?
    public var groupName: String?
    public var installPath: String?
    public var runnerID: Int64?
    public var localAgentID: Int64?

    @MainActor public init(state: RunnerRegistration.State) {
        phase = String(describing: state.phase)
        steps = Array(state.completedSteps).sorted()
        groupID = state.group?.id
        groupName = state.group?.name
        installPath = state.installPath
        runnerID = state.runnerID
        localAgentID = state.localAgentID
    }
}
