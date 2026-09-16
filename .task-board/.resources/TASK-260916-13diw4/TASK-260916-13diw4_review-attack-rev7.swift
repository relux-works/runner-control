@Test @MainActor func reviewerUnicodeCaseAliasCannotBypassDirectoryLease() async throws {
    // Adopted rev6 attack: same production entry (Flow.apply), spellings,
    // refusal assertions (calls==1, busy) and retry-reuse assertion, with
    // one ordering correction — the physical-identity (inode) proof runs
    // after the original settles instead of while the refused second is
    // still pending. On fixed code the directory is absent at that point
    // (the refused operation creates nothing; the first download is still
    // latched before its mkdir), so attributesOfItem would throw instead of
    // asserting. No correct fix can satisfy both the absent-leaf premise
    // and a present-leaf inode check with only a refused operation between
    // them; proving same-inode after settle keeps the alias premise while
    // the calls==1/busy assertions prove the refusal.
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
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft({ var d = orgDraft(); d.installDirName = "runner-σ"; return d }()))
    let old = Task { await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall) }
    let deadline = Date().addingTimeInterval(10)
    while !(await downloads.started) && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    guard await downloads.started else { #expect(Bool(false), "Download never started"); await downloads.release(); _ = await old.value; return }
    #expect(!FileManager.default.fileExists(atPath: harness.installRoot.appendingPathComponent("runner-σ").path))
    var aliasDraft = orgDraft()
    aliasDraft.installDirName = "runner-ς"
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(aliasDraft))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    #expect(await downloads.calls == 1, "Second download must not start while the first owns this directory")
    #expect(lastFailure(harness.logger)?.step == "downloadAndInstall")
    #expect(lastFailure(harness.logger)?.message.contains("busy") ?? false)
    await downloads.release()
    _ = await old.value
    let lower = harness.installRoot.appendingPathComponent("runner-σ")
    let upper = harness.installRoot.appendingPathComponent("runner-ς")
    let lowerInode = try FileManager.default.attributesOfItem(atPath: lower.path)[.systemFileNumber] as? NSNumber
    let upperInode = try FileManager.default.attributesOfItem(atPath: upper.path)[.systemFileNumber] as? NSNumber
    #expect(lowerInode != nil && lowerInode == upperInode, "Attack spellings must address the same filesystem directory")
    print("case-alias evidence: calls=\(await downloads.calls), lowerInode=\(String(describing: lowerInode)), upperInode=\(String(describing: upperInode))")
    _ = await harness.flow.apply(RunnerRegistration.Effect.retry)
    #expect(await downloads.calls == 1, "Retry after settle reuses the install instead of downloading again")
    let state = RunnerRegistration.State()
    for item in registrationActions(harness.logger) { await state.reduce(with: item) }
    #expect(state.installPath != nil)
    #expect(state.completedSteps.contains("downloadAndInstall"))
}

