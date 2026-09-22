import SwiftUI
import RunnerControlCore

extension Runners.Snapshot {
    var remoteLabels: [String] { remote?.labels ?? [] }
    var remoteGroup: String? { remote?.group }
}

extension ManagementWindowPage {
    struct GitHubProps {
        let connection: GitHubAuth.Connection
        let username: String?
        let serverHost: String
        let serverHostText: String
        let installations: [GitHubAuth.Installation]
        let selectedInstallationID: Int64?
        let repositories: [GitHubAuth.Repository]
        let selectedRepositoryIDs: Set<Int64>
        let syncError: String?
        let lastSyncAt: Date?
    }
    struct GeneralProps {
        let appVersion: String
        let canCheckForUpdates: Bool
        let automaticChecks: Bool
        let automaticDownloads: Bool
        let launchAtLoginEnabled: Bool
        let cliAvailable: Bool
        let cliInstalled: Bool
        let cliStatus: String
        let cliBusy: Bool
    }
    struct RunnersProps {
        let snapshots: [Runners.Snapshot]
        let changing: Set<String>
        let runnerError: String?
        let candidates: [RunnerDiscovery.Candidate]
        let catalogError: String?
        let selectedID: String?
        let unregistering: Set<String>
        let remoteSyncError: String?
        let lastRemoteSync: Date?
        let logPreviewTitle: String?
        let logPreview: String?
        let groupAccess: [String: Runners.GroupAccess]
        let candidateRepositories: [GitHubAuth.Repository]
        let installations: [GitHubAuth.Installation]
        let selectedInstallationID: Int64?
    }
    struct Props {
        let runners: RunnersProps
        let github: GitHubProps
        let general: GeneralProps
    }
    struct Reactions {
        let setEnabled: (String, Bool) -> Void
        let enableAll: () -> Void
        let disableAll: () -> Void
        let openGitHub: (Runners.Definition) -> Void
        let openLogs: (Runners.Definition) -> Void
        let showDirectory: (Runners.Definition) -> Void
        let clearRunnerError: () -> Void
        let openRegistration: () -> Void
        let discover: () -> Void
        let importCandidate: (RunnerDiscovery.Candidate) -> Void
        let importFolder: () -> Void
        let removeFromApp: (String) -> Void
        let unregister: (String) -> Void
        let setRunAtLoad: (String, Bool) -> Void
        let renameRunner: (String) -> Void
        let relink: (String) -> Void
        let selectRunner: (String?) -> Void
        let loadLog: (String) -> Void
        let clearLog: () -> Void
        let clearCatalogError: () -> Void
        let refreshRemote: () -> Void
        let loadGroupAccess: (String) -> Void
        let applyGroupAccess: (String, Set<Int64>) -> Void
        let serverHostChanged: (String) -> Void
        let beginLogin: () -> Void
        let cancelLogin: () -> Void
        let logout: () -> Void
        let openVerification: (URL) -> Void
        let copyCode: (String) -> Void
        let refreshInstallations: () -> Void
        let selectInstallation: (Int64?) -> Void
        let selectRepositories: (Set<Int64>) -> Void
        let grantAccess: () -> Void
        let revokeInGitHub: () -> Void
        let checkForUpdates: () -> Void
        let setAutomaticChecks: (Bool) -> Void
        let setAutomaticDownloads: (Bool) -> Void
        let setLaunchAtLogin: (Bool) -> Void
        let installCLI: () -> Void
        let installCLIForUser: () -> Void
        let uninstallCLI: () -> Void
        let quit: () -> Void
    }
}
