import Combine
import Foundation
import Relux

extension GitHubAuth {
    @MainActor public final class State: ObservableObject, Relux.HybridState {
        @Published public internal(set) var connection: Connection = .disconnected
        @Published public internal(set) var username: String?
        @Published public internal(set) var userID: Int64?
        @Published public internal(set) var serverHost: String = "github.com"
        @Published public internal(set) var installations: [Installation] = []
        @Published public internal(set) var selectedInstallationID: Int64?
        @Published public internal(set) var repositories: [Repository] = []
        @Published public internal(set) var selectedRepositoryIDs: Set<Int64> = []
        @Published public internal(set) var syncError: String?
        @Published public internal(set) var lastSyncAt: Date?

        public init() {}

        public func cleanup() async {
            connection = .disconnected
            username = nil
            userID = nil
            serverHost = "github.com"
            installations = []
            selectedInstallationID = nil
            repositories = []
            selectedRepositoryIDs = []
            syncError = nil
            lastSyncAt = nil
        }
    }

    public enum Action: Relux.Action {
        case restoreStarted(serverHost: String)
        case loginStarted(serverHost: String)
        case codeReceived(userCode: String, verificationURI: URL, expiresIn: Int, interval: Int)
        case pollIntervalUpdated(Int)
        case loginCancelled
        case accountVerified(username: String, userID: Int64, serverHost: String)
        case installationsLoaded([Installation])
        case repositoriesLoaded(installationID: Int64, repositories: [Repository])
        case connected(username: String, serverHost: String, syncedAt: Date)
        case failed(message: String, retry: RetryKind)
        case syncFailed(message: String)
        case syncSucceeded(Date)
        case installationSelected(Int64?)
        case repositoriesSelected(Set<Int64>)
        case loggedOut
        case clearSyncError
    }

    public enum Effect: Relux.Effect {
        case restoreSession
        case beginLogin(serverHost: String?)
        case cancelLogin
        case logout
        case refreshInstallations
        case selectInstallation(Int64?)
        case selectRepositories(Set<Int64>)
    }
}
