
@Test @MainActor func reviewerGlobalLeaseBlocksServiceAndRecovery() async throws {
    let package = try await FixturePackage.make()
    let downloads = CountingLatchDownloader(bytes: package.bytes)
    let harness = await registrationHarness(transport: TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem))
    ]), downloader: { url in try await downloads.download(url) })
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let other = harness.home.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try Data("#!/bin/sh".utf8).write(to: other.appendingPathComponent("runsvc.sh"))
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    let old = Task { await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall) }
    await downloads.waitStarted()
    _ = await harness.flow.apply(RunnerRegistration.Effect.cancel)
    do {
        _ = try await harness.installer.setupService(directory: other, label: "review.test")
        Issue.record("Service mutation bypassed global lease")
    } catch { #expect(error.localizedDescription.contains("busy")) }
    do {
        try await harness.installer.recoverPartialInstall(directory: other, scopeKey: orgDraft().scope.scopeKey)
        Issue.record("Recovery bypassed global lease")
    } catch { #expect(error.localizedDescription.contains("busy")) }
    #expect(FileManager.default.fileExists(atPath: other.path))
    #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("manual-service.plist").path))
    await downloads.release()
    _ = await old.value
    _ = try await harness.installer.setupService(directory: other, label: "review.test")
    #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("manual-service.plist").path))
    try await harness.installer.recoverPartialInstall(directory: other, scopeKey: "")
    #expect(!FileManager.default.fileExists(atPath: other.path))
}
