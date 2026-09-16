import Foundation
import Testing
import Relux
@testable import RunnerControlCore

private func githubHarness(
    transport: any GitHubHTTPTransport,
    store: GitHubKeychainStore? = nil,
    identityStore: (any GitHubSessionIdentityStoring)? = nil,
    sleeper: (@Sendable (UInt64) async throws -> Void)? = nil,
    config: GitHubAuth.AppConfig = testConfig
) async -> (GitHubAuth.Flow, Relux.Testing.Logger, GitHubKeychainStore) {
    let logger = Relux.Testing.Logger()
    let dispatcher = Relux.Dispatcher(logger: logger)
    let credentialStore = store ?? GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let flow = await GitHubAuth.Flow(
        deviceFlow: GitHubDeviceFlow(transport: transport),
        api: GitHubAPIClient(transport: transport),
        refresher: GitHubTokenRefresh(transport: transport, store: credentialStore),
        store: credentialStore,
        identityStore: identityStore ?? InMemoryGitHubSessionIdentityStore(),
        configProvider: { _ in config },
        sleeper: sleeper ?? { _ in },
        dispatcher: dispatcher
    )
    return (flow, logger, credentialStore)
}

private func waitForLoggedActions(_ logger: Relux.Testing.Logger, count: Int, timeoutNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
    while ContinuousClock.now < deadline {
        if logger.actions.count >= count { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return logger.actions.count >= count
}

private func githubActions(_ logger: Relux.Testing.Logger) -> [GitHubAuth.Action] {
    logger.actions.compactMap { $0 as? GitHubAuth.Action }
}

// MARK: - Reducer

@Test @MainActor func githubReducerCoversLoginLifecycleAndIgnoresForeignActions() async {
    let state = GitHubAuth.State()
    let before = state.connection
    await state.reduce(with: ForeignAction())
    #expect(state.connection == before)
    await state.reduce(with: GitHubAuth.Action.loginStarted(serverHost: "github.com"))
    guard case .requestingCode = state.connection else { Issue.record("Expected requestingCode"); return }
    let uri = URL(string: "https://github.com/login/device")!
    await state.reduce(with: GitHubAuth.Action.codeReceived(userCode: "ABCD-1234", verificationURI: uri, expiresIn: 900, interval: 5))
    guard case .awaitingUser(let code, _, _, let interval) = state.connection, code == "ABCD-1234", interval == 5 else {
        Issue.record("Expected awaitingUser"); return
    }
    await state.reduce(with: GitHubAuth.Action.pollIntervalUpdated(10))
    guard case .awaitingUser(_, _, _, let updated) = state.connection, updated == 10 else {
        Issue.record("Expected interval 10"); return
    }
    await state.reduce(with: GitHubAuth.Action.accountVerified(username: "octo", userID: 42, serverHost: "github.com"))
    #expect(state.username == "octo")
    await state.reduce(with: GitHubAuth.Action.installationsLoaded([.init(id: 7, account: "acme", accountType: "Organization")]))
    #expect(state.selectedInstallationID == 7)
    await state.reduce(with: GitHubAuth.Action.repositoriesLoaded(installationID: 7, repositories: [.init(id: 9, fullName: "acme/app", isPrivate: true)]))
    #expect(state.repositories.count == 1)
    await state.reduce(with: GitHubAuth.Action.connected(username: "octo", serverHost: "github.com", syncedAt: Date()))
    guard case .connected = state.connection else { Issue.record("Expected connected"); return }
    await state.reduce(with: GitHubAuth.Action.syncFailed(message: "stale"))
    #expect(state.syncError == "stale")
    guard case .connected = state.connection else { Issue.record("syncFailed must preserve connected"); return }
    await state.reduce(with: GitHubAuth.Action.installationSelected(7))
    await state.reduce(with: GitHubAuth.Action.repositoriesSelected([9]))
    #expect(state.selectedRepositoryIDs == [9])
    await state.reduce(with: GitHubAuth.Action.failed(message: "denied", retry: .newCode))
    guard case .failed(_, let retry) = state.connection, retry == .newCode else { Issue.record("Expected failed newCode"); return }
    await state.reduce(with: GitHubAuth.Action.loggedOut)
    guard case .disconnected = state.connection else { Issue.record("Expected disconnected"); return }
    #expect(state.username == nil)
    await state.cleanup()
    #expect(state.installations.isEmpty)
}

// MARK: - Flow: success + 401/403 + logout

@Test func flowLoginSuccessDrivesProductionEffectsToConnected() async throws {
    let transport = TestTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": "ghu_x", "refresh_token": "ghr_y", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": [["id": 7, "account": ["login": "acme", "type": "Organization"]]]]),
        jsonResponse(["repositories": [["id": 9, "full_name": "acme/app", "private": false]]]),
    ])
    let (flow, logger, store) = await githubHarness(transport: transport)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 6))
    let actions = githubActions(logger)
    guard case .loginStarted = actions[0], case .codeReceived = actions[1] else {
        Issue.record("Login did not emit started/code, got \(actions)"); return
    }
    #expect(actions.contains { if case .connected(let user, _, _) = $0, user == "octo" { true } else { false } })
    #expect(await store.load(serverHost: "github.com", userID: 42, clientID: testConfig.clientID)?.accessToken == "ghu_x")
    // No Runners actions leak from the GitHub flow.
    #expect(logger.actions.allSatisfy { $0 is GitHubAuth.Action })
}

@Test func flowExpiredCodeFailsWithNewCode() async {
    let transport = TestTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["error": "expired_token"]),
    ])
    let (flow, logger, _) = await githubHarness(transport: transport)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 3))
    let actions = githubActions(logger)
    guard case .failed(let message, let retry) = actions.last, retry == .newCode else {
        Issue.record("Expected failed newCode, got \(actions)"); return
    }
    #expect(message.contains("expired"))
}

@Test func flowDeniedFailsWithNewCode() async {
    let transport = TestTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["error": "access_denied"]),
    ])
    let (flow, logger, _) = await githubHarness(transport: transport)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 3))
    guard case .failed(_, let retry) = githubActions(logger).last, retry == .newCode else {
        Issue.record("Expected denied newCode"); return
    }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64] = []
    func append(_ value: UInt64) { lock.withLock { values.append(value) } }
    var snapshot: [UInt64] { lock.withLock { values } }
}

@Test func flowSlowDownIncreasesIntervalThenSucceeds() async throws {
    let transport = TestTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5]),
        jsonResponse(["error": "slow_down"]),
        jsonResponse(["access_token": "ghu_x", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": []]),
    ])
    let recorder = SleepRecorder()
    let (flow, logger, _) = await githubHarness(transport: transport, sleeper: { nanos in
        recorder.append(nanos)
    })
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 5))
    let actions = githubActions(logger)
    guard actions.contains(where: { if case .pollIntervalUpdated(let value) = $0, value == 10 { true } else { false } }) else {
        Issue.record("Expected pollIntervalUpdated(10), got \(actions)"); return
    }
    let observed = recorder.snapshot
    #expect(observed.count >= 2)
    #expect(observed[0] == 5_000_000_000)
    #expect(observed[1] == 10_000_000_000)
}

@Test func flowCancellationDestroysCodeAndStopsPoll() async throws {
    // Cancel lands during the first poll sleep, so no poll consumes the queue.
    // Queue order is therefore [code1, code2, ...second-login polls].
    let transport = TestTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5]),
        jsonResponse(["device_code": "dev2", "user_code": "USER-2", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 60]),
        jsonResponse(["error": "authorization_pending"]),
        jsonResponse(["error": "authorization_pending"]),
    ])
    let (flow, logger, _) = await githubHarness(transport: transport, sleeper: { _ in
        try await Task.sleep(for: .milliseconds(200))
    })
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    _ = await waitForLoggedActions(logger, count: 2)
    _ = await flow.apply(GitHubAuth.Effect.cancelLogin)
    _ = await waitForLoggedActions(logger, count: 3)
    // Second login must request a fresh code (old device_code destroyed, not reused).
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 5))
    let actions = githubActions(logger)
    #expect(actions.contains { if case .loginCancelled = $0 { true } else { false } })
    let codes = actions.compactMap { action -> String? in if case .codeReceived(let code, _, _, _) = action { code } else { nil } }
    #expect(codes == ["USER-1", "USER-2"])
    #expect(!actions.contains { if case .connected = $0 { true } else { false } })
    _ = await flow.apply(GitHubAuth.Effect.cancelLogin)
}

@Test func flowCancelWhileConnectedRestoresConnected() async throws {
    let transport = TestTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": "ghu_x", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": []]),
    ])
    let (flow, logger, _) = await githubHarness(transport: transport)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 5))
    _ = await flow.apply(GitHubAuth.Effect.cancelLogin)
    #expect(await waitForLoggedActions(logger, count: 6))
    guard case .connected(let user, _, _) = githubActions(logger).last, user == "octo" else {
        Issue.record("Cancel while connected must restore connected, got \(githubActions(logger))"); return
    }
}

@Test func flowLogoutClearsKeychainAndStopsSync() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let transport = TestTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": "ghu_x", "refresh_token": "ghr_y", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": []]),
    ])
    let (flow, logger, credentialStore) = await githubHarness(transport: transport, store: store)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 5))
    #expect(await credentialStore.load(serverHost: "github.com", userID: 42, clientID: testConfig.clientID) != nil)
    _ = await flow.apply(GitHubAuth.Effect.logout)
    _ = await waitForLoggedActions(logger, count: 6)
    #expect(githubActions(logger).last.map { if case .loggedOut = $0 { true } else { false } } == true)
    #expect(await credentialStore.load(serverHost: "github.com", userID: 42, clientID: testConfig.clientID) == nil)
    // Post-logout refresh is a no-op (background ops stopped).
    let before = logger.actions.count
    _ = await flow.apply(GitHubAuth.Effect.refreshInstallations)
    try await Task.sleep(for: .milliseconds(100))
    #expect(logger.actions.count == before)
}

@Test func flow401DuringRefreshRequiresRelogin() async {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let record = GitHubAuth.TokenRecord(accessToken: "ghu_old", refreshToken: nil, expiresAt: nil)
    await store.saveForTest(record, userID: 42)
    let transport = TestTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": "ghu_x", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": []]),
        GitHubHTTPResponse(status: 401, body: Data()),
    ])
    let (flow, logger, _) = await githubHarness(transport: transport, store: store)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 5))
    _ = await flow.apply(GitHubAuth.Effect.refreshInstallations)
    #expect(await waitForLoggedActions(logger, count: 6))
    guard case .failed(_, let retry) = githubActions(logger).last, retry == .relogin else {
        Issue.record("Expected 401 relogin, got \(githubActions(logger))"); return
    }
}

@Test func flow403DuringRefreshKeepsConnectedWithStaleError() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let transport = TestTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": "ghu_x", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": []]),
        GitHubHTTPResponse(status: 403, body: Data("forbidden".utf8)),
    ])
    let (flow, logger, _) = await githubHarness(transport: transport, store: store)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 5))
    _ = await flow.apply(GitHubAuth.Effect.refreshInstallations)
    #expect(await waitForLoggedActions(logger, count: 6))
    let actions = githubActions(logger)
    guard case .syncFailed = actions.last else {
        Issue.record("Expected syncFailed on 403, got \(actions)"); return
    }
    // Reducer proof: syncFailed preserves connected (local control unaffected).
    let state = await MainActor.run { GitHubAuth.State() }
    for action in actions { await state.reduce(with: action) }
    let connection = await MainActor.run { state.connection }
    guard case .connected = connection else {
        Issue.record("403 must not disconnect"); return
    }
}

@Test func flowLoginPhase401DuringInstallationsRequiresRelogin() async {
    let transport = TestTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": "ghu_x", "refresh_token": "ghr_y", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        GitHubHTTPResponse(status: 401, body: Data()),
    ])
    let (flow, logger, _) = await githubHarness(transport: transport)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 4))
    guard case .failed(_, let retry) = githubActions(logger).last, retry == .relogin else {
        Issue.record("Expected login-phase 401 relogin, got \(githubActions(logger))"); return
    }
}

@Test func flowMissingClientIDFailsWithExactBinding() async {
    let logger = Relux.Testing.Logger()
    let dispatcher = Relux.Dispatcher(logger: logger)
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let transport = TestTransport([])
    let flow = await GitHubAuth.Flow(
        deviceFlow: GitHubDeviceFlow(transport: transport),
        api: GitHubAPIClient(transport: transport),
        refresher: GitHubTokenRefresh(transport: transport, store: store),
        store: store,
        identityStore: InMemoryGitHubSessionIdentityStore(),
        configProvider: { _ in throw GitHubAuth.ConfigError.missingClientID(binding: GitHubAuth.AppConfig.missingBindingHelp) },
        sleeper: { _ in },
        dispatcher: dispatcher
    )
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 1))
    guard case .failed(let message, let retry) = githubActions(logger).first, retry == .none else {
        Issue.record("Expected missing-binding failure"); return
    }
    #expect(message.contains("ios-app-manager.json"))
}

@Test func flowIgnoresForeignEffectsAndSelectsRepositories() async {
    let (flow, logger, _) = await githubHarness(transport: TestTransport([]))
    let result: Relux.ActionResult = await flow.apply(ForeignEffect())
    _ = result
    #expect(logger.actions.isEmpty)
    _ = await flow.apply(GitHubAuth.Effect.selectRepositories([9]))
    #expect(await waitForLoggedActions(logger, count: 1))
    guard case .repositoriesSelected(let ids) = githubActions(logger).first, ids == [9] else {
        Issue.record("Expected repositoriesSelected"); return
    }
}

@Test @MainActor func githubModuleRegistersStateAndFlow() async {
    let state = GitHubAuth.State()
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let transport = TestTransport([])
    let dispatcher = Relux.Dispatcher(logger: Relux.Testing.Logger())
    let flow = await GitHubAuth.Flow(
        deviceFlow: GitHubDeviceFlow(transport: transport),
        api: GitHubAPIClient(transport: transport),
        refresher: GitHubTokenRefresh(transport: transport, store: store),
        store: store,
        identityStore: InMemoryGitHubSessionIdentityStore(),
        configProvider: { _ in testConfig },
        sleeper: { _ in },
        dispatcher: dispatcher
    )
    let module = GitHubAuth.Module(state: state, flow: flow)
    #expect(module.states.count == 1)
    #expect(module.sagas.count == 1)
}

private extension GitHubKeychainStore {
    func saveForTest(_ record: GitHubAuth.TokenRecord, userID: Int64) async {
        try? await save(record, serverHost: "github.com", userID: userID, clientID: testConfig.clientID)
    }
}

// MARK: - Restore (session survives relaunch)

@Test @MainActor func githubReducerRestoreStartedShowsVerifyingAccount() async {
    let state = GitHubAuth.State()
    await state.reduce(with: GitHubAuth.Action.restoreStarted(serverHost: "ghe.example.com"))
    guard case .verifyingAccount = state.connection else {
        Issue.record("Expected verifyingAccount, got \(state.connection)"); return
    }
    #expect(state.serverHost == "ghe.example.com")
}

@Test func flowLoginPersistsSessionIdentityForLaterRestore() async throws {
    let identities = InMemoryGitHubSessionIdentityStore()
    let transport = TestTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": "ghu_x", "refresh_token": "ghr_y", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": []]),
    ])
    let (flow, logger, _) = await githubHarness(transport: transport, identityStore: identities)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 6))
    let saved = await identities.load()
    #expect(saved?.serverHost == "github.com" && saved?.userID == 42 && saved?.clientID == testConfig.clientID && saved?.username == "octo")
    #expect(saved?.sessionIncarnation?.isEmpty == false)
}

@Test func flowRestoreSessionConnectsFromPersistedIdentityThenLogoutClearsBoth() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let identities = InMemoryGitHubSessionIdentityStore(value: GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo"))
    try await store.save(
        GitHubAuth.TokenRecord(accessToken: "ghu_saved", refreshToken: "ghr_saved", expiresAt: Date().addingTimeInterval(3600)),
        serverHost: "github.com", userID: 42, clientID: testConfig.clientID
    )
    let transport = TestTransport([
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": [["id": 7, "account": ["login": "acme", "type": "Organization"]]]]),
        jsonResponse(["repositories": [["id": 9, "full_name": "acme/app", "private": false]]]),
    ])
    let (flow, logger, credentialStore) = await githubHarness(transport: transport, store: store, identityStore: identities)
    _ = await flow.apply(GitHubAuth.Effect.restoreSession)
    #expect(await waitForLoggedActions(logger, count: 5))
    let actions = githubActions(logger)
    guard case .restoreStarted = actions.first else {
        Issue.record("Expected restoreStarted first, got \(actions)"); return
    }
    #expect(actions.contains { if case .connected(let user, _, _) = $0, user == "octo" { true } else { false } })
    // Session is live: a sync now reaches the network instead of no-op.
    await transport.append(jsonResponse(["installations": []]))
    _ = await flow.apply(GitHubAuth.Effect.refreshInstallations)
    #expect(await waitForLoggedActions(logger, count: 7))
    // Logout after restore deletes both Keychain tokens and identity.
    _ = await flow.apply(GitHubAuth.Effect.logout)
    #expect(await waitForLoggedActions(logger, count: 8))
    #expect(await credentialStore.load(serverHost: "github.com", userID: 42, clientID: testConfig.clientID) == nil)
    #expect(await identities.load() == nil)
}

@Test func flowRestoreSessionWithRevokedTokenRequiresReloginAndClearsStorage() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let identities = InMemoryGitHubSessionIdentityStore(value: GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo"))
    try await store.save(
        GitHubAuth.TokenRecord(accessToken: "ghu_revoked", refreshToken: nil, expiresAt: nil),
        serverHost: "github.com", userID: 42, clientID: testConfig.clientID
    )
    let transport = TestTransport([GitHubHTTPResponse(status: 401, body: Data())])
    let (flow, logger, credentialStore) = await githubHarness(transport: transport, store: store, identityStore: identities)
    _ = await flow.apply(GitHubAuth.Effect.restoreSession)
    #expect(await waitForLoggedActions(logger, count: 2))
    guard case .failed(_, let retry) = githubActions(logger).last, retry == .relogin else {
        Issue.record("Expected 401 relogin, got \(githubActions(logger))"); return
    }
    #expect(await credentialStore.load(serverHost: "github.com", userID: 42, clientID: testConfig.clientID) == nil)
    #expect(await identities.load() == nil)
}

@Test func flowRestoreSessionWithoutIdentityIsNoop() async throws {
    let (flow, logger, _) = await githubHarness(transport: TestTransport([]))
    _ = await flow.apply(GitHubAuth.Effect.restoreSession)
    try await Task.sleep(for: .milliseconds(100))
    #expect(logger.actions.isEmpty)
}

// MARK: - Refresh through the production Flow path

private func loginQueue(accessToken: String = "ghu_old", refreshToken: String = "ghr_old") -> [GitHubHTTPResponse] {
    [
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": accessToken, "refresh_token": refreshToken, "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": []]),
    ]
}

@Test func flowRefreshInstallationsRefreshesExpiringTokenViaProductionPath() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let transport = TestTransport(loginQueue())
    let (flow, logger, credentialStore) = await githubHarness(transport: transport, store: store)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 6))
    // Age the stored token into the 60s refresh window.
    try await credentialStore.save(
        GitHubAuth.TokenRecord(accessToken: "ghu_old", refreshToken: "ghr_old", expiresAt: Date().addingTimeInterval(30)),
        serverHost: "github.com", userID: 42, clientID: testConfig.clientID
    )
    await transport.append(jsonResponse(["access_token": "ghu_new", "refresh_token": "ghr_new", "expires_in": 3600]))
    await transport.append(jsonResponse(["installations": [["id": 7, "account": ["login": "acme", "type": "Organization"]]]]))
    _ = await flow.apply(GitHubAuth.Effect.refreshInstallations)
    #expect(await waitForLoggedActions(logger, count: 8))
    let tokenPosts = await transport.requests.filter { $0.url == testConfig.tokenURL }
    #expect(tokenPosts.count == 2) // 1 device poll during login + 1 refresh here
    #expect(await credentialStore.load(serverHost: "github.com", userID: 42, clientID: testConfig.clientID)?.accessToken == "ghu_new")
    #expect(githubActions(logger).contains { if case .syncSucceeded = $0 { true } else { false } })
}

@Test func flowRefreshInstallationsWithInvalidGrantDuringRefreshRequiresRelogin() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let transport = TestTransport(loginQueue())
    let (flow, logger, _) = await githubHarness(transport: transport, store: store)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 6))
    let expiring = GitHubAuth.TokenRecord(accessToken: "ghu_old", refreshToken: "ghr_bad", expiresAt: Date().addingTimeInterval(30))
    await store.saveForTest(expiring, userID: 42)
    await transport.append(jsonResponse(["error": "invalid_grant"]))
    _ = await flow.apply(GitHubAuth.Effect.refreshInstallations)
    #expect(await waitForLoggedActions(logger, count: 7))
    guard case .failed(_, let retry) = githubActions(logger).last, retry == .relogin else {
        Issue.record("Expected invalid_grant relogin, got \(githubActions(logger))"); return
    }
}

actor RoutingTransport: GitHubHTTPTransport {
    private(set) var requests: [GitHubHTTPRequest] = []
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        requests.append(request)
        let path = request.url.path
        if request.method == "POST", path.hasSuffix("/login/device/code") {
            return jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1])
        }
        if request.method == "POST", path.hasSuffix("/login/oauth/access_token") {
            if let body = request.body,
               let obj = try? JSONSerialization.jsonObject(with: body) as? [String: String],
               obj["grant_type"] == "refresh_token" {
                return jsonResponse(["access_token": "ghu_new", "refresh_token": "ghr_new", "expires_in": 3600])
            }
            return jsonResponse(["access_token": "ghu_old", "refresh_token": "ghr_old", "expires_in": 3600])
        }
        if path == "/user" { return jsonResponse(["login": "octo", "id": 42]) }
        if path == "/user/installations" {
            return jsonResponse(["installations": [["id": 7, "account": ["login": "acme", "type": "Organization"]]]])
        }
        if path.hasSuffix("/repositories") {
            return jsonResponse(["repositories": [["id": 9, "full_name": "acme/app", "private": false]]])
        }
        throw GitHubTransportError.invalidResponse
    }
}

@Test func flowConcurrentRefreshAndSelectCoalesceToSingleRefresh() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let transport = RoutingTransport()
    let (flow, logger, credentialStore) = await githubHarness(transport: transport, store: store)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    #expect(await waitForLoggedActions(logger, count: 6))
    try await credentialStore.save(
        GitHubAuth.TokenRecord(accessToken: "ghu_old", refreshToken: "ghr_old", expiresAt: Date().addingTimeInterval(30)),
        serverHost: "github.com", userID: 42, clientID: testConfig.clientID
    )
    async let first = flow.apply(GitHubAuth.Effect.refreshInstallations)
    async let second = flow.apply(GitHubAuth.Effect.selectInstallation(7))
    _ = await (first, second)
    #expect(await waitForLoggedActions(logger, count: 11))
    let all = await transport.requests
    let refreshGrants = all.filter {
        guard $0.url.path.hasSuffix("/login/oauth/access_token"), let body = $0.body else { return false }
        return (try? JSONSerialization.jsonObject(with: body) as? [String: String])?["grant_type"] == "refresh_token"
    }
    #expect(refreshGrants.count == 1)
    #expect(await credentialStore.load(serverHost: "github.com", userID: 42, clientID: testConfig.clientID)?.accessToken == "ghu_new")
    let actions = githubActions(logger)
    #expect(actions.contains { if case .repositoriesLoaded(let id, _) = $0, id == 7 { true } else { false } })
    #expect(actions.filter { if case .syncSucceeded = $0 { true } else { false } }.count == 2)
}
