@Test @MainActor func reviewerCaseAliasMissingLeafCannotBypassDirectoryLease() async throws {
    // R5/R4-F1 at the beginDraft boundary: a new draft for the SAME directory
    // releases the UI lock but never the live install's directory lease. A
    // same-directory retry while the first install runs is refused retryably
    // (no second download); after the first settles stale, retry reuses it.
    let package = try await FixturePackage.make()
    let downloads = CountingLatchDownloader(bytes: package.bytes)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
    ])
    let harness = await registrationHarness(
        transport: transport, downloader: { url in try await downloads.download(url) }
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    let old = Task { await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall) }
    let deadline = Date().addingTimeInterval(10)
    while !(await downloads.started) && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    guard await downloads.started else { #expect(Bool(false), "Download never started"); await downloads.release(); _ = await old.value; return }
    #expect(!FileManager.default.fileExists(atPath: harness.installRoot.appendingPathComponent("macbook-test").path))
    var aliasDraft = orgDraft()
    aliasDraft.installDirName = "MACBOOK-TEST"
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(aliasDraft))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    let lower = harness.installRoot.appendingPathComponent("macbook-test")
    let upper = harness.installRoot.appendingPathComponent("MACBOOK-TEST")
    let lowerInode = try FileManager.default.attributesOfItem(atPath: lower.path)[.systemFileNumber] as? NSNumber
    let upperInode = try FileManager.default.attributesOfItem(atPath: upper.path)[.systemFileNumber] as? NSNumber
    #expect(lowerInode != nil && lowerInode == upperInode, "Attack spellings must address the same filesystem directory")
    print("case-alias evidence: calls=\(await downloads.calls), lowerInode=\(String(describing: lowerInode)), upperInode=\(String(describing: upperInode))")
    #expect(await downloads.calls == 1, "Second download must not start while the first owns this directory")
    #expect(lastFailure(harness.logger)?.step == "downloadAndInstall")
    #expect(lastFailure(harness.logger)?.message.contains("busy") ?? false)
    await downloads.release()
    _ = await old.value
    _ = await harness.flow.apply(RunnerRegistration.Effect.retry)
    #expect(await downloads.calls == 1, "Retry after settle reuses the install instead of downloading again")
    let state = RunnerRegistration.State()
    for item in registrationActions(harness.logger) { await state.reduce(with: item) }
    #expect(state.installPath != nil)
    #expect(state.completedSteps.contains("downloadAndInstall"))
}

