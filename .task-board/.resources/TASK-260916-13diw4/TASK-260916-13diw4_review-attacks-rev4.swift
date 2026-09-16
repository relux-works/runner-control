
// Reviewer-only tests appended to the immutable candidate in a disposable copy.
@Test @MainActor func reviewerRetryCannotRunTwoConfigsInSameDirectory() async throws {
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
    _ = await h.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
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

private actor ReviewTwoDownloads {
    private var count = 0
    private var started: Set<Int> = []
    private var startWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
    func download(_ bytes: Data) async throws -> Data {
        count += 1
        let n = count
        started.insert(n)
        startWaiters.removeValue(forKey: n)?.resume()
        await withCheckedContinuation { releases[n] = $0 }
        if n == 1 { throw GitHubTransportError.invalidResponse }
        return bytes
    }
    func waitStarted(_ n: Int) async {
        if started.contains(n) { return }
        await withCheckedContinuation { startWaiters[n] = $0 }
    }
    func release(_ n: Int) { releases.removeValue(forKey: n)?.resume() }
}

@Test func reviewerStaleFailureCannotUnlockNewOperation() async throws {
    let package = try await FixturePackage.make()
    let latch = ReviewTwoDownloads()
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem))
    ])
    let h = await registrationHarness(transport: transport, downloader: { _ in try await latch.download(package.bytes) })
    defer { try? FileManager.default.removeItem(at: h.home) }
    _ = await h.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    let old = Task { await h.flow.apply(RunnerRegistration.Effect.downloadAndInstall) }
    await latch.waitStarted(1)
    var edited = orgDraft()
    edited.installDirName = "new-install"
    _ = await h.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
    let current = Task { await h.flow.apply(RunnerRegistration.Effect.downloadAndInstall) }
    await latch.waitStarted(2)
    await latch.release(1)
    _ = await old.value
    let before = await transport.requests.count
    _ = await h.flow.apply(RunnerRegistration.Effect.prepareDownload)
    let after = await transport.requests.count
    await latch.release(2)
    _ = await current.value
    #expect(after == before, "Old generation's catch must not clear the current operation's working lock")
}
