
@Test func reviewMissingChecksumMustRefuse() async throws {
    let package = try await FixturePackage.make()
    let harness = await registrationHarness(transport: TestTransport([]), downloader: fixtureDownloader(package.bytes))
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let asset = RunnerRegistration.DownloadAsset(osName: "osx", architecture: "arm64", downloadURL: URL(string: "https://example.com/runner.tar.gz")!, filename: "runner.tar.gz", sha256Checksum: nil)
    do {
        _ = try await harness.installer.downloadAndInstall(asset: asset, draft: orgDraft())
        Issue.record("ABSENT EVIDENCE ADMITTED: archive installed without checksum")
    } catch { }
}

@Test func reviewReal204RepositoryUpdateMustSucceed() async {
    let harness = await harnessWithResolvedGroup(allow: true)
    defer { try? FileManager.default.removeItem(at: harness.home) }
    await harness.transport.append(GitHubHTTPResponse(status: 204, body: Data()))
    await harness.transport.append(jsonResponse(["repositories": [["id": 9], ["id": 10]]]))
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [9,10]))
    #expect(lastFailure(harness.logger) == nil)
    #expect(registrationActions(harness.logger).contains { if case .repositoryAccessApplied = $0 { true } else { false } })
}

@Test func reviewUnownedMatchingGroupMustNotBeMutated() async {
    let harness = await harnessWithResolvedGroup(allow: true)
    defer { try? FileManager.default.removeItem(at: harness.home) }
    await harness.transport.append(jsonResponse([:]))
    await harness.transport.append(jsonResponse(["repositories": [["id": 10]]]))
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [10]))
    #expect(await harness.transport.requests.filter { $0.method == "PUT" }.isEmpty)
}

@Test func reviewPublicRepositoriesMustBeEnabled() async throws {
    let transport = TestTransport([
        jsonResponse(["runner_groups": []]),
        jsonResponse(["id": 7, "name": "RunnerControl-Mac", "visibility": "selected"], status: 201),
        jsonResponse(["repositories": [["id": 9]]])
    ])
    let harness = await registrationHarness(transport: transport)
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    let request = try #require(await transport.requests.first { $0.method == "POST" })
    let body = try #require(JSONSerialization.jsonObject(with: request.body!) as? [String: Any])
    #expect(body["allows_public_repositories"] as? Bool == true)
}

@Test func reviewPostConfigFailureMustDeleteTokenAndNeverReplace() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor()
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        jsonResponse(["token": "REG-REVIEW-SECRET", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        GitHubHTTPResponse(status: 500, body: Data())
    ])
    let harness = await registrationHarness(transport: transport, downloader: fixtureDownloader(package.bytes), executor: executor)
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let draft = repoDraft()
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(draft))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    #expect(await harness.registrationTokens.load(scopeKey: RunnerRegistration.Flow.tokenScopeKey(draft: draft)) == nil)
    #expect(await executor.configCalls.allSatisfy { !$0.contains("--replace") })
}
