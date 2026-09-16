import Foundation
import Relux

extension GitHubAuth.State {
    public func reduce(with action: any Relux.Action) async {
        guard let action = action as? GitHubAuth.Action else { return }
        switch action {
        case .restoreStarted(let host):
            connection = .verifyingAccount
            serverHost = host
            syncError = nil
        case .loginStarted(let host):
            connection = .requestingCode
            serverHost = host
            syncError = nil
        case .codeReceived(let userCode, let uri, let expiresIn, let interval):
            connection = .awaitingUser(userCode: userCode, verificationURI: uri, expiresIn: expiresIn, interval: interval)
        case .pollIntervalUpdated(let interval):
            if case .awaitingUser(let userCode, let uri, let expiresIn, _) = connection {
                connection = .awaitingUser(userCode: userCode, verificationURI: uri, expiresIn: expiresIn, interval: interval)
            }
        case .loginCancelled:
            connection = .disconnected
            syncError = nil
        case .accountVerified(let username, let userID, let host):
            self.username = username
            self.userID = userID
            serverHost = host
            connection = .verifyingInstallations(username: username)
        case .installationsLoaded(let installations):
            self.installations = installations
            if selectedInstallationID == nil {
                selectedInstallationID = installations.first?.id
            } else if let selected = selectedInstallationID, !installations.contains(where: { $0.id == selected }) {
                selectedInstallationID = installations.first?.id
            }
        case .repositoriesLoaded(let installationID, let repositories):
            if selectedInstallationID == installationID || selectedInstallationID == nil {
                self.repositories = repositories
            }
        case .connected(let username, let host, let date):
            self.username = username
            serverHost = host
            connection = .connected(username: username, serverHost: host)
            lastSyncAt = date
            syncError = nil
        case .failed(let message, let retry):
            connection = .failed(message: message, retry: retry)
        case .syncFailed(let message):
            syncError = message
        case .syncSucceeded(let date):
            lastSyncAt = date
            syncError = nil
        case .installationSelected(let id):
            selectedInstallationID = id
            repositories = []
        case .repositoriesSelected(let ids):
            selectedRepositoryIDs = ids
        case .loggedOut:
            connection = .disconnected
            username = nil
            userID = nil
            installations = []
            selectedInstallationID = nil
            repositories = []
            selectedRepositoryIDs = []
            syncError = nil
            lastSyncAt = nil
        case .clearSyncError:
            syncError = nil
        }
    }
}
