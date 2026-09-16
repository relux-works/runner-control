
// Review R4: logout while the final production launchctl inspection awaits.
private actor ReviewR4LogoutExecutor: CommandExecuting {
    let auth: GitHubAuth.Flow
    private var count = 0
    init(auth: GitHubAuth.Flow) { self.auth = auth }
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        count += 1
        if count == 2 { _ = await auth.apply(GitHubAuth.Effect.logout) }
        return stopped
    }
}

@Test func reviewR4LogoutDuringFinalStoppedInspectionMustRefuseRemoval() async throws {
    let h = await catalogHarness(installerResults: [.init(code: 0, output: "ok")], transportResponses: [removeTokenPayload()])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.finalinspection"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let authTransport = TestTransport([])
    let auth = await GitHubAuth.Flow(deviceFlow: GitHubDeviceFlow(transport: authTransport),
        api: GitHubAPIClient(transport: authTransport),
        refresher: GitHubTokenRefresh(transport: authTransport, store: h.userStore),
        store: h.userStore, identityStore: h.identities, configProvider: { _ in testConfig },
        dispatcher: Relux.Dispatcher(logger: Relux.Testing.Logger()))
    let service = LaunchAgentService(catalog: h.catalog, executor: ReviewR4LogoutExecutor(auth: auth), userID: 501, home: h.home)
    let flow = await Runners.Flow(service: service, catalog: h.catalog, installer: h.installer,
        api: GitHubRunnerAPIClient(transport: h.transport), userStore: h.userStore,
        identities: h.identities, refresher: GitHubTokenRefresh(transport: h.transport, store: h.userStore),
        configProvider: { _ in testConfig }, home: h.home, dispatcher: Relux.Dispatcher(logger: h.logger))
    _ = await flow.apply(Runners.Effect.unregister(label, confirmation: "r"))
    #expect(await h.identities.load() == nil)
    #expect(await h.transport.requests.count == 1)
    #expect(await h.installerExecutor.calls.isEmpty)
    #expect(await h.catalog.load().first?.remoteAgentID == 42)
}

@MainActor @Test(arguments: [false, true])
func reviewR4SessionInvalidationMustReleaseEditorLoading(apply: Bool) async throws {
    let responses: [GitHubHTTPResponse] = apply
        ? [groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)]), .init(status: 204), groupReposPayload([2])]
        : [groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)]), groupReposPayload([1])]
    let h = await catalogHarness(transportResponses: responses)
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.releaseeditor"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let flow = await reviewR3ReloginFlow(h, method: apply ? "PUT" : "GET")
    let effect: Runners.Effect = apply ? .applyGroupAccess(label, groupID: 4, repositories: [2], allowTakeover: true) : .loadGroupAccess(label)
    _ = await flow.apply(effect)
    #expect(await h.identities.load()?.sessionIncarnation != nil)
    #expect(loadedGroupAccess(h.logger, id: label) == nil)
    let state = Runners.State(definitions: [])
    for action in runnersActions(h.logger) { await state.reduce(with: action) }
    // Normal local polling must not leave the editor wedged either.
    await state.reduce(with: Runners.Action.refreshed(await h.service.snapshots()))
    #expect(state.groupAccess[label]?.loading != true)
}
