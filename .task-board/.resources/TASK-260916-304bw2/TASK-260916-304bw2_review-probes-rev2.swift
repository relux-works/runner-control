
private actor ReviewLogoutTransport: GitHubHTTPTransport {
    let base: TestTransport
    let identities: any GitHubSessionIdentityStoring
    let logoutMethod: String
    init(_ base: TestTransport, identities: any GitHubSessionIdentityStoring, logoutMethod: String) {
        self.base = base; self.identities = identities; self.logoutMethod = logoutMethod
    }
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        let result = try await base.send(request)
        if request.method == logoutMethod { await identities.delete() }
        return result
    }
}

private func reviewLogoutFlow(_ h: CatalogHarness, method: String) async -> Runners.Flow {
    let transport = ReviewLogoutTransport(h.transport, identities: h.identities, logoutMethod: method)
    return await Runners.Flow(service: h.service, catalog: h.catalog, installer: h.installer,
        api: GitHubRunnerAPIClient(transport: transport), userStore: h.userStore,
        identities: h.identities, refresher: GitHubTokenRefresh(transport: transport, store: h.userStore),
        configProvider: { _ in testConfig }, home: h.home,
        dispatcher: Relux.Dispatcher(logger: h.logger))
}

@Test func reviewR2LogoutDuringPutMustNotPublishAccess() async throws {
    let h = await catalogHarness(transportResponses: [groupsPayload([(4, "g")]),
        groupRunnersPayload([(42, "r", false)]), .init(status: 204), groupReposPayload([1])])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.logoutput"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let flow = await reviewLogoutFlow(h, method: "PUT")
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [1], allowTakeover: true))
    #expect(await h.identities.load() == nil)
    #expect(loadedGroupAccess(h.logger, id: label) == nil)
    #expect(await h.transport.requests.count == 3)
}

@Test func reviewR2LogoutDuringRemoveTokenMustRefuseSideEffect() async throws {
    let h = await catalogHarness(launchResults: [stopped, stopped, stopped],
        installerResults: [.init(code: 0, output: "ok")], transportResponses: [removeTokenPayload()])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.logoutremove"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try "#!/bin/sh\nexit 0\n".write(to: dir.appendingPathComponent("config.sh"), atomically: true, encoding: .utf8)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let flow = await reviewLogoutFlow(h, method: "POST")
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.unregister(label, confirmation: "r"))
    #expect(await h.identities.load() == nil)
    #expect(await h.installerExecutor.calls.isEmpty)
    #expect(await h.catalog.load().first?.remoteAgentID == 42)
}

@Test func reviewR2ScopeEditAfterLoadMustNotRetargetApply() async throws {
    let h = await catalogHarness(transportResponses: [groupsPayload([(4, "g")]),
        groupRunnersPayload([(42, "r", false)]), groupReposPayload([1]),
        groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)]),
        .init(status: 204), groupReposPayload([2])])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.scoperetarget"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(loadedGroupAccess(h.logger, id: label)?.group?.id == 4)
    let runner = dir.appendingPathComponent(".runner")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: runner)) as! [String: Any]
    object["gitHubUrl"] = "https://github.com/other-org"
    try JSONSerialization.data(withJSONObject: object).write(to: runner)
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [2], allowTakeover: true))
    #expect(await h.transport.requests.filter { $0.method == "PUT" }.isEmpty)
}
