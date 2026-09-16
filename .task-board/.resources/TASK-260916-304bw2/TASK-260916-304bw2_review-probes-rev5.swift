
private actor ReviewR5TwoLoads: GitHubHTTPTransport {
    var sends = 0
    var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        sends += 1
        let n = sends
        if n <= 2 {
            await withCheckedContinuation { gates[n] = $0 }
            return groupsPayload([(4, "g")])
        }
        if request.url.path.contains("/runners") { return groupRunnersPayload([(42, "r", false)]) }
        return groupReposPayload([7])
    }
    func release(_ n: Int) { gates.removeValue(forKey: n)?.resume() }
}

@MainActor @Test func reviewR5RemoveReimportMustNotReviveOldEditorOwner() async throws {
    let h = await catalogHarness()
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.owneraba"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let transport = ReviewR5TwoLoads()
    let flow = await Runners.Flow(service: h.service, catalog: h.catalog, installer: h.installer,
        api: GitHubRunnerAPIClient(transport: transport), userStore: h.userStore,
        identities: h.identities, refresher: GitHubTokenRefresh(transport: transport, store: h.userStore),
        configProvider: { _ in testConfig }, home: h.home, dispatcher: Relux.Dispatcher(logger: h.logger))
    let first = Task { await flow.apply(Runners.Effect.loadGroupAccess(label)) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await transport.sends < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await transport.sends == 1)
    _ = await flow.apply(Runners.Effect.removeFromApp(label))
    _ = await flow.apply(Runners.Effect.importFolder(dir))
    #expect(await h.catalog.load().first?.serviceLabel == label)
    let second = Task { await flow.apply(Runners.Effect.loadGroupAccess(label)) }
    let deadline2 = ContinuousClock.now.advanced(by: .seconds(3))
    while await transport.sends < 2, ContinuousClock.now < deadline2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await transport.sends == 2)
    await transport.release(1)
    _ = await first.value
    let state = Runners.State(definitions: [])
    for action in runnersActions(h.logger) { await state.reduce(with: action) }
    #expect(state.groupAccess[label]?.loading == true, "Old operation must not clear the newer pending Load")
    #expect(state.groupAccess[label]?.error == nil, "Old operation must not publish its catalog-change error into new editor")
    await transport.release(2)
    _ = await second.value
}
