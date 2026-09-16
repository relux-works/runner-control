
private actor ReviewR3ReloginTransport: GitHubHTTPTransport {
    let base: TestTransport
    let auth: GitHubAuth.Flow
    let authLogger: Relux.Testing.Logger
    let method: String
    private var fired = false
    init(base: TestTransport, auth: GitHubAuth.Flow, logger: Relux.Testing.Logger, method: String) {
        self.base = base; self.auth = auth; self.authLogger = logger; self.method = method
    }
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        let result = try await base.send(request)
        if request.method == method && !fired {
            fired = true
            _ = await auth.apply(GitHubAuth.Effect.logout)
            _ = await auth.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if authLogger.actions.contains(where: {
                    guard let a = $0 as? GitHubAuth.Action else { return false }
                    if case .connected = a { return true }; return false
                }) { return result }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("Real auth flow failed to finish same-account re-login")
        }
        return result
    }
}

private func reviewR3ReloginFlow(_ h: CatalogHarness, method: String) async -> Runners.Flow {
    let authTransport = TestTransport([
        jsonResponse(["device_code": "dev-r3", "user_code": "R3-CODE", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": "ghu_new_session", "refresh_token": "ghr_new_session", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": []])
    ])
    let logger = Relux.Testing.Logger()
    let auth = await GitHubAuth.Flow(deviceFlow: GitHubDeviceFlow(transport: authTransport),
        api: GitHubAPIClient(transport: authTransport),
        refresher: GitHubTokenRefresh(transport: authTransport, store: h.userStore),
        store: h.userStore, identityStore: h.identities, configProvider: { _ in testConfig },
        sleeper: { _ in }, dispatcher: Relux.Dispatcher(logger: logger))
    let transport = ReviewR3ReloginTransport(base: h.transport, auth: auth, logger: logger, method: method)
    return await Runners.Flow(service: h.service, catalog: h.catalog, installer: h.installer,
        api: GitHubRunnerAPIClient(transport: transport), userStore: h.userStore,
        identities: h.identities, refresher: GitHubTokenRefresh(transport: transport, store: h.userStore),
        configProvider: { _ in testConfig }, home: h.home, dispatcher: Relux.Dispatcher(logger: h.logger))
}
@Test func reviewR3SameAccountReloginDuringPutMustNotPublishAccess() async throws {
    let h = await catalogHarness(transportResponses: [groupsPayload([(4, "g")]),
        groupRunnersPayload([(42, "r", false)]), .init(status: 204, body: Data()), groupReposPayload([1])])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.logoutput"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let flow = await reviewR3ReloginFlow(h, method: "PUT")
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [1], allowTakeover: true))
    #expect(await h.identities.load()?.userID == 42)
    #expect(loadedGroupAccess(h.logger, id: label) == nil)
    #expect(await h.transport.requests.count == 3)
}

@Test func reviewR3SameAccountReloginDuringRemoveTokenMustRefuseSideEffect() async throws {
    let h = await catalogHarness(launchResults: [stopped, stopped, stopped],
        installerResults: [.init(code: 0, output: "ok")], transportResponses: [removeTokenPayload()])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.logoutremove"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try "#!/bin/sh\nexit 0\n".write(to: dir.appendingPathComponent("config.sh"), atomically: true, encoding: .utf8)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let flow = await reviewR3ReloginFlow(h, method: "POST")
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.unregister(label, confirmation: "r"))
    #expect(await h.identities.load()?.userID == 42)
    #expect(await h.installerExecutor.calls.isEmpty)
    #expect(await h.catalog.load().first?.remoteAgentID == 42)
}


@Test func reviewR3RelinkMustNotRebindLoadedEditorToOtherOrg() async throws {
    let h = await catalogHarness(transportResponses: [groupsPayload([(4, "g")]),
        groupRunnersPayload([(42, "r", false)]), groupReposPayload([1]),
        groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)]),
        .init(status: 204), groupReposPayload([2])])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.relinkretarget"
    let dir = try makeRunnerDir(parent: h.home, name: "original", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    _ = await h.flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(loadedGroupAccess(h.logger, id: label)?.group?.id == 4)
    let foreign = try makeRunnerDir(parent: h.home, name: "foreign", agentName: "r", scope: "other-org", agentID: 42, label: label)
    _ = await h.flow.apply(Runners.Effect.relinkDirectory(label, foreign))
    // The previously loaded editor still carries group 4 and its pending selection.
    // A relocation must not turn that acme authority into other-org authority.
    _ = await h.flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [2], allowTakeover: true))
    let writes = await h.transport.requests.filter { $0.method == "PUT" }
    print("R3 relink writes:", writes.map { $0.url.absoluteString })
    #expect(writes.isEmpty)
}
