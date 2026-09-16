import Foundation
import Testing
@testable import RunnerControlCore

// MARK: - Shared fakes

actor TestTransport: GitHubHTTPTransport {
    private var queue: [GitHubHTTPResponse]
    private(set) var requests: [GitHubHTTPRequest] = []
    init(_ responses: [GitHubHTTPResponse]) { self.queue = responses }
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        requests.append(request)
        guard !queue.isEmpty else { throw GitHubTransportError.invalidResponse }
        return queue.removeFirst()
    }
    func prepend(_ response: GitHubHTTPResponse) { queue.insert(response, at: 0) }
    func append(_ response: GitHubHTTPResponse) { queue.append(response) }
}

func jsonResponse(_ object: Any, status: Int = 200) -> GitHubHTTPResponse {
    // Static test literals always serialize.
    // swiftlint:disable:next force_try
    let data = try! JSONSerialization.data(withJSONObject: object)
    return GitHubHTTPResponse(status: status, body: data)
}

let testConfig = GitHubAuth.AppConfig(clientID: "test-client-id")

// MARK: - Config

@Test func configReportsExactMissingBinding() {
    let bundle = Bundle.main
    // Production bundle has no GitHubAppClientID until coordinator provisions it.
    // Assert the thrown binding names the exact scaffold input.
    let raw = bundle.object(forInfoDictionaryKey: "GitHubAppClientID") as? String
    if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        // Provisioned environment: config must load.
        #expect((try? GitHubAuth.AppConfig.current(bundle: bundle)) != nil)
    } else {
        do {
            _ = try GitHubAuth.AppConfig.current(bundle: bundle)
            Issue.record("Expected missingClientID when plist key is absent/empty")
        } catch let error as GitHubAuth.ConfigError {
            guard case .missingClientID(let binding) = error else {
                Issue.record("Wrong config error: \(error)"); return
            }
            #expect(binding == GitHubAuth.AppConfig.missingBindingHelp)
            #expect(binding.contains("ios-app-manager.json"))
            #expect(binding.contains("GitHubAppClientID"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func configAuditRunsThroughCurrentBundle() throws {
    func bundleWithPlist(_ plist: [String: Any]) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AuditProbe-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Info.plist"))
        guard let bundle = Bundle(path: dir.path) else { throw GitHubTransportError.invalidResponse }
        return bundle
    }
    let tainted = try bundleWithPlist(["GitHubAppClientID": "pub-id", "ClientSecret": "shh"])
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: tainted.bundlePath)) }
    do {
        _ = try GitHubAuth.AppConfig.current(bundle: tainted)
        Issue.record("current(bundle:) admitted embedded ClientSecret")
    } catch let error as GitHubAuth.ConfigError {
        guard case .embeddedSecret(let key) = error, key == "ClientSecret" else {
            Issue.record("Wrong audit error: \(error)"); return
        }
    }
    let clean = try bundleWithPlist(["GitHubAppClientID": "pub-id"])
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: clean.bundlePath)) }
    #expect(try GitHubAuth.AppConfig.current(bundle: clean).clientID == "pub-id")
}

@Test func enterpriseConfigUsesHostScopedEndpoints() {
    let config = GitHubAuth.AppConfig(clientID: "pub", serverHost: "ghe.example.com")
    #expect(config.deviceAuthorizationURL.absoluteString == "https://ghe.example.com/login/device/code")
    #expect(config.tokenURL.absoluteString == "https://ghe.example.com/login/oauth/access_token")
    #expect(config.apiBaseURL.absoluteString == "https://ghe.example.com/api/v3")
}

@Test func auditRejectsEmbeddedSecrets() throws {
    try GitHubAuth.AppConfig.auditNoSecrets(in: ["GitHubAppClientID": "pub", "CFBundleIdentifier": "x"])
    for key in ["ClientSecret", "client_secret", "AppPrivateKey", "app_private_key", "GitHubToken", "access_token_cache"] {
        do {
            try GitHubAuth.AppConfig.auditNoSecrets(in: [key: "value"])
            Issue.record("auditNoSecrets admitted forbidden key '\(key)'")
        } catch let error as GitHubAuth.ConfigError {
            guard case .embeddedSecret(let found) = error, found == key else {
                Issue.record("Wrong audit error for '\(key)': \(error)"); return
            }
        }
    }
}

// MARK: - PAT guard (no PAT fallback)

@Test func patGuardRejectsClassicAndFineGrainedPAT() {
    for pat in ["ghp_abc123", "github_pat_abc123"] {
        do {
            _ = try GitHubAuth.PATGuard.authorizationHeader(token: pat)
            Issue.record("PATGuard admitted PAT '\(pat)'")
        } catch let error as GitHubAuth.AuthError {
            #expect(error == .patNotSupported)
        } catch {
            Issue.record("Unexpected error for '\(pat)': \(error)")
        }
    }
    #expect((try? GitHubAuth.PATGuard.authorizationHeader(token: "ghu_deviceflowtoken")) == "Bearer ghu_deviceflowtoken")
}

// MARK: - REST mapper (401/403)

@Test func restMapperSeparatesUnauthorizedForbiddenSSORateLimit() {
    #expect(GitHubAuth.RESTMapper.map(status: 401, body: Data()) == .unauthorized)
    #expect(GitHubAuth.RESTMapper.map(status: 429, body: Data()) == .rateLimited(retryAfter: nil))
    let sso = GitHubAuth.RESTMapper.map(status: 403, body: Data("SAML SSO required".utf8))
    #expect(sso == .ssoRequired)
    let rate = GitHubAuth.RESTMapper.map(status: 403, body: Data("API rate limit exceeded".utf8))
    #expect(rate == .rateLimited(retryAfter: nil))
    let forbidden = GitHubAuth.RESTMapper.map(status: 403, body: Data("Resource not accessible".utf8))
    guard case .forbidden = forbidden else {
        Issue.record("Expected forbidden, got \(String(describing: forbidden))"); return
    }
    #expect(GitHubAuth.RESTMapper.map(status: 200, body: Data()) == nil)
    #expect(GitHubAuth.RESTMapper.map(status: 500, body: Data()) == nil)
}

// MARK: - Redaction

@Test func redactionScrubsExactSecretsAndJSONShapes() {
    let token = "ghu_secret123"
    let refresh = "ghr_refresh456"
    let text = #"{"access_token":"ghu_secret123","refresh_token":"ghr_refresh456","device_code":"dev789","other":"keep"}"#
    let clean = GitHubAuth.Redaction.sanitize(text, secrets: [token, refresh])
    #expect(!clean.contains(token))
    #expect(!clean.contains(refresh))
    #expect(!clean.contains("dev789"))
    #expect(clean.contains("keep"))
    #expect(clean.contains("[REDACTED]"))
    let inline = GitHubAuth.Redaction.sanitize("Bearer \(token) tail", secrets: [token])
    #expect(inline == "Bearer [REDACTED] tail")
}

// MARK: - Device Flow transport

@Test func deviceCodeRequestDecodesAndPostsClientID() async throws {
    let transport = TestTransport([jsonResponse([
        "device_code": "dev", "user_code": "USER-1",
        "verification_uri": "https://github.com/login/device",
        "expires_in": 900, "interval": 5,
    ])])
    let flow = GitHubDeviceFlow(transport: transport)
    let response = try await flow.requestCode(config: testConfig)
    #expect(response.user_code == "USER-1")
    #expect(response.interval == 5)
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests[0].url == testConfig.deviceAuthorizationURL)
    let body = try JSONDecoder().decode([String: String].self, from: requests[0].body!)
    #expect(body["client_id"] == "test-client-id")
    #expect(body["client_secret"] == nil)
}

@Test func devicePollMapsAllTerminalBodiesOnHTTP200() async throws {
    for (payload, expected) in [
        (["error": "authorization_pending"], GitHubAuth.PollResult.pending),
        (["error": "slow_down"], GitHubAuth.PollResult.slowDown),
        (["error": "access_denied"], GitHubAuth.PollResult.denied),
        (["error": "expired_token"], GitHubAuth.PollResult.expired),
    ] as [([String: String], GitHubAuth.PollResult)] {
        let transport = TestTransport([jsonResponse(payload)])
        let flow = GitHubDeviceFlow(transport: transport)
        #expect(try await flow.pollOnce(config: testConfig, deviceCode: "dev") == expected)
    }
    let ok = TestTransport([jsonResponse(["access_token": "ghu_x", "refresh_token": "ghr_y", "expires_in": 3600])])
    let result = try await GitHubDeviceFlow(transport: ok).pollOnce(config: testConfig, deviceCode: "dev")
    #expect(result == .success(accessToken: "ghu_x", refreshToken: "ghr_y", expiresIn: 3600))
}

@Test func devicePollRejectsPATShapedToken() async {
    let transport = TestTransport([jsonResponse(["access_token": "ghp_injected"])])
    do {
        _ = try await GitHubDeviceFlow(transport: transport).pollOnce(config: testConfig, deviceCode: "dev")
        Issue.record("pollOnce admitted PAT-shaped token")
    } catch let error as GitHubAuth.AuthError {
        #expect(error == .patNotSupported)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func slowDownAddsFiveSeconds() {
    #expect(GitHubDeviceFlow.nextInterval(current: 5, after: .slowDown) == 10)
    #expect(GitHubDeviceFlow.nextInterval(current: 5, after: .pending) == 5)
    #expect(GitHubDeviceFlow.nextInterval(current: 10, after: .slowDown) == 15)
}

// MARK: - API client

@Test func apiClientSendsBearerAndDecodesUser() async throws {
    let transport = TestTransport([jsonResponse(["login": "octo", "id": 42])])
    let user = try await GitHubAPIClient(transport: transport).fetchUser(config: testConfig, token: "ghu_x")
    #expect(user.login == "octo")
    #expect(user.id == 42)
    let requests = await transport.requests
    #expect(requests[0].headers["Authorization"] == "Bearer ghu_x")
}

@Test func apiClientRefusesPATWithoutNetwork() async {
    let transport = TestTransport([jsonResponse(["login": "x", "id": 1])])
    do {
        _ = try await GitHubAPIClient(transport: transport).fetchUser(config: testConfig, token: "ghp_abc")
        Issue.record("fetchUser admitted PAT")
    } catch let error as GitHubAuth.AuthError {
        #expect(error == .patNotSupported)
    } catch {
        Issue.record("Unexpected: \(error)")
    }
    #expect(await transport.requests.count == 0)
}

@Test func apiClientMaps401And403() async {
    let unauth = TestTransport([GitHubHTTPResponse(status: 401, body: Data())])
    do {
        _ = try await GitHubAPIClient(transport: unauth).fetchInstallations(config: testConfig, token: "ghu_x")
        Issue.record("Expected unauthorized")
    } catch let error as GitHubAuth.AuthError {
        #expect(error == .unauthorized)
    } catch { Issue.record("Unexpected: \(error)") }

    let forbidden = TestTransport([GitHubHTTPResponse(status: 403, body: Data("forbidden".utf8))])
    do {
        _ = try await GitHubAPIClient(transport: forbidden).fetchInstallations(config: testConfig, token: "ghu_x")
        Issue.record("Expected forbidden")
    } catch let error as GitHubAuth.AuthError {
        guard case .forbidden = error else { Issue.record("Expected forbidden, got \(error)"); return }
    } catch { Issue.record("Unexpected: \(error)") }
}

@Test func apiClientDecodesInstallationsAndRepositories() async throws {
    let transport = TestTransport([
        jsonResponse(["installations": [["id": 7, "account": ["login": "acme", "type": "Organization"]]]]),
        jsonResponse(["repositories": [["id": 9, "full_name": "acme/app", "private": true]]]),
    ])
    let api = GitHubAPIClient(transport: transport)
    let installs = try await api.fetchInstallations(config: testConfig, token: "ghu_x")
    #expect(installs == [.init(id: 7, account: "acme", accountType: "Organization")])
    let repos = try await api.fetchRepositories(config: testConfig, token: "ghu_x", installationID: 7)
    #expect(repos == [.init(id: 9, fullName: "acme/app", isPrivate: true)])
}

// MARK: - Token refresh

@Test func refreshSavesAtomicallyAndCoalescesConcurrentCallers() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let current = GitHubAuth.TokenRecord(accessToken: "ghu_old", refreshToken: "ghr_old", expiresAt: Date().addingTimeInterval(-10))
    try await store.save(current, serverHost: "github.com", userID: 1, clientID: testConfig.clientID)
    // Two identical success payloads available; coalescing must consume exactly one.
    let transport = TestTransport([
        jsonResponse(["access_token": "ghu_new", "refresh_token": "ghr_new", "expires_in": 3600]),
        jsonResponse(["access_token": "ghu_new", "refresh_token": "ghr_new", "expires_in": 3600]),
    ])
    let refresher = GitHubTokenRefresh(transport: transport, store: store)
    async let first = refresher.refresh(config: testConfig, userID: 1, current: current)
    async let second = refresher.refresh(config: testConfig, userID: 1, current: current)
    let (firstResult, secondResult) = try await (first, second)
    #expect(firstResult.accessToken == "ghu_new")
    #expect(secondResult.accessToken == "ghu_new")
    #expect(await transport.requests.count == 1)
    let stored = await store.load(serverHost: "github.com", userID: 1, clientID: testConfig.clientID)
    #expect(stored?.accessToken == "ghu_new")
    #expect(stored?.refreshToken == "ghr_new")
}

@Test func refreshRejectsFineGrainedPATWithoutSaving() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let current = GitHubAuth.TokenRecord(accessToken: "ghu_old", refreshToken: "ghr_old", expiresAt: nil)
    try await store.save(current, serverHost: "github.com", userID: 1, clientID: testConfig.clientID)
    let transport = TestTransport([jsonResponse(["access_token": "github_pat_fine123", "refresh_token": "ghr_new", "expires_in": 3600])])
    do {
        _ = try await GitHubTokenRefresh(transport: transport, store: store).refresh(config: testConfig, userID: 1, current: current)
        Issue.record("refresh admitted github_pat_ token")
    } catch let error as GitHubAuth.AuthError {
        #expect(error == .patNotSupported)
    } catch {
        Issue.record("Unexpected: \(error)")
    }
    #expect(await store.load(serverHost: "github.com", userID: 1, clientID: testConfig.clientID)?.accessToken == "ghu_old")
    #expect(await transport.requests.count == 1)
}

@Test func refreshFailsClosedWithoutRefreshToken() async {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let current = GitHubAuth.TokenRecord(accessToken: "ghu_old", refreshToken: nil, expiresAt: nil)
    let refresher = GitHubTokenRefresh(transport: TestTransport([]), store: store)
    do {
        _ = try await refresher.refresh(config: testConfig, userID: 1, current: current)
        Issue.record("Expected tokenRefreshFailed")
    } catch let error as GitHubAuth.AuthError {
        #expect(error == .tokenRefreshFailed)
    } catch { Issue.record("Unexpected: \(error)") }
}

@Test func refreshMapsInvalidGrantToRevoked() async throws {
    let store = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let current = GitHubAuth.TokenRecord(accessToken: "ghu_old", refreshToken: "ghr_bad", expiresAt: nil)
    try await store.save(current, serverHost: "github.com", userID: 1, clientID: testConfig.clientID)
    let transport = TestTransport([jsonResponse(["error": "invalid_grant"])])
    do {
        _ = try await GitHubTokenRefresh(transport: transport, store: store).refresh(config: testConfig, userID: 1, current: current)
        Issue.record("Expected revoked")
    } catch let error as GitHubAuth.AuthError {
        #expect(error == .revoked)
    } catch { Issue.record("Unexpected: \(error)") }
}

// MARK: - Keychain

@Test func keychainRoundTripsAndDeletesScopedRecords() async throws {
    let store = GitHubKeychainStore(service: "works.relux.runnercontrol.test.\(UUID().uuidString)", backend: InMemoryKeychainBackend())
    let record = GitHubAuth.TokenRecord(accessToken: "ghu_a", refreshToken: "ghr_b", expiresAt: Date())
    try await store.save(record, serverHost: "github.com", userID: 11, clientID: "cid")
    #expect(await store.load(serverHost: "github.com", userID: 11, clientID: "cid") == record)
    #expect(await store.load(serverHost: "github.com", userID: 12, clientID: "cid") == nil)
    await store.delete(serverHost: "github.com", userID: 11, clientID: "cid")
    #expect(await store.load(serverHost: "github.com", userID: 11, clientID: "cid") == nil)
}

@Test func keychainDeleteAllSweepsOnlyMatchingClient() async throws {
    let store = GitHubKeychainStore(service: "works.relux.runnercontrol.test.\(UUID().uuidString)", backend: InMemoryKeychainBackend())
    let record = GitHubAuth.TokenRecord(accessToken: "ghu_a", refreshToken: nil, expiresAt: nil)
    try await store.save(record, serverHost: "github.com", userID: 1, clientID: "cid-a")
    try await store.save(record, serverHost: "github.com", userID: 2, clientID: "cid-a")
    try await store.save(record, serverHost: "github.com", userID: 1, clientID: "cid-b")
    await store.deleteAll(serverHost: "github.com", clientID: "cid-a")
    #expect(await store.load(serverHost: "github.com", userID: 1, clientID: "cid-a") == nil)
    #expect(await store.load(serverHost: "github.com", userID: 2, clientID: "cid-a") == nil)
    #expect(await store.load(serverHost: "github.com", userID: 1, clientID: "cid-b") != nil)
}

@Test func realKeychainBackendRoundTripsUniqueRecord() throws {
    // Focused real-Security check with a unique service/account; always cleaned up.
    let backend = SecurityKeychainBackend()
    let service = "works.relux.runnercontrol.test.\(UUID().uuidString)"
    let account = "github.com:999:\(UUID().uuidString)"
    let data = Data("{\"accessToken\":\"ghu_probe\"}".utf8)
    defer { backend.delete(service: service, account: account) }
    try backend.save(data, service: service, account: account)
    #expect(backend.load(service: service, account: account) == data)
    backend.delete(service: service, account: account)
    #expect(backend.load(service: service, account: account) == nil)
}
