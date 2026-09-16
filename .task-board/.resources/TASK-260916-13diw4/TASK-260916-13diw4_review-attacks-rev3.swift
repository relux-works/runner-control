
private actor ReviewDownloadLatch {
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    var releaseWaiter: CheckedContinuation<Void, Never>?
    func download(_ bytes: Data) async -> Data {
        started = true
        waiter?.resume(); waiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return bytes
    }
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@Test @MainActor func reviewerInFlightInstallCannotRepopulateChangedDraft() async throws {
    let package = try await FixturePackage.make()
    let latch = ReviewDownloadLatch()
    let transport = TestTransport([downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem))])
    let harness = await registrationHarness(transport: transport, downloader: { _ in await latch.download(package.bytes) })
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    let operation = Task { await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall) }
    await latch.waitStarted()
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(repoDraft(dir: "new-install")))
    await latch.release()
    _ = await operation.value
    let state = RunnerRegistration.State()
    for item in registrationActions(harness.logger) { await state.reduce(with: item) }
    #expect(state.draft?.installDirName == "new-install")
    #expect(state.installPath == nil, "Old async install must not attest the new draft")
    #expect(!state.completedSteps.contains("downloadAndInstall"))
}

@Test func reviewerForeignServerIdentityCannotAuthorizeLabels() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        jsonResponse(["labels": [["name": "gpu"]]])
    ])
    let harness = await registrationHarness(transport: transport, downloader: fixtureDownloader(package.bytes), executor: SplitExecutor())
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let directory = await harness.installer.directory(for: "macbook-test")
    try Data(#"{"agentId":4242,"agentName":"macbook-test","gitHubUrl":"https://enterprise.example/acme","workFolder":"_work"}"#.utf8).write(to: directory.appendingPathComponent(".runner"))
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyLabels(["gpu"]))
    #expect(await transport.requests.filter { $0.method == "PUT" }.isEmpty, "Foreign server ID must not authorize github.com writes")
    #expect(lastFailure(harness.logger)?.step == "applyLabels")
}

@Test func reviewerChangedWorkFolderCannotReuseConfiguredSuccess() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]])
    ])
    let harness = await registrationHarness(transport: transport, downloader: fixtureDownloader(package.bytes), executor: SplitExecutor())
    defer { try? FileManager.default.removeItem(at: harness.home) }
    var draft = orgDraft()
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(draft))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    draft.workFolder = "new_work"
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(draft))
    let before = registrationActions(harness.logger).count
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let after = Array(registrationActions(harness.logger).dropFirst(before))
    #expect(!after.contains { if case .registered = $0 { true } else { false } }, "Old _work configuration is not new_work success")
    #expect(lastFailure(harness.logger)?.step == "registerRunner")
}
