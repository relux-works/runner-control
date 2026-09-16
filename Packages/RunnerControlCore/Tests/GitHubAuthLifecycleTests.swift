import Foundation
import Testing
import Relux
@testable import RunnerControlCore

/// Transport that delays every response so a logout can interleave with an in-flight call.
actor SlowTransport: GitHubHTTPTransport {
    private var queue: [GitHubHTTPResponse]
    private(set) var requests: [GitHubHTTPRequest] = []
    let delayMs: Int
    init(_ responses: [GitHubHTTPResponse], delayMs: Int) { self.queue = responses; self.delayMs = delayMs }
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        requests.append(request)
        try? await Task.sleep(for: .milliseconds(delayMs))
        guard !queue.isEmpty else { throw GitHubTransportError.invalidResponse }
        return queue.removeFirst()
    }
}

private func attackHarness(transport: any GitHubHTTPTransport, store: GitHubKeychainStore, identities: any GitHubSessionIdentityStoring) async -> (GitHubAuth.Flow, Relux.Testing.Logger) {
    let logger = Relux.Testing.Logger()
    let dispatcher = Relux.Dispatcher(logger: logger)
    let flow = await GitHubAuth.Flow(
        deviceFlow: GitHubDeviceFlow(transport: transport),
        api: GitHubAPIClient(transport: transport),
        refresher: GitHubTokenRefresh(transport: transport, store: store),
        store: store, identityStore: identities,
        configProvider: { _ in testConfig }, sleeper: { _ in }, dispatcher: dispatcher)
    return (flow, logger)
}

private func names(_ logger: Relux.Testing.Logger) -> [String] {
    logger.actions.compactMap { $0 as? GitHubAuth.Action }.map { String(describing: $0).components(separatedBy: "(")[0] }
}

// RA1: logout while restoreSession is awaiting /user must not revive the session afterwards.
@Test func reviewerLogoutDuringRestoreDoesNotReviveSession() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let identities = InMemoryGitHubSessionIdentityStore(value: GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo"))
    let savedRecord = GitHubAuth.TokenRecord(
        accessToken: "ghu_saved", refreshToken: "ghr_saved", expiresAt: Date().addingTimeInterval(3600))
    try await store.save(savedRecord, serverHost: "github.com", userID: 42, clientID: testConfig.clientID)
    let transport = SlowTransport([
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": []]),
    ], delayMs: 300)
    let (flow, logger) = await attackHarness(transport: transport, store: store, identities: identities)
    let restore = Task { _ = await flow.apply(GitHubAuth.Effect.restoreSession) }
    try await Task.sleep(for: .milliseconds(100))
    _ = await flow.apply(GitHubAuth.Effect.logout)
    _ = await restore.value
    try await Task.sleep(for: .milliseconds(200))
    let seq = names(logger)
    print("RA1 sequence:", seq)
    let loggedOutIdx = seq.lastIndex(of: "loggedOut") ?? -1
    let afterLogout = Array(seq.suffix(from: loggedOutIdx + 1))
    #expect(!afterLogout.contains("connected"), "restore revived session after logout: \(afterLogout)")
    #expect(!afterLogout.contains("accountVerified"), "restore verified account after logout: \(afterLogout)")
    // Session must be gone: a sync now is a no-op.
    let before = logger.actions.count
    _ = await flow.apply(GitHubAuth.Effect.refreshInstallations)
    try await Task.sleep(for: .milliseconds(100))
    #expect(logger.actions.count == before, "refresh after logout still had a session: \(names(logger))")
    #expect(await identities.load() == nil)
}

// RA2: logout while refreshInstallations is awaiting /user/installations must not emit sync results afterwards.
@Test func reviewerLogoutDuringRefreshDoesNotEmitSyncAfterLoggedOut() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let identities = InMemoryGitHubSessionIdentityStore()
    let transport = SlowTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": "ghu_x", "refresh_token": "ghr_y", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": []]),
        jsonResponse(["installations": [["id": 7, "account": ["login": "acme", "type": "Organization"]]]]),
    ], delayMs: 150)
    let (flow, logger) = await attackHarness(transport: transport, store: store, identities: identities)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline, !names(logger).contains("connected") { try await Task.sleep(for: .milliseconds(20)) }
    #expect(names(logger).contains("connected"))
    let refresh = Task { _ = await flow.apply(GitHubAuth.Effect.refreshInstallations) }
    try await Task.sleep(for: .milliseconds(50))
    _ = await flow.apply(GitHubAuth.Effect.logout)
    _ = await refresh.value
    try await Task.sleep(for: .milliseconds(100))
    let seq = names(logger)
    print("RA2 sequence:", seq)
    let loggedOutIdx = seq.lastIndex(of: "loggedOut") ?? -1
    let afterLogout = Array(seq.suffix(from: loggedOutIdx + 1))
    #expect(afterLogout.isEmpty, "actions after loggedOut: \(afterLogout)")
}

// RA3: beginLogin while restoreSession is in flight must not have restore clobber the login state.
@Test func reviewerLoginDuringRestoreIsNotClobberedByRestore() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let identities = InMemoryGitHubSessionIdentityStore(value: GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo"))
    let savedRecord = GitHubAuth.TokenRecord(
        accessToken: "ghu_saved", refreshToken: "ghr_saved", expiresAt: Date().addingTimeInterval(3600))
    try await store.save(savedRecord, serverHost: "github.com", userID: 42, clientID: testConfig.clientID)
    let transport = SlowTransport([
        jsonResponse(["login": "octo", "id": 42]),                       // restore: /user (slow)
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]), // login: device code
        jsonResponse(["installations": []]),                             // restore: installations
        jsonResponse(["error": "authorization_pending"]),
    ], delayMs: 200)
    let (flow, logger) = await attackHarness(transport: transport, store: store, identities: identities)
    let restore = Task { _ = await flow.apply(GitHubAuth.Effect.restoreSession) }
    try await Task.sleep(for: .milliseconds(50))
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    _ = await restore.value
    try await Task.sleep(for: .milliseconds(600))
    let seq = names(logger)
    print("RA3 sequence:", seq)
    let codeIdx = seq.lastIndex(of: "codeReceived") ?? -1
    let afterCode = Array(seq.suffix(from: codeIdx + 1)).filter { $0 == "connected" || $0 == "accountVerified" }
    #expect(afterCode.isEmpty, "restore emitted \(afterCode) after login codeReceived")
    _ = await flow.apply(GitHubAuth.Effect.cancelLogin)
}

// RA4: logout while a token refresh is awaiting the network must leave no
// refreshed tokens behind: the in-flight refresh is cancelled before its save.
@Test func reviewerLogoutDuringRefreshLeavesNoTokensBehind() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let identities = InMemoryGitHubSessionIdentityStore()
    let transport = SlowTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": "ghu_old", "refresh_token": "ghr_old", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": []]),
        jsonResponse(["access_token": "ghu_new", "refresh_token": "ghr_new", "expires_in": 3600]),
    ], delayMs: 100)
    let (flow, logger) = await attackHarness(transport: transport, store: store, identities: identities)
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline, !names(logger).contains("connected") { try await Task.sleep(for: .milliseconds(20)) }
    #expect(names(logger).contains("connected"))
    try await store.save(
        GitHubAuth.TokenRecord(accessToken: "ghu_old", refreshToken: "ghr_old", expiresAt: Date().addingTimeInterval(30)),
        serverHost: "github.com", userID: 42, clientID: testConfig.clientID
    )
    let refresh = Task { _ = await flow.apply(GitHubAuth.Effect.refreshInstallations) }
    try await Task.sleep(for: .milliseconds(50))
    _ = await flow.apply(GitHubAuth.Effect.logout)
    _ = await refresh.value
    try await Task.sleep(for: .milliseconds(300))
    let seq = names(logger)
    print("RA4 sequence:", seq)
    let loggedOutIdx = seq.lastIndex(of: "loggedOut") ?? -1
    let afterLogout = Array(seq.suffix(from: loggedOutIdx + 1))
    #expect(afterLogout.isEmpty, "actions after loggedOut: \(afterLogout)")
    #expect(await store.load(serverHost: "github.com", userID: 42, clientID: testConfig.clientID) == nil)
    #expect(await identities.load() == nil)
}

// Helper-level proof: cancelling the in-flight refresh surfaces
// CancellationError and never writes the refreshed record.
@Test func refreshCancelInFlightNeverSavesRefreshedRecord() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let old = GitHubAuth.TokenRecord(accessToken: "ghu_old", refreshToken: "ghr_old", expiresAt: Date().addingTimeInterval(30))
    try await store.save(old, serverHost: "github.com", userID: 42, clientID: testConfig.clientID)
    let transport = SlowTransport([jsonResponse(["access_token": "ghu_new", "refresh_token": "ghr_new", "expires_in": 3600])], delayMs: 300)
    let refresher = GitHubTokenRefresh(transport: transport, store: store)
    let attempt = Task { try await refresher.refresh(config: testConfig, userID: 42, current: old) }
    try await Task.sleep(for: .milliseconds(100))
    await refresher.cancelInFlight()
    do {
        _ = try await attempt.value
        Issue.record("Cancelled refresh unexpectedly succeeded")
    } catch is CancellationError {
        // Expected.
    }
    #expect(await store.load(serverHost: "github.com", userID: 42, clientID: testConfig.clientID)?.accessToken == "ghu_old")
}

// A 401 right after an unrefreshed expiring token blames the expired access
// token, not the refresh token: storage is kept for a later retry.
@Test func flowRestoreWithFailedRefreshThen401KeepsTokensAndStaysStale() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let identities = InMemoryGitHubSessionIdentityStore(value: GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo"))
    try await store.save(
        GitHubAuth.TokenRecord(accessToken: "ghu_expired", refreshToken: "ghr_valid", expiresAt: Date().addingTimeInterval(30)),
        serverHost: "github.com", userID: 42, clientID: testConfig.clientID
    )
    let transport = TestTransport([
        GitHubHTTPResponse(status: 500, body: Data("boom".utf8)),
        GitHubHTTPResponse(status: 401, body: Data()),
    ])
    let (flow, logger) = await attackHarness(transport: transport, store: store, identities: identities)
    _ = await flow.apply(GitHubAuth.Effect.restoreSession)
    try await Task.sleep(for: .milliseconds(200))
    let seq = names(logger)
    print("Heuristic sequence:", seq)
    #expect(seq.contains("connected"))
    #expect(seq.contains("syncFailed"))
    #expect(!seq.contains("failed"))
    #expect(await store.load(serverHost: "github.com", userID: 42, clientID: testConfig.clientID)?.refreshToken == "ghr_valid")
    #expect(await identities.load() != nil)
}

// Revoked session surfaces relogin from selectInstallation, matching refresh.
@Test func flowSelectInstallationWithRevokedTokenRequiresRelogin() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let transport = TestTransport([
        jsonResponse(["device_code": "dev1", "user_code": "USER-1", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": "ghu_x", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": [["id": 7, "account": ["login": "acme", "type": "Organization"]]]]),
        jsonResponse(["repositories": [["id": 9, "full_name": "acme/app", "private": false]]]),
    ])
    let (flow, logger) = await attackHarness(transport: transport, store: store, identities: InMemoryGitHubSessionIdentityStore())
    _ = await flow.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline, !names(logger).contains("connected") { try await Task.sleep(for: .milliseconds(20)) }
    #expect(names(logger).contains("connected"))
    await store.delete(serverHost: "github.com", userID: 42, clientID: testConfig.clientID)
    _ = await flow.apply(GitHubAuth.Effect.selectInstallation(7))
    try await Task.sleep(for: .milliseconds(200))
    let actions = logger.actions.compactMap { $0 as? GitHubAuth.Action }
    guard case .failed(_, let retry) = actions.last, retry == .relogin else {
        Issue.record("Expected revoked select to require relogin, got \(names(logger))"); return
    }
}

@Test func userDefaultsSessionIdentityStoreRoundTrips() async throws {
    let suiteName = "works.relux.runnercontrol.test.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Could not create test UserDefaults suite"); return
    }
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsGitHubSessionIdentityStore(defaults: defaults)
    #expect(await store.load() == nil)
    let identity = GitHubSessionIdentity(serverHost: "ghe.example.com", userID: 7, clientID: "pub", username: "octo")
    await store.save(identity)
    #expect(await store.load() == identity)
    await store.delete()
    #expect(await store.load() == nil)
}
