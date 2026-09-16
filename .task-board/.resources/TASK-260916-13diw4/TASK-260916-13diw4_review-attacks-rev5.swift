@Test @MainActor func reviewerSymlinkAliasCannotBypassDirectoryLease() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = ConfigLatchExecutor()
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-OLD", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([]),
        jsonResponse(["token": "REG-NEW", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "renamed-runner", "labels": []]])
    ])
    let h = await registrationHarness(transport: transport, downloader: fixtureDownloader(package.bytes), executor: executor)
    defer { try? FileManager.default.removeItem(at: h.home) }
    _ = await h.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await h.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    let old = Task { await h.flow.apply(RunnerRegistration.Effect.registerRunner) }
    await executor.waitStarted()
    var edited = orgDraft()
    edited.runnerName = "renamed-runner"
    edited.installDirName = "alias-install"
    try FileManager.default.createSymbolicLink(
        at: h.installRoot.appendingPathComponent("alias-install"),
        withDestinationURL: h.installRoot.appendingPathComponent("macbook-test"))
    _ = await h.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
    _ = await h.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await h.flow.apply(RunnerRegistration.Effect.registerRunner)
    let callsWhileOldRuns = await executor.configCalls.count
    await executor.release()
    _ = await old.value
    #expect(callsWhileOldRuns == 1, "An identity edit must not allow a second config.sh while the first still owns this directory")
    let state = RunnerRegistration.State()
    for action in registrationActions(h.logger) { await state.reduce(with: action) }
    let directory = await h.installer.directory(for: edited.installDirName)
    let local = await h.installer.readLocalRegistration(directory: directory)
    #expect(!state.completedSteps.contains("registerRunner") || local?.agentName == edited.runnerName,
            "New registration is attested complete but old in-flight config overwrites .runner afterwards")
}
