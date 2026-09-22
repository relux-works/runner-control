import Foundation
import Relux

extension GitHubAuth {
    public protocol IFlow: Relux.Flow {}
    public struct Session: Sendable {
        let userID: Int64
        let username: String
        let serverHost: String
        let config: AppConfig
    }

    public actor Flow {
        public let dispatcher: Relux.Dispatcher
        private let deviceFlow: GitHubDeviceFlow
        private let api: GitHubAPIClient
        private let refresher: GitHubTokenRefresh
        private let store: any GitHubCredentialStoring
        private let identities: any GitHubSessionIdentityStoring
        private let configProvider: @Sendable (String?) throws -> GitHubAuth.AppConfig
        private let sleeper: @Sendable (UInt64) async throws -> Void
        private let now: @Sendable () -> Date

        private var deviceCode: String?
        private var generation = 0
        private var pollTask: Task<Void, Never>?
        private var session: Session?

        public init(
            deviceFlow: GitHubDeviceFlow,
            api: GitHubAPIClient,
            refresher: GitHubTokenRefresh,
            store: any GitHubCredentialStoring,
            identityStore: (any GitHubSessionIdentityStoring)? = nil,
            configProvider: (@Sendable (String?) throws -> GitHubAuth.AppConfig)? = nil,
            sleeper: (@Sendable (UInt64) async throws -> Void)? = nil,
            now: (@Sendable () -> Date)? = nil,
            dispatcher: Relux.Dispatcher? = nil
        ) async {
            self.deviceFlow = deviceFlow
            self.api = api
            self.refresher = refresher
            self.store = store
            self.identities = identityStore ?? UserDefaultsGitHubSessionIdentityStore()
            self.configProvider = configProvider ?? { host in try GitHubAuth.AppConfig.current(serverHost: host ?? "github.com") }
            self.sleeper = sleeper ?? { try await Task.sleep(nanoseconds: $0) }
            self.now = now ?? Date.init
            self.dispatcher = if let dispatcher { dispatcher } else { await Self.defaultDispatcher }
        }
    }
}

extension GitHubAuth.Flow: GitHubAuth.IFlow {
    public func apply(_ effect: any Relux.Effect) async -> Relux.ActionResult {
        guard let effect = effect as? GitHubAuth.Effect else { return .success }
        switch effect {
        case .restoreSession: await restoreSession()
        case .beginLogin(let host): await beginLogin(serverHost: host)
        case .cancelLogin: await cancelLogin()
        case .logout: await logout()
        case .refreshInstallations: await refreshInstallations()
        case .selectInstallation(let id): await selectInstallation(id)
        case .selectRepositories(let ids): await action { GitHubAuth.Action.repositoriesSelected(ids) }
        }
        return .success
    }

    /// True once a logout, cancel, or newer login has superseded `gen`.
    /// Stale continuations must stop silently: no state emission, no session/identity
    /// restore, no token saves.
    private func isStale(_ gen: Int) -> Bool { generation != gen }

    private func beginLogin(serverHost: String?) async {
        generation += 1
        let gen = generation
        pollTask?.cancel()
        pollTask = nil
        await refresher.cancelInFlight()
        deviceCode = nil
        let config: GitHubAuth.AppConfig
        do {
            config = try configProvider(serverHost)
        } catch let error as GitHubAuth.ConfigError {
            if case .missingClientID(let binding) = error {
                await action { GitHubAuth.Action.failed(message: GitHubAuth.AuthError.missingClientID(binding: binding).localizedDescription, retry: .none) }
            } else {
                await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .none) }
            }
            return
        } catch {
            await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .none) }
            return
        }
        await action { GitHubAuth.Action.loginStarted(serverHost: config.serverHost) }
        let response: GitHubAuth.DeviceCodeResponse
        do {
            response = try await deviceFlow.requestCode(config: config)
        } catch let error as GitHubAuth.AuthError {
            await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: Self.retryKind(for: error)) }
            return
        } catch {
            await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .retry) }
            return
        }
        guard generation == gen else { return }
        deviceCode = response.device_code
        guard let uri = URL(string: response.verification_uri) else {
            await action { GitHubAuth.Action.failed(message: GitHubTransportError.invalidResponse.localizedDescription, retry: .newCode) }
            deviceCode = nil
            return
        }
        await action { GitHubAuth.Action.codeReceived(userCode: response.user_code, verificationURI: uri, expiresIn: response.expires_in, interval: response.interval) }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollLoop(generation: gen, config: config, interval: response.interval, expiresIn: response.expires_in)
        }
    }

    private func pollLoop(generation gen: Int, config: GitHubAuth.AppConfig, interval: Int, expiresIn: Int) async {
        var currentInterval = interval
        let deadline = now().addingTimeInterval(TimeInterval(expiresIn))
        while generation == gen {
            do {
                try await sleeper(UInt64(currentInterval) * 1_000_000_000)
            } catch {
                return
            }
            guard generation == gen else { return }
            if now() >= deadline {
                deviceCode = nil
                await action { GitHubAuth.Action.failed(message: GitHubAuth.AuthError.codeExpired.localizedDescription, retry: .newCode) }
                return
            }
            guard let code = deviceCode else { return }
            let result: GitHubAuth.PollResult
            do {
                result = try await deviceFlow.pollOnce(config: config, deviceCode: code)
            } catch let error as GitHubAuth.AuthError {
                guard generation == gen else { return }
                deviceCode = nil
                await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: Self.retryKind(for: error)) }
                return
            } catch {
                guard generation == gen else { return }
                deviceCode = nil
                await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .retry) }
                return
            }
            guard generation == gen else { return }
            switch result {
            case .pending:
                continue
            case .slowDown:
                currentInterval = GitHubDeviceFlow.nextInterval(current: currentInterval, after: .slowDown)
                let updatedInterval = currentInterval
                await action { GitHubAuth.Action.pollIntervalUpdated(updatedInterval) }
            case .denied:
                deviceCode = nil
                await action { GitHubAuth.Action.failed(message: GitHubAuth.AuthError.denied.localizedDescription, retry: .newCode) }
                return
            case .expired:
                deviceCode = nil
                await action { GitHubAuth.Action.failed(message: GitHubAuth.AuthError.codeExpired.localizedDescription, retry: .newCode) }
                return
            case .success(let accessToken, let refreshToken, let expiresIn):
                await handlePollSuccess(
                    generation: gen,
                    config: config,
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiresIn: expiresIn
                )
                return
            }
        }
    }

    private func handlePollSuccess(generation gen: Int, config: GitHubAuth.AppConfig, accessToken: String, refreshToken: String?, expiresIn: Int?) async {
        guard generation == gen else { return }
        let user: GitHubAuth.UserResponse
        do {
            user = try await api.fetchUser(config: config, token: accessToken)
        } catch let error as GitHubAuth.AuthError {
            guard generation == gen else { return }
            deviceCode = nil
            await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: Self.retryKind(for: error)) }
            return
        } catch {
            guard generation == gen else { return }
            deviceCode = nil
            await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .retry) }
            return
        }
        guard generation == gen else { return }
        let expiresAt: Date? = expiresIn.map { now().addingTimeInterval(TimeInterval($0)) }
        let record = GitHubAuth.TokenRecord(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, obtainedAt: now())
        do {
            try await store.save(record, serverHost: config.serverHost, userID: user.id, clientID: config.clientID)
        } catch {
            guard generation == gen else { return }
            deviceCode = nil
            await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .retry) }
            return
        }
        guard generation == gen else { return }
        session = GitHubAuth.Session(userID: user.id, username: user.login, serverHost: config.serverHost, config: config)
        await identities.save(GitHubSessionIdentity(serverHost: config.serverHost, userID: user.id, clientID: config.clientID, username: user.login, sessionIncarnation: UUID().uuidString))
        guard generation == gen else { return }
        deviceCode = nil
        await action { GitHubAuth.Action.accountVerified(username: user.login, userID: user.id, serverHost: config.serverHost) }
        guard generation == gen else { return }
        do {
            let installations = try await api.fetchInstallations(config: config, token: accessToken)
            guard generation == gen else { return }
            await action { GitHubAuth.Action.installationsLoaded(installations) }
            guard await loadLoginRepositories(generation: gen, config: config, token: accessToken, installations: installations) else { return }
            guard generation == gen else { return }
            await action { GitHubAuth.Action.connected(username: user.login, serverHost: config.serverHost, syncedAt: now()) }
        } catch {
            guard generation == gen else { return }
            await loginInstallationsFailed(error, username: user.login, serverHost: config.serverHost, generation: gen)
        }
    }

    /// Loads repositories for the first installation. False means superseded: caller must stop.
    private func loadLoginRepositories(generation gen: Int, config: GitHubAuth.AppConfig, token: String, installations: [GitHubAuth.Installation]) async -> Bool {
        guard let first = installations.first else {
            await action { GitHubAuth.Action.syncFailed(message: GitHubAuth.AuthError.needsInstallation.localizedDescription) }
            return true
        }
        do {
            let repos = try await api.fetchRepositories(config: config, token: token, installationID: first.id)
            guard generation == gen else { return false }
            await action { GitHubAuth.Action.repositoriesLoaded(installationID: first.id, repositories: repos) }
        } catch let error as GitHubAuth.AuthError {
            guard generation == gen else { return false }
            await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
        } catch {
            guard generation == gen else { return false }
            await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
        }
        return true
    }

    private func loginInstallationsFailed(_ error: Error, username: String, serverHost: String, generation gen: Int) async {
        if let authError = error as? GitHubAuth.AuthError, authError == .unauthorized || authError == .revoked {
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.failed(message: authError.localizedDescription, retry: .relogin) }
            return
        }
        guard !isStale(gen) else { return }
        await action { GitHubAuth.Action.installationsLoaded([]) }
        guard !isStale(gen) else { return }
        await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
        guard !isStale(gen) else { return }
        await action { GitHubAuth.Action.connected(username: username, serverHost: serverHost, syncedAt: now()) }
    }

    private func cancelLogin() async {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        await refresher.cancelInFlight()
        deviceCode = nil
        if let sess = session {
            await action { GitHubAuth.Action.connected(username: sess.username, serverHost: sess.serverHost, syncedAt: now()) }
        } else {
            await action { GitHubAuth.Action.loginCancelled }
        }
    }

    private func logout() async {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        await refresher.cancelInFlight()
        deviceCode = nil
        if let sess = session {
            await store.delete(serverHost: sess.serverHost, userID: sess.userID, clientID: sess.config.clientID)
            await store.deleteAll(serverHost: sess.serverHost, clientID: sess.config.clientID)
            await identities.delete()
        } else if let identity = await identities.load() {
            // Restore never ran (or session was lost): still reach persisted tokens.
            await store.delete(serverHost: identity.serverHost, userID: identity.userID, clientID: identity.clientID)
            await store.deleteAll(serverHost: identity.serverHost, clientID: identity.clientID)
            await identities.delete()
        }
        session = nil
        await action { GitHubAuth.Action.loggedOut }
    }

    /// Deletes the stored token and identity only when the stored token is
    /// still `accessToken` — the record this owner just proved dead. A
    /// concurrent owner (GUI vs CLI) may have already refreshed and saved a
    /// newer valid session since our read; deleting it would sign every
    /// surface out. Same compare-before-delete rule as the refresh cancel
    /// path in `GitHubTokenRefresh`.
    private func deleteSessionIfCurrent(
        serverHost: String, userID: Int64, clientID: String, accessToken: String
    ) async -> Bool {
        guard let stored = await store.load(serverHost: serverHost, userID: userID, clientID: clientID),
              stored.accessToken == accessToken else {
            return false
        }
        await store.delete(serverHost: serverHost, userID: userID, clientID: clientID)
        await identities.delete()
        return true
    }

    /// Re-establishes the session from persisted Keychain tokens after relaunch.
    /// Validates via `/user`; revoked tokens clear storage and require relogin,
    /// but only when the dead record is still current — a concurrent owner
    /// may have saved a newer session, in which case restore retries once
    /// against the fresh record instead of destroying it.
    /// Offline/403 keep the local session with a stale marker instead of disconnecting.
    private func restoreSession(retried: Bool = false) async {
        let gen = generation
        guard session == nil else { return }
        guard deviceCode == nil, pollTask == nil else { return }
        guard let identity = await identities.load() else { return }
        guard !isStale(gen) else { return }
        let config: GitHubAuth.AppConfig
        do {
            config = try configProvider(identity.serverHost)
        } catch let error as GitHubAuth.ConfigError {
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .none) }
            return
        } catch {
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .none) }
            return
        }
        guard var record = await store.load(serverHost: identity.serverHost, userID: identity.userID, clientID: identity.clientID) else {
            // A nil read conflates "no stored token" with "Keychain refused
            // this read" (locked keychain, denied prompt, foreign-team
            // probe). Deleting the identity here would orphan a still-valid
            // token and sign every surface out; a read-only restore must
            // never mutate. Stay disconnected and retry on the next launch —
            // login and logout repair stale identities explicitly.
            return
        }
        guard !isStale(gen) else { return }
        do {
            try GitHubAuth.PATGuard.validate(token: record.accessToken)
        } catch {
            guard !isStale(gen) else { return }
            let dead = await deleteSessionIfCurrent(serverHost: identity.serverHost, userID: identity.userID, clientID: identity.clientID, accessToken: record.accessToken)
            guard !isStale(gen) else { return }
            if !dead, !retried {
                await restoreSession(retried: true)
                return
            }
            await action { GitHubAuth.Action.failed(message: GitHubAuth.AuthError.patNotSupported.localizedDescription, retry: .none) }
            return
        }
        await action { GitHubAuth.Action.restoreStarted(serverHost: identity.serverHost) }
        guard !isStale(gen) else { return }
        // A 401 below with an unrefreshed expiring token blames the expired access
        // token, not the refresh token: keep storage and retry later instead of
        // demanding relogin and deleting a still-valid refresh token.
        var keptExpiringTokenAfterRefreshFailure = false
        if GitHubTokenRefresh.isExpiringSoon(record, now: now()) {
            do {
                record = try await refresher.refresh(config: config, userID: identity.userID, current: record)
            } catch is CancellationError {
                return
            } catch let error as GitHubAuth.AuthError {
                guard !isStale(gen) else { return }
                switch error {
                case .revoked, .unauthorized, .tokenRefreshFailed:
                    let dead = await deleteSessionIfCurrent(serverHost: identity.serverHost, userID: identity.userID, clientID: identity.clientID, accessToken: record.accessToken)
                    guard !isStale(gen) else { return }
                    if !dead, !retried {
                        await restoreSession(retried: true)
                        return
                    }
                    await action { GitHubAuth.Action.failed(message: GitHubAuth.AuthError.revoked.localizedDescription, retry: .relogin) }
                    return
                case .patNotSupported:
                    let dead = await deleteSessionIfCurrent(serverHost: identity.serverHost, userID: identity.userID, clientID: identity.clientID, accessToken: record.accessToken)
                    guard !isStale(gen) else { return }
                    if !dead, !retried {
                        await restoreSession(retried: true)
                        return
                    }
                    await action { GitHubAuth.Action.failed(message: GitHubAuth.AuthError.patNotSupported.localizedDescription, retry: .none) }
                    return
                default:
                    keptExpiringTokenAfterRefreshFailure = true
                }
            } catch {
                guard !isStale(gen) else { return }
                // Keep the stored token; validation below decides.
                keptExpiringTokenAfterRefreshFailure = true
            }
            guard !isStale(gen) else { return }
        }
        do {
            let user = try await api.fetchUser(config: config, token: record.accessToken)
            guard !isStale(gen) else { return }
            if user.id != identity.userID {
                await store.delete(serverHost: identity.serverHost, userID: identity.userID, clientID: identity.clientID)
                guard !isStale(gen) else { return }
                try? await store.save(record, serverHost: identity.serverHost, userID: user.id, clientID: identity.clientID)
                guard !isStale(gen) else { return }
            }
            guard !isStale(gen) else { return }
            session = GitHubAuth.Session(userID: user.id, username: user.login, serverHost: config.serverHost, config: config)
            let restoredIncarnation: String? = (user.id == identity.userID) ? identity.sessionIncarnation : UUID().uuidString
            await identities.save(GitHubSessionIdentity(serverHost: config.serverHost, userID: user.id, clientID: config.clientID, username: user.login, sessionIncarnation: restoredIncarnation))
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.accountVerified(username: user.login, userID: user.id, serverHost: config.serverHost) }
            guard !isStale(gen) else { return }
            await restoreInstallations(config: config, token: record.accessToken, username: user.login, userID: user.id, generation: gen, retried: retried)
        } catch is CancellationError {
            return
        } catch let error as GitHubAuth.AuthError {
            guard !isStale(gen) else { return }
            switch error {
            case .unauthorized, .revoked:
                if keptExpiringTokenAfterRefreshFailure {
                    session = GitHubAuth.Session(userID: identity.userID, username: identity.username, serverHost: identity.serverHost, config: config)
                    await action { GitHubAuth.Action.connected(username: identity.username, serverHost: identity.serverHost, syncedAt: now()) }
                    guard !isStale(gen) else { return }
                    await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
                    return
                }
                let dead = await deleteSessionIfCurrent(serverHost: identity.serverHost, userID: identity.userID, clientID: identity.clientID, accessToken: record.accessToken)
                guard !isStale(gen) else { return }
                if !dead, !retried {
                    await restoreSession(retried: true)
                    return
                }
                await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .relogin) }
            case .patNotSupported:
                let dead = await deleteSessionIfCurrent(serverHost: identity.serverHost, userID: identity.userID, clientID: identity.clientID, accessToken: record.accessToken)
                guard !isStale(gen) else { return }
                if !dead, !retried {
                    await restoreSession(retried: true)
                    return
                }
                await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .none) }
            default:
                session = GitHubAuth.Session(userID: identity.userID, username: identity.username, serverHost: identity.serverHost, config: config)
                await action { GitHubAuth.Action.connected(username: identity.username, serverHost: identity.serverHost, syncedAt: now()) }
                guard !isStale(gen) else { return }
                await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
            }
        } catch {
            guard !isStale(gen) else { return }
            session = GitHubAuth.Session(userID: identity.userID, username: identity.username, serverHost: identity.serverHost, config: config)
            await action { GitHubAuth.Action.connected(username: identity.username, serverHost: identity.serverHost, syncedAt: now()) }
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
        }
    }

    private func restoreInstallations(config: GitHubAuth.AppConfig, token: String, username: String, userID: Int64, generation gen: Int, retried: Bool) async {
        guard !isStale(gen) else { return }
        do {
            let installations = try await api.fetchInstallations(config: config, token: token)
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.installationsLoaded(installations) }
            guard !isStale(gen) else { return }
            var reposError: String?
            if let first = installations.first {
                do {
                    let repos = try await api.fetchRepositories(config: config, token: token, installationID: first.id)
                    guard !isStale(gen) else { return }
                    await action { GitHubAuth.Action.repositoriesLoaded(installationID: first.id, repositories: repos) }
                    guard !isStale(gen) else { return }
                } catch let error as GitHubAuth.AuthError {
                    guard !isStale(gen) else { return }
                    switch error {
                    case .unauthorized, .revoked:
                        let dead = await deleteSessionIfCurrent(serverHost: config.serverHost, userID: userID, clientID: config.clientID, accessToken: token)
                        guard !isStale(gen) else { return }
                        if !dead, !retried {
                            session = nil
                            await restoreSession(retried: true)
                            return
                        }
                        session = nil
                        await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .relogin) }
                        return
                    default:
                        reposError = error.localizedDescription
                    }
                } catch {
                    guard !isStale(gen) else { return }
                    reposError = error.localizedDescription
                }
            }
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.connected(username: username, serverHost: config.serverHost, syncedAt: now()) }
            if let message = reposError {
                guard !isStale(gen) else { return }
                await action { GitHubAuth.Action.syncFailed(message: message) }
            }
        } catch is CancellationError {
            return
        } catch let error as GitHubAuth.AuthError {
            guard !isStale(gen) else { return }
            switch error {
            case .unauthorized, .revoked:
                let dead = await deleteSessionIfCurrent(serverHost: config.serverHost, userID: userID, clientID: config.clientID, accessToken: token)
                guard !isStale(gen) else { return }
                if !dead, !retried {
                    session = nil
                    await restoreSession(retried: true)
                    return
                }
                session = nil
                await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .relogin) }
            default:
                await action { GitHubAuth.Action.installationsLoaded([]) }
                guard !isStale(gen) else { return }
                await action { GitHubAuth.Action.connected(username: username, serverHost: config.serverHost, syncedAt: now()) }
                guard !isStale(gen) else { return }
                await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
            }
        } catch {
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.installationsLoaded([]) }
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.connected(username: username, serverHost: config.serverHost, syncedAt: now()) }
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
        }
    }

    private func currentToken(generation gen: Int) async throws -> (GitHubAuth.Session, String) {
        guard let sess = session else { throw GitHubAuth.AuthError.revoked }
        guard var record = await store.load(serverHost: sess.serverHost, userID: sess.userID, clientID: sess.config.clientID) else {
            throw GitHubAuth.AuthError.revoked
        }
        guard !isStale(gen) else { throw CancellationError() }
        if GitHubTokenRefresh.isExpiringSoon(record, now: now()) {
            do {
                record = try await refresher.refresh(config: sess.config, userID: sess.userID, current: record)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GitHubAuth.AuthError {
                switch error {
                case .revoked, .unauthorized, .tokenRefreshFailed:
                    throw error
                default:
                    break // Keep old token; report stale below.
                }
            }
            guard !isStale(gen) else { throw CancellationError() }
        }
        return (sess, record.accessToken)
    }

    private func refreshInstallations() async {
        let gen = generation
        guard session != nil else { return }
        let sess: GitHubAuth.Session
        let token: String
        do {
            (sess, token) = try await currentToken(generation: gen)
        } catch is CancellationError {
            return
        } catch let error as GitHubAuth.AuthError {
            guard !isStale(gen) else { return }
            switch error {
            case .revoked, .unauthorized, .tokenRefreshFailed:
                await action { GitHubAuth.Action.failed(message: GitHubAuth.AuthError.revoked.localizedDescription, retry: .relogin) }
            default:
                await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
            }
            return
        } catch {
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
            return
        }
        do {
            let installations = try await api.fetchInstallations(config: sess.config, token: token)
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.installationsLoaded(installations) }
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.syncSucceeded(now()) }
        } catch is CancellationError {
            return
        } catch let error as GitHubAuth.AuthError {
            guard !isStale(gen) else { return }
            switch error {
            case .unauthorized, .revoked:
                await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .relogin) }
            default:
                await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
            }
        } catch {
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
        }
    }

    private func selectInstallation(_ id: Int64?) async {
        let gen = generation
        await action { GitHubAuth.Action.installationSelected(id) }
        guard !isStale(gen) else { return }
        guard let id, session != nil else { return }
        let sess: GitHubAuth.Session
        let token: String
        do {
            (sess, token) = try await currentToken(generation: gen)
        } catch is CancellationError {
            return
        } catch let error as GitHubAuth.AuthError {
            guard !isStale(gen) else { return }
            switch error {
            case .revoked, .unauthorized, .tokenRefreshFailed:
                await action { GitHubAuth.Action.failed(message: GitHubAuth.AuthError.revoked.localizedDescription, retry: .relogin) }
            default:
                await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
            }
            return
        } catch {
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
            return
        }
        do {
            let repos = try await api.fetchRepositories(config: sess.config, token: token, installationID: id)
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.repositoriesLoaded(installationID: id, repositories: repos) }
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.syncSucceeded(now()) }
        } catch is CancellationError {
            return
        } catch let error as GitHubAuth.AuthError {
            guard !isStale(gen) else { return }
            switch error {
            case .unauthorized, .revoked:
                await action { GitHubAuth.Action.failed(message: error.localizedDescription, retry: .relogin) }
            default:
                await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
            }
        } catch {
            guard !isStale(gen) else { return }
            await action { GitHubAuth.Action.syncFailed(message: error.localizedDescription) }
        }
    }

    private nonisolated static func retryKind(for error: GitHubAuth.AuthError) -> GitHubAuth.RetryKind {
        switch error {
        case .denied, .codeExpired: .newCode
        case .unauthorized, .revoked, .tokenRefreshFailed: .relogin
        case .forbidden, .needsApproval, .needsInstallation: .grantAccess
        case .ssoRequired, .missingClientID, .patNotSupported: .none
        case .cancelled: .none
        case .network, .rateLimited, .slowDown, .authorizationPending: .retry
        }
    }
}
