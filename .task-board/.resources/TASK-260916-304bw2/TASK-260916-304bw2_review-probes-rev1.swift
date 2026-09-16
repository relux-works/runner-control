
@Test func reviewUnknownServiceMustRefuseUnregister() async throws {
    let h = await catalogHarness(launchResults: [.init(code: 1, output: "Operation not permitted")], installerResults: [.init(code: 0, output: "ok")], transportResponses: [removeTokenPayload()])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let d = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", label: "actions.runner.review.unknown")
    try await h.catalog.add(unregisterEntry(dir: d, label: "actions.runner.review.unknown"))
    _ = await h.flow.apply(Runners.Effect.unregister("actions.runner.review.unknown", confirmation: "r"))
    #expect(await h.transport.requests.isEmpty)
    #expect(await h.installerExecutor.calls.isEmpty)
}

@Test func reviewRemovedLastEntryMustStayRemovedOnMigration() async throws {
    let h = await catalogHarness()
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    _ = try makeRunnerDir(parent: h.home.appendingPathComponent("Library/GitHubActions"), name: "r")
    let entries = try await h.catalog.migrateIfNeeded(home: h.home)
    #expect(entries.count == 1)
    _ = try await h.catalog.remove(localID: entries[0].localID)
    #expect(await h.catalog.load().isEmpty)
    #expect(try await h.catalog.migrateIfNeeded(home: h.home).isEmpty)
}

@Test func reviewSameNameFolderImportsMustHaveDistinctServiceIDs() async throws {
    let h = await catalogHarness()
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let a = try makeRunnerDir(parent: h.home, name: "a", agentName: "same", scope: "acme/a", withPlist: false)
    let b = try makeRunnerDir(parent: h.home, name: "b", agentName: "same", scope: "acme/b", withPlist: false)
    _ = await h.flow.apply(Runners.Effect.importFolder(a))
    _ = await h.flow.apply(Runners.Effect.importFolder(b))
    let entries = await h.catalog.load()
    #expect(entries.count == 2)
    #expect(Set(entries.map(\.serviceLabel)).count == 2)
}

@Test func reviewCrossServerGroupApplyMustRefuse() async throws {
    let h = await catalogHarness(transportResponses: [groupsPayload([(4, "g")]), groupRunnersPayload([(42,"r",false)]), .init(status:204,body:Data()), groupReposPayload([1])])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let d = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", label: "actions.runner.review.cross")
    let foreign: [String: Any] = ["agentId":42,"agentName":"r","gitHubUrl":"https://ghe.example.com/acme","workFolder":"_work"]
    try JSONSerialization.data(withJSONObject:foreign).write(to:d.appendingPathComponent(".runner"))
    var entry = unregisterEntry(dir:d,label:"actions.runner.review.cross")
    entry.serverHost = "ghe.example.com"
    try await h.catalog.add(entry)
    _ = await h.flow.apply(Runners.Effect.applyGroupAccess("actions.runner.review.cross",groupID:4,repositories:[1],allowTakeover:true))
    #expect(await h.transport.requests.filter { $0.method == "PUT" }.isEmpty)
    #expect(loadedGroupAccess(h.logger,id:"actions.runner.review.cross") == nil)
}
