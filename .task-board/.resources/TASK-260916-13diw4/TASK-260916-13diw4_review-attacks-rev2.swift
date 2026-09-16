
// Reviewer attacks; appended only to git-archived rev2 in /tmp.
@Test func reviewR2ListURLsUseQueryNotEncodedPath() async throws {
    let transport = TestTransport([
        groupsListPayload([]),
        jsonResponse(groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true), status: 201),
        jsonResponse(["repositories": []]),
        runnersListPayload([])
    ])
    let h = await registrationHarness(transport: transport)
    defer { try? FileManager.default.removeItem(at: h.home) }
    _ = await h.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await h.flow.apply(RunnerRegistration.Effect.resolveGroup)
    _ = await h.flow.apply(RunnerRegistration.Effect.applyLabels(["gpu"]))
    let requests = await transport.requests
    let lists = requests.filter { $0.url.absoluteString.contains("per_page") }
    #expect(lists.count == 2)
    for request in lists {
        #expect(!request.url.absoluteString.contains("%3F"))
        #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "per_page", value: "100")) == true)
    }
}

@Test func reviewR2NameOnlyMustNotAuthorizeLabelMutation() async throws {
    let transport = TestTransport([
        runnersListPayload([["id": 77, "name": "macbook-test", "labels": []]]),
        jsonResponse(["labels": [["name": "gpu"]]])
    ])
    let h = await registrationHarness(transport: transport)
    defer { try? FileManager.default.removeItem(at: h.home) }
    _ = await h.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    // No install, no local agent ID, no successful registration; foreign name match only.
    _ = await h.flow.apply(RunnerRegistration.Effect.applyLabels(["gpu"]))
    #expect(await transport.requests.filter { $0.method == "PUT" }.isEmpty)
    #expect(!registrationActions(h.logger).contains { if case .labelsApplied = $0 { true } else { false } })
}

@Test func reviewR2ChangedScopeMustNotReuseRegistrationOrRemoteID() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor()
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REVIEW-TOKEN", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        jsonResponse(["labels": [["name": "gpu"]]])
    ])
    let h = await registrationHarness(transport: transport, downloader: fixtureDownloader(package.bytes), executor: executor)
    defer { try? FileManager.default.removeItem(at: h.home) }
    _ = await h.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await h.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await h.flow.apply(RunnerRegistration.Effect.registerRunner)
    // Actual Container dispatches updateDraft for edits and leaves Apply Labels enabled.
    _ = await h.flow.apply(RunnerRegistration.Effect.updateDraft(repoDraft(dir: "different-install")))
    _ = await h.flow.apply(RunnerRegistration.Effect.applyLabels(["gpu"]))
    let foreignWrites = await transport.requests.filter { $0.method == "PUT" && $0.url.path.contains("/repos/octo/app/actions/runners/4242/labels") }
    #expect(foreignWrites.isEmpty)
}

@Test func reviewR2MismatchedLocalAgentMustNotBecomeRemoteIdentity() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REVIEW-TOKEN", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 77, "name": "macbook-test", "labels": []]]),
        jsonResponse(["labels": [["name": "gpu"]]])
    ])
    let h = await registrationHarness(transport: transport, downloader: fixtureDownloader(package.bytes), executor: SplitExecutor())
    defer { try? FileManager.default.removeItem(at: h.home) }
    _ = await h.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await h.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await h.flow.apply(RunnerRegistration.Effect.registerRunner)
    _ = await h.flow.apply(RunnerRegistration.Effect.applyLabels(["gpu"]))
    #expect(await h.installer.readAgentID(directory: h.installRoot.appendingPathComponent("macbook-test")) == 4242)
    #expect(await transport.requests.filter { $0.method == "PUT" && $0.url.path.contains("/77/labels") }.isEmpty)
}

@Test func reviewR2ServiceCannotClaimDoneBeforeRegistration() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem))])
    let h = await registrationHarness(transport: transport, downloader: fixtureDownloader(package.bytes), executor: SplitExecutor())
    defer { try? FileManager.default.removeItem(at: h.home) }
    _ = await h.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await h.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    // Wizard exposes this step while connected even when registration was skipped/failed.
    _ = await h.flow.apply(RunnerRegistration.Effect.setupService)
    #expect(!registrationActions(h.logger).contains { if case .serviceReady = $0 { true } else { false } })
    #expect(!FileManager.default.fileExists(atPath: h.installRoot.appendingPathComponent("macbook-test/manual-service.plist").path))
}

@Test func reviewR2RepositoryConfirmationMustFollowPagination() async throws {
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
        GitHubHTTPResponse(status: 204, body: Data()),
        GitHubHTTPResponse(status: 200, headers: ["Link": "<https://api.github.com/orgs/acme/actions/runner-groups/5/repositories?page=2>; rel=\"next\""], body: try JSONSerialization.data(withJSONObject: ["total_count": 2, "repositories": [["id": 9]]])),
        jsonResponse(["total_count": 2, "repositories": [["id": 10]]])
    ])
    let h = await registrationHarness(transport: transport)
    defer { try? FileManager.default.removeItem(at: h.home) }
    _ = await h.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await h.flow.apply(RunnerRegistration.Effect.resolveGroup)
    _ = await h.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [9,10]))
    let confirmed = registrationActions(h.logger).compactMap { a -> [Int64]? in
        if case .repositoryAccessApplied(let ids) = a { ids } else { nil }
    }
    #expect(confirmed.last.map(Set.init) == Set<Int64>([9,10]))
    #expect(await transport.requests.contains { $0.url.query?.contains("page=2") == true })
}
