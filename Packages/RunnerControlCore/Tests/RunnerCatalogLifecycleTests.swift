import Foundation
import Testing
import Relux
@testable import RunnerControlCore

// MARK: - Catalog lifecycle harness (production entry points, controlled IO)

// TestTransport, jsonResponse, testConfig shared from GitHubTransportTests.
// FakeExecutor, stopped, running shared from RunnerControlCoreTests.

private struct CatalogHarness {
    let flow: Runners.Flow
    let logger: Relux.Testing.Logger
    let transport: TestTransport
    let launchExecutor: FakeExecutor
    let installerExecutor: FakeExecutor
    let userStore: GitHubKeychainStore
    let identities: any GitHubSessionIdentityStoring
    let installer: RunnerInstallerService
    let catalog: RunnerCatalogStore
    let service: LaunchAgentService
    let home: URL
    let catalogFile: URL
}

private func catalogHarness(
    launchResults: [CommandResult] = [],
    installerResults: [CommandResult] = [],
    transportResponses: [GitHubHTTPResponse] = [],
    seedAuth: Bool = true,
    identitiesOverride: (any GitHubSessionIdentityStoring)? = nil
) async -> CatalogHarness {
    let logger = Relux.Testing.Logger()
    let dispatcher = Relux.Dispatcher(logger: logger)
    let launchExecutor = FakeExecutor(launchResults)
    let installerExecutor = FakeExecutor(installerResults)
    let transport = TestTransport(transportResponses)
    let userStore = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let identities: any GitHubSessionIdentityStoring = identitiesOverride ?? InMemoryGitHubSessionIdentityStore()
    if seedAuth {
        if identitiesOverride == nil {
            await identities.save(GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo"))
        }
        try? await userStore.save(
            GitHubAuth.TokenRecord(accessToken: "user-token-42", refreshToken: "refresh-42", expiresAt: Date().addingTimeInterval(3600)),
            serverHost: "github.com", userID: 42, clientID: testConfig.clientID
        )
    }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogHome-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let catalogFile = FileManager.default.temporaryDirectory.appendingPathComponent("Catalog-" + UUID().uuidString + ".json")
    let catalog = RunnerCatalogStore(fileURL: catalogFile)
    let installRoot = home.appendingPathComponent("Library/GitHubActions")
    try? FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
    let installer = RunnerInstallerService(installRoot: installRoot, executor: installerExecutor)
    let service = LaunchAgentService(catalog: catalog, executor: launchExecutor, userID: 501, home: home)
    let api = GitHubRunnerAPIClient(transport: transport)
    let refresher = GitHubTokenRefresh(transport: transport, store: userStore)
    let flow = await Runners.Flow(
        service: service, catalog: catalog, installer: installer,
        api: api, userStore: userStore, identities: identities,
        refresher: refresher, configProvider: { _ in testConfig },
        home: home, dispatcher: dispatcher
    )
    return CatalogHarness(
        flow: flow, logger: logger, transport: transport,
        launchExecutor: launchExecutor, installerExecutor: installerExecutor,
        userStore: userStore, identities: identities,
        installer: installer, catalog: catalog, service: service,
        home: home, catalogFile: catalogFile
    )
}

private func runnersActions(_ logger: Relux.Testing.Logger) -> [Runners.Action] {
    logger.actions.compactMap { $0 as? Runners.Action }
}

private func lastCatalogFailure(_ logger: Relux.Testing.Logger) -> String? {
    for action in runnersActions(logger).reversed() {
        if case .catalogFailed(let message) = action { return message }
    }
    return nil
}


private func catalogErr(_ logger: Relux.Testing.Logger) -> String {
    lastCatalogFailure(logger) ?? ""
}

private func failErr(_ logger: Relux.Testing.Logger) -> String {
    lastFailureMessage(logger) ?? ""
}

private func lastFailureMessage(_ logger: Relux.Testing.Logger) -> String? {
    for action in runnersActions(logger).reversed() {
        if case .failed(let message) = action { return message }
    }
    return nil
}

/// Creates a runner directory with `.runner`, `runsvc.sh`, `run.sh` and an
/// optional manual-service plist. Returns the directory.
@discardableResult
private func makeRunnerDir(
    parent: URL, name: String,
    agentName: String = "test-runner", scope: String = "acme/app",
    agentID: Int64 = 42, workFolder: String = "_work",
    runAtLoad: Bool? = true, withPlist: Bool = true,
    label: String? = nil
) throws -> URL {
    let dir = parent.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let config: [String: Any] = [
        "agentId": agentID, "agentName": agentName,
        "gitHubUrl": "https://github.com/" + scope, "workFolder": workFolder
    ]
    try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent(".runner"))
    try "#!/bin/sh\nexit 0\n".write(to: dir.appendingPathComponent("runsvc.sh"), atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexit 0\n".write(to: dir.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexit 0\n".write(to: dir.appendingPathComponent("config.sh"), atomically: true, encoding: .utf8)
    if withPlist {
        let resolvedLabel = label ?? "actions.runner.test.\(name)"
        var plist: [String: Any] = [
            "Label": resolvedLabel,
            "ProgramArguments": [dir.appendingPathComponent("runsvc.sh").path],
            "WorkingDirectory": dir.path
        ]
        if let runAtLoad { plist["RunAtLoad"] = runAtLoad }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("manual-service.plist"))
    }
    return dir
}

private func runnersListPayload(_ runners: [[String: Any]]) -> GitHubHTTPResponse {
    jsonResponse(["runners": runners])
}

private func removeTokenPayload(token: String = "remove-token-1") -> GitHubHTTPResponse {
    jsonResponse(["token": token, "expires_at": "2030-01-01T00:00:00Z"])
}

// MARK: - Catalog persistence and dedupe (AC rows 1, 3)

@Test func catalogPersistsAndDedupesCanonicalViaSymlink() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Catalog-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = RunnerCatalogStore(fileURL: file)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Dedupe-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = try makeRunnerDir(parent: root, name: "runner-a")
    let canonical = RunnerCatalogStore.canonical(dir)
    let entry = RunnerCatalogStore.Entry(
        directoryPath: dir.path, canonicalPath: canonical,
        serviceLabel: "actions.runner.test.a",
        servicePlistPath: dir.appendingPathComponent("manual-service.plist").path,
        controllerKind: .manualManaged, runAtLoad: true,
        serverHost: "github.com", scopeKind: "repo", scope: "acme/app",
        remoteAgentID: 42, agentName: "runner", workFolder: "_work"
    )
    try await store.add(entry)
    #expect(await store.load().count == 1)
    // Same directory via a symlink spelling must be refused.
    let link = root.appendingPathComponent("link-a")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
    let alias = RunnerCatalogStore.Entry(
        directoryPath: link.path, canonicalPath: RunnerCatalogStore.canonical(link),
        serviceLabel: "actions.runner.test.alias",
        servicePlistPath: link.appendingPathComponent("manual-service.plist").path,
        controllerKind: .manualManaged
    )
    do {
        try await store.add(alias)
        Issue.record("Catalog admitted the same directory twice via symlink")
    } catch let error as RunnerCatalogStore.CatalogError {
        guard case .duplicateDirectory = error else {
            Issue.record("Wrong dedupe error: \(error)"); return
        }
    }
    #expect(await store.load().count == 1)
}

@Test func catalogKeepsSameNameDifferentScopesAsTwoRunners() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Catalog-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = RunnerCatalogStore(fileURL: file)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Scopes-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let orgDir = try makeRunnerDir(parent: root, name: "org-runner", agentName: "mac", scope: "acme", agentID: 1)
    let repoDir = try makeRunnerDir(parent: root, name: "repo-runner", agentName: "mac", scope: "acme/app", agentID: 2)
    for (dir, label, kind, scope) in [
        (orgDir, "actions.runner.test.org", "org", "acme"),
        (repoDir, "actions.runner.test.repo", "repo", "acme/app")
    ] {
        let entry = RunnerCatalogStore.Entry(
            directoryPath: dir.path, canonicalPath: RunnerCatalogStore.canonical(dir),
            serviceLabel: label,
            servicePlistPath: dir.appendingPathComponent("manual-service.plist").path,
            controllerKind: .manualManaged, serverHost: "github.com",
            scopeKind: kind, scope: scope, agentName: "mac"
        )
        try await store.add(entry)
    }
    let loaded = await store.load()
    #expect(loaded.count == 2)
    #expect(Set(loaded.map(\.scope)) == ["acme", "acme/app"])
}

// MARK: - Migration preserves production (AC rows 12, 13)

@Test func migrationPreservesPoliciesWithoutTouchingServices() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("MigHome-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let root = home.appendingPathComponent("Library/GitHubActions")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let a = try makeRunnerDir(parent: root, name: "a", agentName: "mac", scope: "acme", agentID: 11, runAtLoad: true, label: "actions.runner.test.a")
    let b = try makeRunnerDir(parent: root, name: "b", agentName: "mac", scope: "acme/app", agentID: 22, runAtLoad: false, label: "actions.runner.test.b")
    try "#!/bin/sh\nexit 0\n".write(to: a.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexit 0\n".write(to: b.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
    let beforeA = try Data(contentsOf: a.appendingPathComponent("manual-service.plist"))
    let beforeB = try Data(contentsOf: b.appendingPathComponent("manual-service.plist"))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Catalog-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = RunnerCatalogStore(fileURL: file)
    let migrated = try await store.migrateIfNeeded(home: home)
    #expect(migrated.count == 2)
    #expect(Set(migrated.map(\.serviceLabel)) == ["actions.runner.test.a", "actions.runner.test.b"])
    #expect(migrated.first { $0.serviceLabel == "actions.runner.test.a" }?.runAtLoad == true)
    #expect(migrated.first { $0.serviceLabel == "actions.runner.test.b" }?.runAtLoad == false)
    #expect(migrated.first { $0.serviceLabel == "actions.runner.test.a" }?.scope == "acme")
    #expect(migrated.first { $0.serviceLabel == "actions.runner.test.b" }?.scope == "acme/app")
    // Services untouched: byte-identical plists, no relaunch.
    #expect(try Data(contentsOf: a.appendingPathComponent("manual-service.plist")) == beforeA)
    #expect(try Data(contentsOf: b.appendingPathComponent("manual-service.plist")) == beforeB)
    // Second migration is a no-op (no duplicates).
    let again = try await store.migrateIfNeeded(home: home)
    #expect(again.count == 2)
}

// MARK: - Discovery candidates (AC row 2)

@Test func discoveryFindsManualAndStandardWithoutLaunching() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("DiscHome-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let fm = FileManager.default
    let agents = home.appendingPathComponent("Library/LaunchAgents")
    let root = home.appendingPathComponent("Library/GitHubActions")
    try fm.createDirectory(at: agents, withIntermediateDirectories: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let manual = try makeRunnerDir(parent: root, name: "manual", agentName: "mac", scope: "acme/app", label: "actions.runner.test.manual")
    let custom = home.appendingPathComponent("custom-install")
    try fm.createDirectory(at: custom, withIntermediateDirectories: true)
    let config: [String: Any] = ["agentId": 7, "agentName": "mac", "gitHubUrl": "https://github.com/acme", "workFolder": "_work"]
    try JSONSerialization.data(withJSONObject: config).write(to: custom.appendingPathComponent(".runner"))
    try "#!/bin/sh\nexit 0\n".write(to: custom.appendingPathComponent("runsvc.sh"), atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexit 0\n".write(to: custom.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
    let standardManifest = agents.appendingPathComponent("actions.runner.test.standard.plist")
    let plist: [String: Any] = [
        "Label": "actions.runner.test.standard",
        "WorkingDirectory": custom.path,
        "ProgramArguments": [custom.appendingPathComponent("runsvc.sh").path],
        "RunAtLoad": true
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: standardManifest)
    // Unknown supervisor: label matches but args do not launch runsvc.sh.
    let weirdDir = try makeRunnerDir(parent: root, name: "weird", withPlist: false)
    let weirdManifest = agents.appendingPathComponent("actions.runner.test.weird.plist")
    let weird: [String: Any] = [
        "Label": "actions.runner.test.weird",
        "WorkingDirectory": weirdDir.path,
        "ProgramArguments": ["/bin/sleep", "10"]
    ]
    try PropertyListSerialization.data(fromPropertyList: weird, format: .xml, options: 0).write(to: weirdManifest)
    // .credentials present but must never be read for discovery.
    try "secret-token".write(to: manual.appendingPathComponent(".credentials"), atomically: true, encoding: .utf8)
    let candidates = RunnerDiscovery.discoverCandidates(home: home)
    #expect(candidates.count == 3)
    let manualCandidate = candidates.first { $0.directory.path == manual.path }
    #expect(manualCandidate?.isImportable == true)
    #expect(manualCandidate?.controllerKind == .manualManaged)
    let standardCandidate = candidates.first { $0.label == "actions.runner.test.standard" }
    #expect(standardCandidate?.isImportable == true)
    #expect(standardCandidate?.controllerKind == .standardLaunchAgent)
    let weirdCandidate = candidates.first { $0.label == "actions.runner.test.weird" }
    #expect(weirdCandidate?.controllerKind == .unsupported)
    #expect(weirdCandidate?.isImportable == false)
    let weirdReason = weirdCandidate?.unsupportedReason ?? ""
    #expect(weirdReason.contains("Unknown supervisor"))
}

// MARK: - Import gates (AC rows 3, 4, 10, 12)

@Test func importRefusesSpacedPathWithoutMoving() async throws {
    let harness = await catalogHarness()
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let root = harness.home.appendingPathComponent("spaced root")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dir = try makeRunnerDir(parent: root, name: "runner", label: "actions.runner.test.spaced")
    let candidate = RunnerDiscovery.validateFolder(dir)
    #expect(candidate.needsRelocation == true)
    #expect(candidate.isImportable == false)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.importCandidate(candidate))
    #expect(lastCatalogFailure(harness.logger)?.contains("space") == true)
    #expect(await harness.catalog.load().isEmpty)
    // No auto-move: the spaced directory still exists untouched.
    #expect(FileManager.default.fileExists(atPath: dir.path))
}

@Test func importRefusesMissingBinariesAndRegistration() async throws {
    let harness = await catalogHarness()
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "broken", label: "actions.runner.test.broken")
    try FileManager.default.removeItem(at: dir.appendingPathComponent("runsvc.sh"))
    try FileManager.default.removeItem(at: dir.appendingPathComponent(".runner"))
    let candidate = RunnerDiscovery.validateManifest(dir.appendingPathComponent("manual-service.plist"))
    #expect(candidate.isImportable == false)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.importCandidate(candidate))
    #expect(lastCatalogFailure(harness.logger) != nil)
    #expect(await harness.catalog.load().isEmpty)
}

@Test func importRefusesUnsupportedWithoutSecondProcess() async throws {
    let harness = await catalogHarness()
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "weird", withPlist: false)
    let manifest = harness.home.appendingPathComponent("weird.plist")
    let plist: [String: Any] = [
        "Label": "actions.runner.test.weird",
        "WorkingDirectory": dir.path,
        "ProgramArguments": ["/bin/sleep", "10"]
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: manifest)
    let candidate = RunnerDiscovery.validateManifest(manifest)
    #expect(candidate.controllerKind == .unsupported)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.importCandidate(candidate))
    let unsupErr = catalogErr(harness.logger)
    #expect(unsupErr.contains("Unsupported") || unsupErr.contains("supervisor"))
    #expect(await harness.catalog.load().isEmpty)
    #expect(await harness.launchExecutor.calls.isEmpty)
}

@Test func importPreservesServiceAndRunAtLoad() async throws {
    let harness = await catalogHarness(launchResults: [
        CommandResult(code: 113, output: "Could not find service x")
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let root = harness.home.appendingPathComponent("Library/GitHubActions")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dir = try makeRunnerDir(parent: root, name: "keep", agentName: "keep-runner", scope: "acme", runAtLoad: true, label: "actions.runner.test.keep")
    let before = try Data(contentsOf: dir.appendingPathComponent("manual-service.plist"))
    let candidate = RunnerDiscovery.validateManifest(dir.appendingPathComponent("manual-service.plist"))
    #expect(candidate.isImportable == true)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.importCandidate(candidate))
    #expect(lastCatalogFailure(harness.logger) == nil)
    let entries = await harness.catalog.load()
    #expect(entries.count == 1)
    #expect(entries.first?.runAtLoad == true)
    #expect(entries.first?.serviceLabel == "actions.runner.test.keep")
    // Service file byte-identical: import never rewrites the policy.
    #expect(try Data(contentsOf: dir.appendingPathComponent("manual-service.plist")) == before)
    // Import never bootstraps: only the post-import refresh print ran.
    for call in await harness.launchExecutor.calls {
        #expect(!call.contains("bootstrap"))
    }
}

// MARK: - Local snapshots preserve running (AC rows 5, 8)

@Test func snapshotsPreserveRunningDespiteMissingRunner() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Snap-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = try makeRunnerDir(parent: root, name: "svc", label: "actions.runner.test.svc")
    try FileManager.default.removeItem(at: dir.appendingPathComponent(".runner"))
    let definition = Runners.Definition(
        id: "actions.runner.test.svc", title: "svc", detail: "acme",
        directory: dir, githubURL: URL(string: "https://github.com/acme")!,
        servicePlist: dir.appendingPathComponent("manual-service.plist")
    )
    let executor = FakeExecutor([CommandResult(code: 0, output: "state = running")])
    let service = LaunchAgentService(definitions: [definition], executor: executor, userID: 501)
    let snapshots = await service.snapshots()
    #expect(snapshots.first?.status == .running)
    let snapMsg = snapshots.first?.message ?? ""
    #expect(snapMsg.contains("Рабочий каталог"))
}

@Test func stopWorksDespiteMissingRunnerStartBlockedOnBadManifest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stop-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = try makeRunnerDir(parent: root, name: "svc", label: "actions.runner.test.stop")
    try FileManager.default.removeItem(at: dir.appendingPathComponent(".runner"))
    let definition = Runners.Definition(
        id: "actions.runner.test.stop", title: "svc", detail: "acme",
        directory: dir, githubURL: URL(string: "https://github.com/acme")!,
        servicePlist: dir.appendingPathComponent("manual-service.plist")
    )
    // Stop succeeds without .runner.
    let stopExecutor = FakeExecutor([
        CommandResult(code: 0, output: "state = running"),
        CommandResult(code: 0, output: ""),
        CommandResult(code: 113, output: "Could not find service x")
    ])
    let stopService = LaunchAgentService(definitions: [definition], executor: stopExecutor, userID: 501)
    try await stopService.setEnabled(false, id: definition.id)
    #expect(await stopExecutor.calls.contains(["/bin/launchctl", "bootout", "gui/501/" + definition.id]))
    // Start is blocked on a damaged manifest (no bootstrap). The args stay
    // correct so the failure narrows to the WorkingDirectory binding alone.
    let badPlist = dir.appendingPathComponent("manual-service.plist")
    let bad: [String: Any] = [
        "Label": definition.id,
        "WorkingDirectory": "/elsewhere",
        "ProgramArguments": [dir.appendingPathComponent("runsvc.sh").path]
    ]
    try PropertyListSerialization.data(fromPropertyList: bad, format: .xml, options: 0).write(to: badPlist)
    // Restore .runner so the failure is attributed to the manifest, not registration.
    let config: [String: Any] = ["agentName": "svc", "gitHubUrl": "https://github.com/acme", "workFolder": "_work"]
    try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent(".runner"))
    let startExecutor = FakeExecutor([])
    let startService = LaunchAgentService(definitions: [definition], executor: startExecutor, userID: 501)
    do {
        try await startService.setEnabled(true, id: definition.id)
        Issue.record("Start admitted a mismatched manifest")
    } catch let error as RunnerError {
        guard case .manifestMismatch = error else {
            Issue.record("Wrong start-block error: \(error)"); return
        }
    }
    #expect(await startExecutor.calls.isEmpty)
}

@Test func unsupportedShowsStateButRefusesControl() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Unsup-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = try makeRunnerDir(parent: root, name: "svc", label: "actions.runner.test.unsup")
    let definition = Runners.Definition(
        id: "actions.runner.test.unsup", title: "svc", detail: "acme",
        directory: dir, githubURL: URL(string: "https://github.com/acme")!,
        servicePlist: dir.appendingPathComponent("manual-service.plist"),
        controllerKind: .unsupported
    )
    let snapExecutor = FakeExecutor([CommandResult(code: 0, output: "state = running")])
    let snapService = LaunchAgentService(definitions: [definition], executor: snapExecutor, userID: 501)
    let snapshots = await snapService.snapshots()
    #expect(snapshots.first?.status == .running)
    let unsupMsg = snapshots.first?.message ?? ""
    #expect(unsupMsg.contains("Unsupported"))
    for enabled in [true, false] {
        let executor = FakeExecutor([])
        let service = LaunchAgentService(definitions: [definition], executor: executor, userID: 501)
        do {
            try await service.setEnabled(enabled, id: definition.id)
            Issue.record("Unsupported admitted setEnabled(\(enabled))")
        } catch let error as RunnerError {
            guard case .unsupported = error else {
                Issue.record("Wrong unsupported error: \(error)"); return
            }
        }
        #expect(await executor.calls.isEmpty)
    }
}

// MARK: - Bulk power (AC row 7)

@Test func bulkPowerReportsPartialFailuresPerRow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bulk-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let good = try makeRunnerDir(parent: root, name: "good", label: "actions.runner.test.good")
    let bad = try makeRunnerDir(parent: root, name: "bad", label: "actions.runner.test.bad")
    // Break the bad manifest so its start is refused without launchctl.
    let badPlist = bad.appendingPathComponent("manual-service.plist")
    let broken: [String: Any] = ["Label": "actions.runner.test.bad", "WorkingDirectory": "/elsewhere", "ProgramArguments": ["/bin/false"]]
    try PropertyListSerialization.data(fromPropertyList: broken, format: .xml, options: 0).write(to: badPlist)
    let goodDef = Runners.Definition(id: "actions.runner.test.good", title: "good", detail: "acme", directory: good, githubURL: URL(string: "https://github.com/acme")!, servicePlist: good.appendingPathComponent("manual-service.plist"))
    let badDef = Runners.Definition(id: "actions.runner.test.bad", title: "bad", detail: "acme", directory: bad, githubURL: URL(string: "https://github.com/acme")!, servicePlist: badPlist)
    let executor = FakeExecutor([
        // good: print stopped, bootstrap ok, print running
        CommandResult(code: 113, output: "Could not find service good"),
        CommandResult(code: 0, output: ""),
        CommandResult(code: 0, output: "state = running"),
        // final snapshots: good running, bad missing (print for bad still runs? bad validate fails first? No: snapshots prints first, so needs prints for both)
        CommandResult(code: 0, output: "state = running"),
        CommandResult(code: 113, output: "Could not find service bad")
    ])
    let logger = Relux.Testing.Logger()
    let dispatcher = Relux.Dispatcher(logger: logger)
    let service = LaunchAgentService(definitions: [goodDef, badDef], executor: executor, userID: 501)
    let flow = await Runners.Flow(service: service, dispatcher: dispatcher)
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.setEnabledMany(["actions.runner.test.good", "actions.runner.test.bad"], true))
    let actions = runnersActions(logger)
    #expect(actions.contains { if case .failed(let message) = $0 { message.contains("Partial failure (1 of 2)") } else { false } })
    let refreshed = actions.compactMap { action -> [Runners.Snapshot]? in
        if case .refreshed(let snapshots) = action { return snapshots }
        return nil
    }.last
    #expect(refreshed?.first { $0.id == "actions.runner.test.bad" }?.message?.contains("Настройки службы") == true)
    // Changing balanced for both rows.
    for id in ["actions.runner.test.good", "actions.runner.test.bad"] {
        #expect(actions.contains { if case .changing(id, true) = $0 { true } else { false } })
        #expect(actions.contains { if case .changing(id, false) = $0 { true } else { false } })
    }
}

// MARK: - Observer and staleness (AC row 6)

@Test func observerMatchesByIDNeverByName() {
    let definition = Runners.Definition(
        id: "actions.runner.test.x", title: "mac", detail: "acme",
        directory: URL(fileURLWithPath: "/tmp/x"),
        githubURL: URL(string: "https://github.com/acme")!,
        remoteAgentID: 42
    )
    let runners = [
        RunnerRegistration.RegisteredRunner(id: 42, name: "mac", labels: ["self-hosted"], status: "online", busy: false),
        RunnerRegistration.RegisteredRunner(id: 99, name: "mac", labels: ["self-hosted"], status: "online", busy: true)
    ]
    let observation = GitHubRunnerObserver.match(definition: definition, runners: runners)
    #expect(observation?.busy == false)
    #expect(observation?.busyKnown == true)
    #expect(observation?.online == true)
}

@Test func observerRefusesContradictionAndForeignName() {
    let definition = Runners.Definition(
        id: "actions.runner.test.x", title: "mac", detail: "acme",
        directory: URL(fileURLWithPath: "/tmp/x"),
        githubURL: URL(string: "https://github.com/acme")!,
        remoteAgentID: 42
    )
    // Same ID renamed: contradiction, no attach.
    let renamed = [RunnerRegistration.RegisteredRunner(id: 42, name: "other", labels: [], status: "online", busy: false)]
    #expect(GitHubRunnerObserver.match(definition: definition, runners: renamed) == nil)
    // Agent absent but a same-name foreign runner exists: must not adopt it.
    let foreign = [RunnerRegistration.RegisteredRunner(id: 99, name: "mac", labels: [], status: "online", busy: true)]
    let absent = GitHubRunnerObserver.match(definition: definition, runners: foreign)
    #expect(absent?.busyKnown == false)
    let absentErr = absent?.syncError ?? ""
    #expect(absentErr.contains("not listed"))
}

@Test func staleBusyFalseIsNotIdleProof() {
    let now = Date()
    let fresh = Runners.RemoteObservation(online: true, busy: false, busyKnown: true, updatedAt: now, stale: false)
    #expect(GitHubRunnerObserver.isStale(fresh, now: now) == false)
    #expect(Runners.StopConfirmation.mayInterrupt(remote: fresh) == false)
    #expect(Runners.StopConfirmation.message(remote: fresh, runnerTitle: "mac").contains("свободен"))
    let old = Runners.RemoteObservation(online: true, busy: false, busyKnown: true, updatedAt: now.addingTimeInterval(-61), stale: false)
    #expect(GitHubRunnerObserver.isStale(old, now: now) == true)
    let marked = GitHubRunnerObserver.withFreshness(old, now: now)
    #expect(marked.stale == true)
    #expect(marked.busyKnown == false)
    #expect(Runners.StopConfirmation.mayInterrupt(remote: marked) == true)
    #expect(Runners.StopConfirmation.message(remote: marked, runnerTitle: "mac").contains("неизвестна"))
    // Disconnected and busy are both interrupt-risky.
    #expect(Runners.StopConfirmation.mayInterrupt(remote: nil) == true)
    let busy = Runners.RemoteObservation(online: true, busy: true, busyKnown: true, updatedAt: now, stale: false)
    #expect(Runners.StopConfirmation.mayInterrupt(remote: busy) == true)
    #expect(Runners.StopConfirmation.message(remote: busy, runnerTitle: "mac").contains("выполняется задача"))
}

// MARK: - Remote sync keeps local (AC row 14)

@Test func refreshRemoteKeepsLocalOnOffline() async throws {
    let harness = await catalogHarness(
        launchResults: [CommandResult(code: 0, output: "state = running")],
        transportResponses: []
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: "actions.runner.test.r")
    let entry = RunnerCatalogStore.Entry(
        directoryPath: dir.path, canonicalPath: RunnerCatalogStore.canonical(dir),
        serviceLabel: "actions.runner.test.r",
        servicePlistPath: dir.appendingPathComponent("manual-service.plist").path,
        controllerKind: .manualManaged, serverHost: "github.com",
        scopeKind: "org", scope: "acme", remoteAgentID: 42, agentName: "r", workFolder: "_work"
    )
    try await harness.catalog.add(entry)
    // Empty transport queue throws invalidResponse -> network failure, never a local change.
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.refreshRemote)
    let actions = runnersActions(harness.logger)
    #expect(actions.contains { if case .remoteSyncFailed = $0 { true } else { false } })
    // Local still observable via launchctl mock.
    let snapshots = await harness.service.snapshots()
    #expect(snapshots.first?.status == .running)
    #expect(await harness.transport.requests.count >= 1)
}

@Test func offlineLocalControlWithoutToken() async throws {
    let harness = await catalogHarness(
        launchResults: [
            CommandResult(code: 113, output: "Could not find service x"),
            CommandResult(code: 0, output: ""),
            CommandResult(code: 0, output: "state = running"),
            CommandResult(code: 0, output: "state = running")
        ],
        seedAuth: false
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", label: "actions.runner.test.offline")
    let entry = RunnerCatalogStore.Entry(
        directoryPath: dir.path, canonicalPath: RunnerCatalogStore.canonical(dir),
        serviceLabel: "actions.runner.test.offline",
        servicePlistPath: dir.appendingPathComponent("manual-service.plist").path,
        controllerKind: .manualManaged, serverHost: "github.com",
        scopeKind: "org", scope: "acme", remoteAgentID: 42, agentName: "r", workFolder: "_work"
    )
    try await harness.catalog.add(entry)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.setEnabled("actions.runner.test.offline", true))
    #expect(lastFailureMessage(harness.logger) == nil)
    #expect(await harness.transport.requests.isEmpty)
}

// MARK: - Catalog removal (AC row 11)

@Test func removeDeletesOnlyEntryAndWarnsWhenRunning() async throws {
    let harness = await catalogHarness(launchResults: [
        CommandResult(code: 0, output: "state = running"),
        CommandResult(code: 0, output: "state = running")
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", label: "actions.runner.test.rm")
    let entry = RunnerCatalogStore.Entry(
        directoryPath: dir.path, canonicalPath: RunnerCatalogStore.canonical(dir),
        serviceLabel: "actions.runner.test.rm",
        servicePlistPath: dir.appendingPathComponent("manual-service.plist").path,
        controllerKind: .manualManaged, agentName: "r"
    )
    try await harness.catalog.add(entry)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.removeFromApp("actions.runner.test.rm"))
    #expect(await harness.catalog.load().isEmpty)
    // Files, registration and manifest untouched.
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".runner").path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manual-service.plist").path))
    #expect(catalogErr(harness.logger).contains("keeps running"))
}

// MARK: - Unregister binds local identity (AC row 11)

private func unregisterEntry(dir: URL, label: String, agentID: Int64 = 42, agentName: String = "r") -> RunnerCatalogStore.Entry {
    RunnerCatalogStore.Entry(
        directoryPath: dir.path, canonicalPath: RunnerCatalogStore.canonical(dir),
        serviceLabel: label,
        servicePlistPath: dir.appendingPathComponent("manual-service.plist").path,
        controllerKind: .manualManaged, serverHost: "github.com",
        scopeKind: "org", scope: "acme", remoteAgentID: agentID, agentName: agentName, workFolder: "_work"
    )
}

@Test func unregisterRefusesWrongConfirmationWithoutAPICall() async throws {
    let harness = await catalogHarness(launchResults: [
        CommandResult(code: 113, output: "Could not find service x")
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", agentName: "my-runner", scope: "acme", agentID: 42, label: "actions.runner.test.unreg")
    try await harness.catalog.add(unregisterEntry(dir: dir, label: "actions.runner.test.unreg", agentName: "my-runner"))
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.unregister("actions.runner.test.unreg", confirmation: "wrong"))
    #expect(catalogErr(harness.logger).contains("Type 'my-runner'"))
    #expect(await harness.transport.requests.isEmpty)
    #expect(await harness.installerExecutor.calls.isEmpty)
}

@Test func unregisterRefusesRunningService() async throws {
    let harness = await catalogHarness(launchResults: [
        CommandResult(code: 0, output: "state = running")
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", agentName: "r", scope: "acme", label: "actions.runner.test.running")
    try await harness.catalog.add(unregisterEntry(dir: dir, label: "actions.runner.test.running"))
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.unregister("actions.runner.test.running", confirmation: "r"))
    #expect(catalogErr(harness.logger).contains("Stop the runner first"))
    #expect(await harness.transport.requests.isEmpty)
}

@Test func unregisterRefusesNameWithoutVerifiedAgentID() async throws {
    let harness = await catalogHarness()
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", label: "actions.runner.test.noname")
    // Strip the agent ID: a bare name must never authorize removal.
    let config: [String: Any] = ["agentName": "r", "gitHubUrl": "https://github.com/acme", "workFolder": "_work"]
    try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent(".runner"))
    var entry = unregisterEntry(dir: dir, label: "actions.runner.test.noname")
    entry.remoteAgentID = nil
    try await harness.catalog.add(entry)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.unregister("actions.runner.test.noname", confirmation: "r"))
    #expect(catalogErr(harness.logger).contains("verified local registration"))
    #expect(await harness.transport.requests.isEmpty)
}

@Test func unregisterRefusesStoredIDMismatchAndCrossServer() async throws {
    // Stored-vs-disk mismatch.
    let mismatch = await catalogHarness()
    defer { try? FileManager.default.removeItem(at: mismatch.home) }
    let mismatchDir = try makeRunnerDir(parent: mismatch.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: "actions.runner.test.mismatch")
    var entry = unregisterEntry(dir: mismatchDir, label: "actions.runner.test.mismatch")
    entry.remoteAgentID = 99
    try await mismatch.catalog.add(entry)
    let _: Relux.ActionResult = await mismatch.flow.apply(Runners.Effect.unregister("actions.runner.test.mismatch", confirmation: "r"))
    #expect(catalogErr(mismatch.logger).contains("mismatched registration"))
    #expect(await mismatch.transport.requests.isEmpty)
    // Cross-server: disk points at another host, auth is github.com.
    let cross = await catalogHarness()
    defer { try? FileManager.default.removeItem(at: cross.home) }
    let crossDir = try makeRunnerDir(parent: cross.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: "actions.runner.test.cross")
    let foreign: [String: Any] = ["agentId": 42, "agentName": "r", "gitHubUrl": "https://ghe.example.com/acme", "workFolder": "_work"]
    try JSONSerialization.data(withJSONObject: foreign).write(to: crossDir.appendingPathComponent(".runner"))
    // Need stopped status before the server check runs.
    let stoppedHarness = await catalogHarness(launchResults: [CommandResult(code: 113, output: "Could not find service x")])
    defer { try? FileManager.default.removeItem(at: stoppedHarness.home) }
    // Reuse the cross dir files by copying .runner content into the stopped harness entry.
    let stoppedDir = try makeRunnerDir(parent: stoppedHarness.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: "actions.runner.test.cross")
    try JSONSerialization.data(withJSONObject: foreign).write(to: stoppedDir.appendingPathComponent(".runner"))
    try await stoppedHarness.catalog.add(unregisterEntry(dir: stoppedDir, label: "actions.runner.test.cross"))
    let _: Relux.ActionResult = await stoppedHarness.flow.apply(Runners.Effect.unregister("actions.runner.test.cross", confirmation: "r"))
    #expect(catalogErr(stoppedHarness.logger).contains("not the signed-in server"))
}

@Test func unregisterRemovesRemoteKeepsFilesAndEntry() async throws {
    let harness = await catalogHarness(
        launchResults: [
            // Pre-check stopped, boundary revalidation stopped, post-op refresh.
            CommandResult(code: 113, output: "Could not find service x"),
            CommandResult(code: 113, output: "Could not find service x"),
            CommandResult(code: 113, output: "Could not find service x")
        ],
        installerResults: [CommandResult(code: 0, output: "remove ok")],
        transportResponses: [removeTokenPayload()]
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: "actions.runner.test.ok")
    try await harness.catalog.add(unregisterEntry(dir: dir, label: "actions.runner.test.ok"))
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.unregister("actions.runner.test.ok", confirmation: "r"))
    #expect(lastCatalogFailure(harness.logger) == nil)
    // Remove token minted for the verified scope, config.sh remove ran with it.
    let requests = await harness.transport.requests
    #expect(requests.count == 1)
    #expect(requests.first?.url.path.contains("/orgs/acme/actions/runners/remove-token") == true)
    let installerCalls = await harness.installerExecutor.calls
    #expect(installerCalls.count == 1)
    #expect(installerCalls.first?.contains("remove") == true)
    // Token never leaks into the catalog or the success path.
    let entries = await harness.catalog.load()
    #expect(entries.count == 1)
    #expect(entries.first?.remoteAgentID == nil)
    #expect(FileManager.default.fileExists(atPath: dir.path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manual-service.plist").path))
}

// MARK: - Installer lease (AC row 11)

@Test func installerLeaseSerializesUnregisterAndInstall() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lease-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = RunnerInstallerService(
        installRoot: root,
        downloader: { _ in
            try await Task.sleep(for: .seconds(2))
            return Data()
        },
        executor: FakeExecutor([])
    )
    let draft = RunnerRegistration.Draft(scope: .organization(org: "acme"), runnerName: "r", installDirName: "a", groupName: "g")
    let asset = RunnerRegistration.DownloadAsset(
        osName: RunnerInstallerService.installOS, architecture: installer.architecture,
        downloadURL: URL(string: "https://example.com/pkg.tar.gz")!, filename: "pkg.tar.gz",
        sha256Checksum: String(repeating: "a", count: 64)
    )
    let first = Task { try await installer.downloadAndInstall(asset: asset, draft: draft, serverHost: "github.com") }
    try? await Task.sleep(for: .milliseconds(200))
    // Second mutation on ANY directory is refused while the first holds the lease.
    let otherDir = root.appendingPathComponent("b")
    do {
        try await installer.unregister(directory: otherDir, removeToken: "t")
        Issue.record("Installer admitted a second mutation while busy")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .installerBusy = error else {
            Issue.record("Wrong busy error: \(error)"); first.cancel(); return
        }
    }
    first.cancel()
    _ = try? await first.value
}

// MARK: - Diagnostics (AC row 9)

@Test func diagnosticsResolvesManifestPathsAndRedacts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Diag-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = try makeRunnerDir(parent: root, name: "r", label: "actions.runner.test.diag")
    let logs = root.appendingPathComponent("custom-logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let stdout = logs.appendingPathComponent("stdout.log")
    let stderr = logs.appendingPathComponent("stderr.log")
    try "hello secret-token-abc {\"access_token\":\"tok-123\"}\nline2\n".write(to: stdout, atomically: true, encoding: .utf8)
    try "err\n".write(to: stderr, atomically: true, encoding: .utf8)
    var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: dir.appendingPathComponent("manual-service.plist")), format: nil) as! [String: Any]
    plist["StandardOutPath"] = stdout.path
    plist["StandardErrorPath"] = stderr.path
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: dir.appendingPathComponent("manual-service.plist"))
    let definition = Runners.Definition(
        id: "actions.runner.test.diag", title: "r", detail: "acme",
        directory: dir, githubURL: URL(string: "https://github.com/acme")!,
        servicePlist: dir.appendingPathComponent("manual-service.plist")
    )
    let files = RunnerDiagnostics.logFiles(definition: definition)
    #expect(files.first == stdout)
    #expect(!files.contains(definition.logs))
    let tail = RunnerDiagnostics.tail(definition: definition, secrets: ["secret-token-abc"])
    #expect(!tail.contains("secret-token-abc"))
    #expect(!tail.contains("tok-123"))
    #expect(tail.contains("[REDACTED]"))
}

// MARK: - Login policy, relink, alias (AC rows 1, 10)

@Test func standardPolicyChangePreservesManifestAndSkipsLaunchctl() async throws {
    let harness = await catalogHarness(launchResults: [
        CommandResult(code: 113, output: "Could not find service x")
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let agents = harness.home.appendingPathComponent("Library/LaunchAgents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let dir = try makeRunnerDir(parent: harness.home, name: "r", runAtLoad: true, withPlist: false, label: "actions.runner.test.policy")
    let manifest = agents.appendingPathComponent("actions.runner.test.policy.plist")
    let plistBody: [String: Any] = [
        "Label": "actions.runner.test.policy",
        "WorkingDirectory": dir.path,
        "ProgramArguments": [dir.appendingPathComponent("runsvc.sh").path],
        "RunAtLoad": true
    ]
    try PropertyListSerialization.data(fromPropertyList: plistBody, format: .xml, options: 0).write(to: manifest)
    var entry = unregisterEntry(dir: dir, label: "actions.runner.test.policy")
    entry.servicePlistPath = manifest.path
    entry.controllerKind = .standardLaunchAgent
    entry.runAtLoad = true
    try await harness.catalog.add(entry)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.setRunAtLoad("actions.runner.test.policy", false))
    #expect(catalogErr(harness.logger).isEmpty)
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: manifest), format: nil) as! [String: Any]
    #expect((plist["RunAtLoad"] as? Bool) == false)
    #expect(plist["Label"] as? String == "actions.runner.test.policy")
    let entries = await harness.catalog.load()
    #expect(entries.first?.runAtLoad == false)
    for call in await harness.launchExecutor.calls {
        #expect(!call.contains("bootstrap") && !call.contains("bootout"))
    }
}

@Test func manualExternalRunAtLoadTrueDisplaysLoginOff() async throws {
    // Production defect shape: external manual plist says RunAtLoad=true
    // but no LaunchAgents registration exists. Effective login is OFF while
    // the preserved import policy stays visible as info.
    let harness = await catalogHarness(launchResults: [
        CommandResult(code: 0, output: "state = running")
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", runAtLoad: true, label: "actions.runner.test.ext")
    var entry = unregisterEntry(dir: dir, label: "actions.runner.test.ext")
    entry.controllerKind = .manualManaged
    entry.runAtLoad = true
    try await harness.catalog.add(entry)
    let snapshots = await harness.service.snapshots()
    #expect(snapshots.first?.status == .running)
    #expect(snapshots.first?.definition.runAtLoad == true)
    #expect(snapshots.first?.definition.loginEnabled == false)
}

@Test func standardManifestShowsActualPolicy() async throws {
    let harness = await catalogHarness(launchResults: [
        CommandResult(code: 113, output: "Could not find service x")
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let agents = harness.home.appendingPathComponent("Library/LaunchAgents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let dir = try makeRunnerDir(parent: harness.home, name: "r", withPlist: false, label: "actions.runner.test.std")
    let manifest = agents.appendingPathComponent("actions.runner.test.std.plist")
    let body: [String: Any] = [
        "Label": "actions.runner.test.std",
        "WorkingDirectory": dir.path,
        "ProgramArguments": [dir.appendingPathComponent("runsvc.sh").path],
        "RunAtLoad": false
    ]
    try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0).write(to: manifest)
    var entry = unregisterEntry(dir: dir, label: "actions.runner.test.std")
    entry.servicePlistPath = manifest.path
    entry.controllerKind = .standardLaunchAgent
    try await harness.catalog.add(entry)
    let snapshots = await harness.service.snapshots()
    #expect(snapshots.first?.definition.loginEnabled == false)
}

@Test func manualToggleOnRegistersLoginWithoutChangingLiveState() async throws {
    let harness = await catalogHarness(launchResults: [
        CommandResult(code: 0, output: "state = running"),
        CommandResult(code: 0, output: "state = running")
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", runAtLoad: true, label: "actions.runner.test.reg")
    var entry = unregisterEntry(dir: dir, label: "actions.runner.test.reg")
    entry.controllerKind = .manualManaged
    entry.runAtLoad = true
    try await harness.catalog.add(entry)
    let before = try Data(contentsOf: dir.appendingPathComponent("manual-service.plist"))
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.setRunAtLoad("actions.runner.test.reg", true))
    #expect(catalogErr(harness.logger).isEmpty)
    // Registration created with the same service identity and RunAtLoad true.
    let copy = harness.home.appendingPathComponent("Library/LaunchAgents/actions.runner.test.reg.plist")
    let reg = try PropertyListSerialization.propertyList(from: Data(contentsOf: copy), format: nil) as! [String: Any]
    #expect(reg["Label"] as? String == "actions.runner.test.reg")
    #expect(reg["WorkingDirectory"] as? String == dir.path)
    #expect((reg["ProgramArguments"] as? [String]) == [dir.appendingPathComponent("runsvc.sh").path])
    #expect((reg["RunAtLoad"] as? Bool) == true)
    // External service file byte-identical; live state untouched.
    #expect(try Data(contentsOf: dir.appendingPathComponent("manual-service.plist")) == before)
    for call in await harness.launchExecutor.calls {
        #expect(!call.contains("bootstrap") && !call.contains("bootout"))
    }
    // Idempotent second enable keeps working.
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.setRunAtLoad("actions.runner.test.reg", true))
    #expect(catalogErr(harness.logger).isEmpty)
}

@Test func manualToggleOffUnregistersLoginWithoutStopping() async throws {
    let harness = await catalogHarness(launchResults: [
        CommandResult(code: 0, output: "state = running"),
        CommandResult(code: 0, output: "state = running"),
        CommandResult(code: 0, output: "state = running")
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", runAtLoad: true, label: "actions.runner.test.unreg2")
    var entry = unregisterEntry(dir: dir, label: "actions.runner.test.unreg2")
    entry.controllerKind = .manualManaged
    entry.runAtLoad = true
    try await harness.catalog.add(entry)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.setRunAtLoad("actions.runner.test.unreg2", true))
    let copy = harness.home.appendingPathComponent("Library/LaunchAgents/actions.runner.test.unreg2.plist")
    #expect(FileManager.default.fileExists(atPath: copy.path))
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.setRunAtLoad("actions.runner.test.unreg2", false))
    #expect(catalogErr(harness.logger).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: copy.path))
    for call in await harness.launchExecutor.calls {
        #expect(!call.contains("bootstrap") && !call.contains("bootout"))
    }
    // Idempotent disable when nothing is registered.
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.setRunAtLoad("actions.runner.test.unreg2", false))
    #expect(catalogErr(harness.logger).isEmpty)
}

@Test func manualToggleRefusesForeignPlist() async throws {
    let harness = await catalogHarness()
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", runAtLoad: true, label: "actions.runner.test.foreign")
    var entry = unregisterEntry(dir: dir, label: "actions.runner.test.foreign")
    entry.controllerKind = .manualManaged
    try await harness.catalog.add(entry)
    let agents = harness.home.appendingPathComponent("Library/LaunchAgents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let foreign: [String: Any] = [
        "Label": "actions.runner.test.foreign",
        "WorkingDirectory": "/elsewhere",
        "ProgramArguments": ["/bin/false"],
        "RunAtLoad": true
    ]
    let copy = agents.appendingPathComponent("actions.runner.test.foreign.plist")
    try PropertyListSerialization.data(fromPropertyList: foreign, format: .xml, options: 0).write(to: copy)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.setRunAtLoad("actions.runner.test.foreign", true))
    #expect(catalogErr(harness.logger).contains("belongs to another service"))
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.setRunAtLoad("actions.runner.test.foreign", false))
    #expect(catalogErr(harness.logger).contains("belongs to another service"))
    // Foreign file untouched in both directions.
    let kept = try PropertyListSerialization.propertyList(from: Data(contentsOf: copy), format: nil) as! [String: Any]
    #expect(kept["WorkingDirectory"] as? String == "/elsewhere")
}

@Test func relinkRequiresSameAgent() async throws {
    let harness = await catalogHarness()
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let a = try makeRunnerDir(parent: harness.home, name: "a", agentName: "r", scope: "acme", agentID: 42, label: "actions.runner.test.relink")
    let b = try makeRunnerDir(parent: harness.home, name: "b", agentName: "r", scope: "acme", agentID: 99, label: "actions.runner.test.other")
    try await harness.catalog.add(unregisterEntry(dir: a, label: "actions.runner.test.relink"))
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.relinkDirectory("actions.runner.test.relink", b))
    #expect(catalogErr(harness.logger).contains("not 42"))
    #expect(await harness.catalog.load().first?.directoryPath == a.path)
}

@Test func aliasDoesNotChangeIdentity() async throws {
    let harness = await catalogHarness(launchResults: [CommandResult(code: 113, output: "Could not find service x")])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", agentName: "real-name", label: "actions.runner.test.alias")
    let entry = RunnerCatalogStore.Entry(
        directoryPath: dir.path, canonicalPath: RunnerCatalogStore.canonical(dir),
        serviceLabel: "actions.runner.test.alias",
        servicePlistPath: dir.appendingPathComponent("manual-service.plist").path,
        controllerKind: .manualManaged, agentName: "real-name"
    )
    try await harness.catalog.add(entry)
    let localID = entry.localID
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.setAlias("actions.runner.test.alias", "My CI"))
    let loaded = await harness.catalog.load()
    #expect(loaded.first?.displayName == "My CI")
    #expect(loaded.first?.localID == localID)
    #expect(loaded.first?.agentName == "real-name")
    let definition = Runners.Definition(
        id: "actions.runner.test.alias", title: "real-name", detail: "acme",
        directory: dir, githubURL: URL(string: "https://github.com/acme")!,
        displayName: "My CI"
    )
    #expect(definition.displayTitle == "My CI")
}

// MARK: - Direct gate narrowing (mutant targets)

@Test func importGateRefusesSpacedPathDirectly() {
    // Crafted candidate isolates the explicit no-space check from the generic
    // issues check: spaced path, empty issues, every other check valid.
    let dir = URL(fileURLWithPath: "/tmp/spaced root/runner")
    let candidate = RunnerDiscovery.Candidate(
        directory: dir,
        manifest: dir.appendingPathComponent("manual-service.plist"),
        label: "actions.runner.test.x",
        controllerKind: .manualManaged,
        agentName: "r", scope: "acme", serverHost: "github.com",
        agentID: 1, workFolder: "_work", runAtLoad: false,
        runsvcExists: true, binaryExists: true,
        registrationReadable: true, manifestMatches: true,
        noSpacePath: false, noSpaceWork: true,
        issues: []
    )
    do {
        try RunnersCatalogGates.validateImportable(candidate)
        Issue.record("Import gate admitted a spaced install path")
    } catch let error as RunnerError {
        guard case .noSpacePath = error else {
            Issue.record("Wrong no-space error: \(error)"); return
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

// MARK: - Group access uses fresh API membership (imported drift)

private func groupsPayload(_ groups: [(Int64, String)]) -> GitHubHTTPResponse {
    jsonResponse(["runner_groups": groups.map { id, name in
        ["id": id, "name": name, "visibility": "selected", "allows_public_repositories": true] as [String: Any]
    }])
}

private func groupRunnersPayload(_ runners: [(Int64, String, Bool)]) -> GitHubHTTPResponse {
    jsonResponse(["runners": runners.map { id, name, busy in
        ["id": id, "name": name, "labels": [], "status": "online", "busy": busy] as [String: Any]
    }])
}

private func groupReposPayload(_ ids: [Int64]) -> GitHubHTTPResponse {
    jsonResponse(["repositories": ids.map { ["id": $0] }])
}

private func loadedGroupAccess(_ logger: Relux.Testing.Logger, id: String) -> Runners.GroupAccess? {
    for action in runnersActions(logger).reversed() {
        if case .groupAccessLoaded(let loadedID, let access) = action, loadedID == id {
            return access
        }
    }
    return nil
}

private func groupAccessError(_ logger: Relux.Testing.Logger, id: String) -> String? {
    for action in runnersActions(logger).reversed() {
        if case .groupAccessFailed(let failedID, let message) = action, failedID == id {
            return message
        }
        if case .groupAccessInvalidated(let failedID, let message) = action, failedID == id {
            return message
        }
    }
    return nil
}

@Test func groupAccessUsesFreshAPIMembershipNotStalePool() async throws {
    // Local .runner carries stale pool3 fields; fresh API puts ID39 in group4.
    // Same-name foreign ID99 sits in group3 and must never be adopted.
    let harness = await catalogHarness(transportResponses: [
        groupsPayload([(3, "old-group"), (4, "current-group")]),
        groupRunnersPayload([(99, "macbook-iv", false)]),
        groupRunnersPayload([(39, "macbook-iv", true)]),
        groupReposPayload([101, 102])
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = harness.home.appendingPathComponent("r")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stale: [String: Any] = [
        "agentId": 39, "agentName": "macbook-iv",
        "poolId": 3, "poolName": "rose-air-projects",
        "gitHubUrl": "https://github.com/acme", "workFolder": "_work"
    ]
    try JSONSerialization.data(withJSONObject: stale).write(to: dir.appendingPathComponent(".runner"))
    try "#!/bin/sh\nexit 0\n".write(to: dir.appendingPathComponent("runsvc.sh"), atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexit 0\n".write(to: dir.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
    let manifest: [String: Any] = [
        "Label": "actions.runner.test.drift",
        "ProgramArguments": [dir.appendingPathComponent("runsvc.sh").path],
        "WorkingDirectory": dir.path, "RunAtLoad": false
    ]
    try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        .write(to: dir.appendingPathComponent("manual-service.plist"))
    let entry = RunnerCatalogStore.Entry(
        directoryPath: dir.path, canonicalPath: RunnerCatalogStore.canonical(dir),
        serviceLabel: "actions.runner.test.drift",
        servicePlistPath: dir.appendingPathComponent("manual-service.plist").path,
        controllerKind: .manualManaged, serverHost: "github.com",
        scopeKind: "org", scope: "acme", remoteAgentID: 39,
        agentName: "macbook-iv", workFolder: "_work"
    )
    try await harness.catalog.add(entry)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.loadGroupAccess("actions.runner.test.drift"))
    let access = loadedGroupAccess(harness.logger, id: "actions.runner.test.drift")
    #expect(access?.group?.id == 4)
    #expect(access?.group?.name == "current-group")
    #expect(access?.repoIDs == [101, 102])
    #expect(access?.owned == false)
    #expect(groupAccessError(harness.logger, id: "actions.runner.test.drift") == nil)
}

@Test func groupAccessRefusesRepoScope() async throws {
    let harness = await catalogHarness()
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", agentName: "r", scope: "acme/app", label: "actions.runner.test.repo")
    let entry = RunnerCatalogStore.Entry(
        directoryPath: dir.path, canonicalPath: RunnerCatalogStore.canonical(dir),
        serviceLabel: "actions.runner.test.repo",
        servicePlistPath: dir.appendingPathComponent("manual-service.plist").path,
        controllerKind: .manualManaged, serverHost: "github.com",
        scopeKind: "repo", scope: "acme/app", remoteAgentID: 42, agentName: "r", workFolder: "_work"
    )
    try await harness.catalog.add(entry)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.loadGroupAccess("actions.runner.test.repo"))
    let err = groupAccessError(harness.logger, id: "actions.runner.test.repo") ?? ""
    #expect(err.contains("organization runners only"))
    #expect(await harness.transport.requests.isEmpty)
}

@Test func applyGroupAccessRequiresTakeoverForShared() async throws {
    let harness = await catalogHarness(transportResponses: [
        groupsPayload([(4, "team-group")]),
        groupRunnersPayload([(42, "r", false)]),
        groupReposPayload([1])
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: "actions.runner.test.shared")
    try await harness.catalog.add(unregisterEntry(dir: dir, label: "actions.runner.test.shared"))
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.loadGroupAccess("actions.runner.test.shared"))
    #expect(loadedGroupAccess(harness.logger, id: "actions.runner.test.shared")?.owned == false)
    // Without takeover: refused before any PUT.
    await harness.transport.append(groupsPayload([(4, "team-group")]))
    await harness.transport.append(groupRunnersPayload([(42, "r", false)]))
    let _: Relux.ActionResult = await harness.flow.apply(
        Runners.Effect.applyGroupAccess("actions.runner.test.shared", groupID: 4, repositories: [1, 2], allowTakeover: false)
    )
    let refused = groupAccessError(harness.logger, id: "actions.runner.test.shared") ?? ""
    #expect(refused.contains("team-group"))
    #expect(await harness.transport.requests.filter { $0.method == "PUT" }.isEmpty)
    // With explicit takeover: ownership recorded, PUT applied, confirmation re-fetched.
    await harness.transport.append(groupsPayload([(4, "team-group")]))
    await harness.transport.append(groupRunnersPayload([(42, "r", false)]))
    await harness.transport.append(GitHubHTTPResponse(status: 204, body: Data()))
    await harness.transport.append(groupReposPayload([1, 2]))
    let _: Relux.ActionResult = await harness.flow.apply(
        Runners.Effect.applyGroupAccess("actions.runner.test.shared", groupID: 4, repositories: [1, 2], allowTakeover: true)
    )
    // Success is proven by the fresh loaded access below; the action log
    // retains the earlier refusal by design.
    let access = loadedGroupAccess(harness.logger, id: "actions.runner.test.shared")
    #expect(access?.repoIDs == [1, 2])
    #expect(access?.owned == true)
    #expect(await harness.transport.requests.filter { $0.method == "PUT" }.count == 1)
}

@Test func applyGroupAccessRefusesStaleGroup() async throws {
    let harness = await catalogHarness(transportResponses: [
        groupsPayload([(4, "g4")]),
        groupRunnersPayload([(42, "r", false)]),
        groupReposPayload([1])
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: "actions.runner.test.stalegroup")
    try await harness.catalog.add(unregisterEntry(dir: dir, label: "actions.runner.test.stalegroup"))
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.loadGroupAccess("actions.runner.test.stalegroup"))
    #expect(loadedGroupAccess(harness.logger, id: "actions.runner.test.stalegroup")?.group?.id == 4)
    // Fresh membership now shows the runner in group5: the UI group4 is stale.
    await harness.transport.append(groupsPayload([(4, "g4"), (5, "g5")]))
    await harness.transport.append(groupRunnersPayload([]))
    await harness.transport.append(groupRunnersPayload([(42, "r", false)]))
    let _: Relux.ActionResult = await harness.flow.apply(
        Runners.Effect.applyGroupAccess("actions.runner.test.stalegroup", groupID: 4, repositories: [1, 2], allowTakeover: true)
    )
    let err = groupAccessError(harness.logger, id: "actions.runner.test.stalegroup") ?? ""
    #expect(err.contains("moved from group 4"))
    #expect(await harness.transport.requests.filter { $0.method == "PUT" }.isEmpty)
}

@Test func applyGroupAccessConfirmsExactRepos() async throws {
    let harness = await catalogHarness(transportResponses: [
        groupsPayload([(4, "g4")]),
        groupRunnersPayload([(42, "r", false)]),
        groupReposPayload([1])
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: "actions.runner.test.confirm")
    try await harness.catalog.add(unregisterEntry(dir: dir, label: "actions.runner.test.confirm"))
    try await harness.installer.saveOwnedGroupID(serverHost: "github.com", org: "acme", name: "g4", groupID: 4)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.loadGroupAccess("actions.runner.test.confirm"))
    #expect(loadedGroupAccess(harness.logger, id: "actions.runner.test.confirm")?.owned == true)
    await harness.transport.append(groupsPayload([(4, "g4")]))
    await harness.transport.append(groupRunnersPayload([(42, "r", false)]))
    await harness.transport.append(GitHubHTTPResponse(status: 204, body: Data()))
    await harness.transport.append(groupReposPayload([1]))
    let _: Relux.ActionResult = await harness.flow.apply(
        Runners.Effect.applyGroupAccess("actions.runner.test.confirm", groupID: 4, repositories: [1, 2], allowTakeover: false)
    )
    let err = groupAccessError(harness.logger, id: "actions.runner.test.confirm") ?? ""
    #expect(err.contains("confirmed repositories"))
}

// MARK: - R2 reviewer regressions (rev1 verdict, adopted probes + bounds)

// The four exact reviewer probes, adopted as maintained production-entry
// regressions. Each failed on the rev1 candidate (exit 1) and passes now.

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

// MARK: - R2 bounds: revalidation, session preservation, control, persistence

/// F1 bound: a service that starts (or is lost to inspection) after the
/// token mint must not reach `config.sh remove`. The boundary revalidation
/// refuses; the installer never runs and the entry keeps its registration.
@Test func unregisterRevalidatesStoppedAtSideEffectBoundary() async throws {
    let harness = await catalogHarness(
        launchResults: [
            CommandResult(code: 113, output: "Could not find service x"),
            CommandResult(code: 0, output: "state = running")
        ],
        installerResults: [CommandResult(code: 0, output: "ok")],
        transportResponses: [removeTokenPayload()]
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", agentName: "r", scope: "acme", label: "actions.runner.test.revalidate")
    try await harness.catalog.add(unregisterEntry(dir: dir, label: "actions.runner.test.revalidate"))
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.unregister("actions.runner.test.revalidate", confirmation: "r"))
    #expect(catalogErr(harness.logger).contains("Stop the runner first"))
    #expect(await harness.installerExecutor.calls.isEmpty)
    #expect(await harness.catalog.load().first?.remoteAgentID == 42)
}

/// Session double that returns `first` for the first `flipAfter` loads and
/// `later` afterwards: a deterministic mid-operation logout.
private final class FlippingSessionStore: GitHubSessionIdentityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0
    private let flipAfter: Int
    private var first: GitHubSessionIdentity?
    private var later: GitHubSessionIdentity?
    init(first: GitHubSessionIdentity?, later: GitHubSessionIdentity?, flipAfter: Int) {
        self.first = first
        self.later = later
        self.flipAfter = flipAfter
    }
    func save(_ identity: GitHubSessionIdentity) async {
        lock.withLock { first = identity; later = identity }
    }
    func load() async -> GitHubSessionIdentity? {
        lock.withLock {
            loads += 1
            return loads <= flipAfter ? first : later
        }
    }
    func delete() async {
        lock.withLock { first = nil; later = nil }
    }
}

/// F2 bound: a logout between the membership reads and the PUT refuses the
/// write and releases the editor with an explicit retry message — reads
/// happened, the write never fires into a dead session, no stale data is
/// published, and the busy state does not wedge.
/// Identity load order in apply: started(1), auth(2), post-auth check(3),
/// pre-PUT check(4); the flip lands on the pre-PUT check.
@Test func applyGroupAccessStopsWhenSessionChangesMidApply() async throws {
    let session = GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo")
    let flipping = FlippingSessionStore(first: session, later: nil, flipAfter: 3)
    let harness = await catalogHarness(
        transportResponses: [
            groupsPayload([(4, "g4")]),
            groupRunnersPayload([(42, "r", false)])
        ],
        identitiesOverride: flipping
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: "actions.runner.test.sessionflip")
    try await harness.catalog.add(unregisterEntry(dir: dir, label: "actions.runner.test.sessionflip"))
    let _: Relux.ActionResult = await harness.flow.apply(
        Runners.Effect.applyGroupAccess("actions.runner.test.sessionflip", groupID: 4, repositories: [1, 2], allowTakeover: true)
    )
    let requests = await harness.transport.requests
    #expect(requests.count == 2)
    #expect(requests.filter { $0.method == "PUT" }.isEmpty)
    #expect(loadedGroupAccess(harness.logger, id: "actions.runner.test.sessionflip") == nil)
    let cleanup = groupAccessError(harness.logger, id: "actions.runner.test.sessionflip") ?? ""
    #expect(cleanup.contains("session changed") && cleanup.contains("Reload group access"))
}

/// F2 bound: a server switch between the membership reads and the PUT
/// also refuses the write and releases the editor with an explicit retry
/// message, even when the user ID is unchanged.
@Test func applyGroupAccessStopsWhenServerSwitchesMidApply() async throws {
    let first = GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo")
    let switched = GitHubSessionIdentity(serverHost: "ghe.example.com", userID: 42, clientID: testConfig.clientID, username: "octo")
    let flipping = FlippingSessionStore(first: first, later: switched, flipAfter: 3)
    let harness = await catalogHarness(
        transportResponses: [
            groupsPayload([(4, "g4")]),
            groupRunnersPayload([(42, "r", false)])
        ],
        identitiesOverride: flipping
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let dir = try makeRunnerDir(parent: harness.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: "actions.runner.test.serverswitch")
    try await harness.catalog.add(unregisterEntry(dir: dir, label: "actions.runner.test.serverswitch"))
    let _: Relux.ActionResult = await harness.flow.apply(
        Runners.Effect.applyGroupAccess("actions.runner.test.serverswitch", groupID: 4, repositories: [1, 2], allowTakeover: true)
    )
    let requests = await harness.transport.requests
    #expect(requests.count == 2)
    #expect(requests.filter { $0.method == "PUT" }.isEmpty)
    #expect(loadedGroupAccess(harness.logger, id: "actions.runner.test.serverswitch") == nil)
    let cleanup = groupAccessError(harness.logger, id: "actions.runner.test.serverswitch") ?? ""
    #expect(cleanup.contains("session changed") && cleanup.contains("Reload group access"))
}

/// F3 bound: the store itself refuses a second entry sharing one service
/// label, so no import path can create an uncontrollable duplicate.
@Test func catalogRefusesDuplicateServiceLabel() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Catalog-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = RunnerCatalogStore(fileURL: file)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DupLabel-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a")
    let b = root.appendingPathComponent("b")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    let first = RunnerCatalogStore.Entry(
        directoryPath: a.path, canonicalPath: RunnerCatalogStore.canonical(a),
        serviceLabel: "actions.runner.test.dup",
        servicePlistPath: a.appendingPathComponent("manual-service.plist").path,
        controllerKind: .manualManaged
    )
    try await store.add(first)
    let second = RunnerCatalogStore.Entry(
        directoryPath: b.path, canonicalPath: RunnerCatalogStore.canonical(b),
        serviceLabel: "actions.runner.test.dup",
        servicePlistPath: b.appendingPathComponent("manual-service.plist").path,
        controllerKind: .manualManaged
    )
    do {
        try await store.add(second)
        Issue.record("Catalog admitted two entries sharing one service label")
    } catch let error as RunnerCatalogStore.CatalogError {
        guard case .duplicateLabel(let label) = error, label == "actions.runner.test.dup" else {
            Issue.record("Wrong duplicate-label error: \(error)"); return
        }
    }
    #expect(await store.load().count == 1)
}

/// F3 bound: same-name imports are independently controllable — enabling
/// each runner bootstraps its own manifest, never the sibling's.
@Test func sameNameFolderImportsControlIndependently() async throws {
    let stoppedResult = CommandResult(code: 113, output: "Could not find service x")
    let okResult = CommandResult(code: 0, output: "")
    let runningResult = CommandResult(code: 0, output: "state = running")
    let harness = await catalogHarness(launchResults: [
        stoppedResult, stoppedResult, stoppedResult,
        stoppedResult, okResult, runningResult, runningResult, runningResult,
        stoppedResult, okResult, runningResult, runningResult, runningResult
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let a = try makeRunnerDir(parent: harness.home, name: "a", agentName: "same", scope: "acme/a", withPlist: false)
    let b = try makeRunnerDir(parent: harness.home, name: "b", agentName: "same", scope: "acme/b", withPlist: false)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.importFolder(a))
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.importFolder(b))
    let entries = await harness.catalog.load()
    #expect(entries.count == 2)
    let labels = entries.map(\.serviceLabel)
    #expect(Set(labels).count == 2)
    for label in labels {
        let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.setEnabled(label, true))
    }
    let bootstraps = await harness.launchExecutor.calls.filter { $0.contains("bootstrap") }
    #expect(bootstraps.count == 2)
    let targets = Set(bootstraps.compactMap(\.last))
    #expect(targets == [
        a.appendingPathComponent("manual-service.plist").path,
        b.appendingPathComponent("manual-service.plist").path
    ])
}

/// F3 bound: a manifest label already owned by another entry refuses the
/// second import instead of creating an uncontrollable duplicate.
@Test func importRefusesConflictingManifestLabel() async throws {
    let harness = await catalogHarness(launchResults: [
        CommandResult(code: 113, output: "Could not find service x")
    ])
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let a = try makeRunnerDir(parent: harness.home, name: "a", agentName: "r", scope: "acme/a", label: "actions.runner.test.clash")
    let b = try makeRunnerDir(parent: harness.home, name: "b", agentName: "r", scope: "acme/b", label: "actions.runner.test.clash")
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.importFolder(a))
    #expect(await harness.catalog.load().count == 1)
    let _: Relux.ActionResult = await harness.flow.apply(Runners.Effect.importFolder(b))
    #expect(await harness.catalog.load().count == 1)
    #expect(catalogErr(harness.logger).contains("already in the catalog"))
}

/// F4 bound: a malformed store fails closed — no migration, no overwrite —
/// and the bytes stay untouched for recovery.
@Test func migrationFailsClosedOnMalformedPersistence() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Catalog-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    try "not-json{{".write(to: file, atomically: true, encoding: .utf8)
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("MalformedHome-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let store = RunnerCatalogStore(fileURL: file)
    do {
        _ = try await store.migrateIfNeeded(home: home)
        Issue.record("Migration treated malformed persistence as first-run absence")
    } catch let error as RunnerCatalogStore.CatalogError {
        guard case .persistenceUnreadable = error else {
            Issue.record("Wrong malformed error: \(error)"); return
        }
    }
    let entry = RunnerCatalogStore.Entry(
        directoryPath: "/tmp/x", canonicalPath: "/tmp/x",
        serviceLabel: "actions.runner.test.clobber",
        servicePlistPath: "/tmp/x/manual-service.plist",
        controllerKind: .manualManaged
    )
    do {
        try await store.add(entry)
        Issue.record("Add overwrote malformed persistence")
    } catch let error as RunnerCatalogStore.CatalogError {
        guard case .persistenceUnreadable = error else {
            Issue.record("Wrong clobber error: \(error)"); return
        }
    }
    #expect(await store.load().isEmpty)
    #expect(try String(contentsOf: file, encoding: .utf8) == "not-json{{")
}

/// F4 bound: an unsupported catalog version fails closed instead of
/// migrating or overwriting.
@Test func migrationFailsClosedOnUnsupportedVersion() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Catalog-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    try "{\"version\":999,\"entries\":[],\"migrated\":true}".write(to: file, atomically: true, encoding: .utf8)
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("VersionHome-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let store = RunnerCatalogStore(fileURL: file)
    do {
        _ = try await store.migrateIfNeeded(home: home)
        Issue.record("Migration treated an unsupported version as first-run absence")
    } catch let error as RunnerCatalogStore.CatalogError {
        guard case .unsupportedVersion(let found) = error, found == 999 else {
            Issue.record("Wrong version error: \(error)"); return
        }
    }
    #expect(try String(contentsOf: file, encoding: .utf8).contains("\"version\":999"))
}

/// F4 bound: a legacy store without the migrated flag seals in place —
/// entries untouched — and a later explicit emptying stays authoritative.
@Test func migrationSealsLegacyStoreWithoutTouchingEntries() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Catalog-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Legacy-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let entry = RunnerCatalogStore.Entry(
        localID: "legacy-local-id",
        directoryPath: dir.path, canonicalPath: RunnerCatalogStore.canonical(dir),
        serviceLabel: "actions.runner.test.legacy",
        servicePlistPath: dir.appendingPathComponent("manual-service.plist").path,
        controllerKind: .manualManaged, agentName: "legacy"
    )
    let entryJSON = String(data: try JSONEncoder().encode(entry), encoding: .utf8)!
    try "{\"version\":1,\"entries\":[\(entryJSON)]}".write(to: file, atomically: true, encoding: .utf8)
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyHome-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let store = RunnerCatalogStore(fileURL: file)
    let sealed = try await store.migrateIfNeeded(home: home)
    #expect(sealed.count == 1)
    #expect(sealed.first?.localID == "legacy-local-id")
    #expect(try String(contentsOf: file, encoding: .utf8).contains("\"migrated\":true"))
    _ = try await store.remove(localID: "legacy-local-id")
    #expect(try await store.migrateIfNeeded(home: home).isEmpty)
}

// MARK: - R3 reviewer regressions (rev2 verdict, adopted probes + bounds)

// The three exact rev2 reviewer probes, adopted as maintained
// production-entry regressions. Each failed on the rev2 candidate (exit 1,
// 5 assertion failures) and passes now.

private actor ReviewLogoutTransport: GitHubHTTPTransport {
    let base: TestTransport
    let identities: any GitHubSessionIdentityStoring
    let logoutMethod: String
    init(_ base: TestTransport, identities: any GitHubSessionIdentityStoring, logoutMethod: String) {
        self.base = base; self.identities = identities; self.logoutMethod = logoutMethod
    }
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        let result = try await base.send(request)
        if request.method == logoutMethod { await identities.delete() }
        return result
    }
}

private func reviewLogoutFlow(_ h: CatalogHarness, method: String) async -> Runners.Flow {
    let transport = ReviewLogoutTransport(h.transport, identities: h.identities, logoutMethod: method)
    return await Runners.Flow(service: h.service, catalog: h.catalog, installer: h.installer,
        api: GitHubRunnerAPIClient(transport: transport), userStore: h.userStore,
        identities: h.identities, refresher: GitHubTokenRefresh(transport: transport, store: h.userStore),
        configProvider: { _ in testConfig }, home: h.home,
        dispatcher: Relux.Dispatcher(logger: h.logger))
}

@Test func reviewR2LogoutDuringPutMustNotPublishAccess() async throws {
    let h = await catalogHarness(transportResponses: [groupsPayload([(4, "g")]),
        groupRunnersPayload([(42, "r", false)]), .init(status: 204, body: Data()), groupReposPayload([1])])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.logoutput"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let flow = await reviewLogoutFlow(h, method: "PUT")
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [1], allowTakeover: true))
    #expect(await h.identities.load() == nil)
    #expect(loadedGroupAccess(h.logger, id: label) == nil)
    #expect(await h.transport.requests.count == 3)
}

@Test func reviewR2LogoutDuringRemoveTokenMustRefuseSideEffect() async throws {
    let h = await catalogHarness(launchResults: [stopped, stopped, stopped],
        installerResults: [.init(code: 0, output: "ok")], transportResponses: [removeTokenPayload()])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.logoutremove"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try "#!/bin/sh\nexit 0\n".write(to: dir.appendingPathComponent("config.sh"), atomically: true, encoding: .utf8)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let flow = await reviewLogoutFlow(h, method: "POST")
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.unregister(label, confirmation: "r"))
    #expect(await h.identities.load() == nil)
    #expect(await h.installerExecutor.calls.isEmpty)
    #expect(await h.catalog.load().first?.remoteAgentID == 42)
}

@Test func reviewR2ScopeEditAfterLoadMustNotRetargetApply() async throws {
    let h = await catalogHarness(transportResponses: [groupsPayload([(4, "g")]),
        groupRunnersPayload([(42, "r", false)]), groupReposPayload([1]),
        groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)]),
        .init(status: 204, body: Data()), groupReposPayload([2])])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.scoperetarget"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(loadedGroupAccess(h.logger, id: label)?.group?.id == 4)
    let runner = dir.appendingPathComponent(".runner")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: runner)) as! [String: Any]
    object["gitHubUrl"] = "https://github.com/other-org"
    try JSONSerialization.data(withJSONObject: object).write(to: runner)
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [2], allowTakeover: true))
    #expect(await h.transport.requests.filter { $0.method == "PUT" }.isEmpty)
}

// MARK: - R3 bounds: completion ownership, retry release, re-verification

/// R2-F2 bound (sibling Load completion): a logout during the membership
/// reads stops the Load — the repository fetch after the invalidation
/// point never fires and no stale access is published into the logged-out
/// session. Bound: the in-flight membership loop may finish its current
/// read; no write, confirmation read, or publication follows.
@Test func loadGroupAccessStopsPublishingAfterMidLoadLogout() async throws {
    let h = await catalogHarness(transportResponses: [groupsPayload([(4, "g")]),
        groupRunnersPayload([(42, "r", false)]), groupReposPayload([1])])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.loadlogout"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let flow = await reviewLogoutFlow(h, method: "GET")
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(await h.identities.load() == nil)
    #expect(loadedGroupAccess(h.logger, id: label) == nil)
    let cleanup = groupAccessError(h.logger, id: label) ?? ""
    #expect(cleanup.contains("session changed") && cleanup.contains("Reload group access"))
    // Groups + runners reads happened; the repos fetch after the logout did not.
    #expect(await h.transport.requests.count == 2)
}

private func lastUnregistering(_ logger: Relux.Testing.Logger, id: String) -> Bool? {
    for action in runnersActions(logger).reversed() {
        if case .unregistering(let target, let value) = action, target == id {
            return value
        }
    }
    return nil
}

/// R2-F3 bound: a session-invalidated unregister releases the UI operation
/// state, so re-authenticating and retrying proceeds instead of wedging on
/// a stuck "unregistering" flag.
@Test func unregisterReleasesOperationStateAfterSessionLoss() async throws {
    let h = await catalogHarness(launchResults: [stopped, stopped, stopped, stopped],
        installerResults: [.init(code: 0, output: "ok")], transportResponses: [removeTokenPayload()])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.unregretry"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let loggedOut = await reviewLogoutFlow(h, method: "POST")
    let _: Relux.ActionResult = await loggedOut.apply(Runners.Effect.unregister(label, confirmation: "r"))
    #expect(await h.identities.load() == nil)
    #expect(await h.installerExecutor.calls.isEmpty)
    #expect(lastUnregistering(h.logger, id: label) == false)
    // Re-authenticate and retry through the normal entry: the side effect proceeds.
    await h.identities.save(GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo"))
    await h.transport.append(removeTokenPayload())
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.unregister(label, confirmation: "r"))
    #expect(await h.installerExecutor.calls.count == 1)
    #expect(await h.catalog.load().first?.remoteAgentID == nil)
}

/// R2-F1 bound: the scope-change refusal names the drift and is recoverable
/// through explicit re-verification — remove and re-add rebinds the catalog
/// original, after which Apply targets the new org (and only it).
@Test func scopeEditThenReAddReverifiesGroupApply() async throws {
    let h = await catalogHarness(
        launchResults: [stopped, stopped],
        transportResponses: [
            groupsPayload([(4, "g")]),
            groupRunnersPayload([(42, "r", false)]),
            groupReposPayload([1])
        ]
    )
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.scopeverify"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(loadedGroupAccess(h.logger, id: label)?.group?.id == 4)
    // Same-host scope edit without re-verification: refused, no PUT.
    let runner = dir.appendingPathComponent(".runner")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: runner)) as! [String: Any]
    object["gitHubUrl"] = "https://github.com/other-org"
    try JSONSerialization.data(withJSONObject: object).write(to: runner)
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [2], allowTakeover: true))
    #expect(await h.transport.requests.filter { $0.method == "PUT" }.isEmpty)
    let refusal = groupAccessError(h.logger, id: label) ?? ""
    #expect(refusal.contains("acme") && refusal.contains("other-org"))
    // Explicit re-verification: remove and re-add rebinds the original.
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.removeFromApp(label))
    #expect(await h.catalog.load().isEmpty)
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.importFolder(dir))
    #expect(await h.catalog.load().count == 1)
    #expect(await h.catalog.load().first?.scope == "other-org")
    await h.transport.append(groupsPayload([(4, "g")]))
    await h.transport.append(groupRunnersPayload([(42, "r", false)]))
    await h.transport.append(groupReposPayload([1]))
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(loadedGroupAccess(h.logger, id: label)?.group?.id == 4)
    await h.transport.append(groupsPayload([(4, "g")]))
    await h.transport.append(groupRunnersPayload([(42, "r", false)]))
    await h.transport.append(.init(status: 204, body: Data()))
    await h.transport.append(groupReposPayload([2]))
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [2], allowTakeover: true))
    let puts = await h.transport.requests.filter { $0.method == "PUT" }
    #expect(puts.count == 1)
    #expect(puts.first?.url.path.contains("orgs/other-org/") == true)
    #expect(loadedGroupAccess(h.logger, id: label)?.repoIDs == [2])
}

// MARK: - R4 reviewer regressions (rev3 verdict, adopted probes + bounds)

// The three exact rev3 reviewer probes, adopted as maintained
// production-entry regressions. Each failed on the rev3 candidate (exit 1,
// 5 assertion failures) and passes now. The session probes drive the real
// GitHubAuth.Flow logout + Device Flow re-login (same account/server) while
// the catalog operation awaits; only HTTP/Keychain are fake.

private actor ReviewR3ReloginTransport: GitHubHTTPTransport {
    let base: TestTransport
    let auth: GitHubAuth.Flow
    let authLogger: Relux.Testing.Logger
    let method: String
    private var fired = false
    init(base: TestTransport, auth: GitHubAuth.Flow, logger: Relux.Testing.Logger, method: String) {
        self.base = base; self.auth = auth; self.authLogger = logger; self.method = method
    }
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        let result = try await base.send(request)
        if request.method == method && !fired {
            fired = true
            _ = await auth.apply(GitHubAuth.Effect.logout)
            _ = await auth.apply(GitHubAuth.Effect.beginLogin(serverHost: nil))
            // CI VMs saturate the cooperative pool under full-suite parallel
            // load (locally this completes in ~20ms); keep a generous hang
            // bound instead of a tight latency assertion.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline {
                if authLogger.actions.contains(where: {
                    guard let a = $0 as? GitHubAuth.Action else { return false }
                    if case .connected = a { return true }; return false
                }) { return result }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("Real auth flow failed to finish same-account re-login")
        }
        return result
    }
}

private func reviewR3ReloginFlow(_ h: CatalogHarness, method: String) async -> Runners.Flow {
    let authTransport = TestTransport([
        jsonResponse(["device_code": "dev-r3", "user_code": "R3-CODE", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1]),
        jsonResponse(["access_token": "[REDACTED]", "refresh_token": "[REDACTED]", "expires_in": 3600]),
        jsonResponse(["login": "octo", "id": 42]),
        jsonResponse(["installations": []])
    ])
    let logger = Relux.Testing.Logger()
    let auth = await GitHubAuth.Flow(deviceFlow: GitHubDeviceFlow(transport: authTransport),
        api: GitHubAPIClient(transport: authTransport),
        refresher: GitHubTokenRefresh(transport: authTransport, store: h.userStore),
        store: h.userStore, identityStore: h.identities, configProvider: { _ in testConfig },
        sleeper: { _ in }, dispatcher: Relux.Dispatcher(logger: logger))
    let transport = ReviewR3ReloginTransport(base: h.transport, auth: auth, logger: logger, method: method)
    return await Runners.Flow(service: h.service, catalog: h.catalog, installer: h.installer,
        api: GitHubRunnerAPIClient(transport: transport), userStore: h.userStore,
        identities: h.identities, refresher: GitHubTokenRefresh(transport: transport, store: h.userStore),
        configProvider: { _ in testConfig }, home: h.home, dispatcher: Relux.Dispatcher(logger: h.logger))
}

@Test func reviewR3SameAccountReloginDuringPutMustNotPublishAccess() async throws {
    let h = await catalogHarness(transportResponses: [groupsPayload([(4, "g")]),
        groupRunnersPayload([(42, "r", false)]), .init(status: 204, body: Data()), groupReposPayload([1])])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.logoutput"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let flow = await reviewR3ReloginFlow(h, method: "PUT")
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [1], allowTakeover: true))
    #expect(await h.identities.load()?.userID == 42)
    #expect(loadedGroupAccess(h.logger, id: label) == nil)
    #expect(await h.transport.requests.count == 3)
}

@Test func reviewR3SameAccountReloginDuringRemoveTokenMustRefuseSideEffect() async throws {
    let h = await catalogHarness(launchResults: [stopped, stopped, stopped],
        installerResults: [.init(code: 0, output: "ok")], transportResponses: [removeTokenPayload()])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.logoutremove"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try "#!/bin/sh\nexit 0\n".write(to: dir.appendingPathComponent("config.sh"), atomically: true, encoding: .utf8)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let flow = await reviewR3ReloginFlow(h, method: "POST")
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.unregister(label, confirmation: "r"))
    #expect(await h.identities.load()?.userID == 42)
    #expect(await h.installerExecutor.calls.isEmpty)
    #expect(await h.catalog.load().first?.remoteAgentID == 42)
}

@Test func reviewR3RelinkMustNotRebindLoadedEditorToOtherOrg() async throws {
    let h = await catalogHarness(transportResponses: [groupsPayload([(4, "g")]),
        groupRunnersPayload([(42, "r", false)]), groupReposPayload([1]),
        groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)]),
        .init(status: 204), groupReposPayload([2])])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.relinkretarget"
    let dir = try makeRunnerDir(parent: h.home, name: "original", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    _ = await h.flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(loadedGroupAccess(h.logger, id: label)?.group?.id == 4)
    let foreign = try makeRunnerDir(parent: h.home, name: "foreign", agentName: "r", scope: "other-org", agentID: 42, label: label)
    _ = await h.flow.apply(Runners.Effect.relinkDirectory(label, foreign))
    _ = await h.flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [2], allowTakeover: true))
    let writes = await h.transport.requests.filter { $0.method == "PUT" }
    #expect(writes.isEmpty)
}

// MARK: - R4 bounds: incarnation, editor invalidation, retry, refresh

/// R3-F2 sibling (Load completion): same-account re-login through the real
/// auth flow during the Load membership reads refuses the repository fetch
/// and any publication into the new incarnation.
@Test func reviewR3SiblingLoadDuringReloginMustNotPublishAccess() async throws {
    let h = await catalogHarness(transportResponses: [groupsPayload([(4, "g")]),
        groupRunnersPayload([(42, "r", false)]), groupReposPayload([1])])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.loadrelogin"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let flow = await reviewR3ReloginFlow(h, method: "GET")
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(await h.identities.load()?.userID == 42)
    #expect(await h.identities.load()?.sessionIncarnation?.isEmpty == false)
    #expect(loadedGroupAccess(h.logger, id: label) == nil)
    let cleanup = groupAccessError(h.logger, id: label) ?? ""
    #expect(cleanup.contains("session changed") && cleanup.contains("Reload group access"))
    #expect(await h.transport.requests.count == 2)
}

/// Positive control: an expiring token refreshed within the same login keeps
/// the same incarnation, so Apply proceeds and publishes.
@Test func applySucceedsAfterTokenRefreshWithinSameLogin() async throws {
    let h = await catalogHarness(transportResponses: [
        jsonResponse(["access_token": "ghu_new", "refresh_token": "ghr_new", "expires_in": 3600]),
        groupsPayload([(4, "g")]),
        groupRunnersPayload([(42, "r", false)]),
        .init(status: 204, body: Data()),
        groupReposPayload([1, 2])
    ])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.refreshok"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    try? await h.userStore.save(
        GitHubAuth.TokenRecord(accessToken: "user-token-42", refreshToken: "refresh-42", expiresAt: Date().addingTimeInterval(30)),
        serverHost: "github.com", userID: 42, clientID: testConfig.clientID
    )
    let before = await h.identities.load()
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [1, 2], allowTakeover: true))
    #expect(await h.identities.load()?.sessionIncarnation == before?.sessionIncarnation)
    #expect(await h.transport.requests.filter { $0.method == "PUT" }.count == 1)
    #expect(loadedGroupAccess(h.logger, id: label)?.repoIDs == [1, 2])
}

/// Retry control: after a same-account relogin invalidates an unregister,
/// an explicit retry initiated in the new incarnation proceeds.
@Test func unregisterRetryInNewIncarnationSucceeds() async throws {
    let h = await catalogHarness(launchResults: [stopped, stopped, stopped, stopped],
        installerResults: [.init(code: 0, output: "ok")],
        transportResponses: [removeTokenPayload(), removeTokenPayload()])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.unregrelogin"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let stale = await reviewR3ReloginFlow(h, method: "POST")
    let _: Relux.ActionResult = await stale.apply(Runners.Effect.unregister(label, confirmation: "r"))
    #expect(await h.identities.load()?.userID == 42)
    #expect(await h.identities.load()?.sessionIncarnation?.isEmpty == false)
    #expect(await h.installerExecutor.calls.isEmpty)
    #expect(await h.catalog.load().first?.remoteAgentID == 42)
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.unregister(label, confirmation: "r"))
    #expect(await h.installerExecutor.calls.count == 1)
    #expect(await h.catalog.load().first?.remoteAgentID == nil)
}

/// R3-F1 bound: relink to a same-ID different-scope folder refuses, keeps
/// the catalog on the original, invalidates the loaded editor, and requires
/// an explicit Load before the next Apply (which then targets the original).
@Test func relinkRefusesChangedScopeAndRequiresReload() async throws {
    let h = await catalogHarness(transportResponses: [
        groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)]), groupReposPayload([1])
    ])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.relinkscope"
    let dir = try makeRunnerDir(parent: h.home, name: "original", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    _ = await h.flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(loadedGroupAccess(h.logger, id: label)?.group?.id == 4)
    let foreign = try makeRunnerDir(parent: h.home, name: "foreign", agentName: "r", scope: "other-org", agentID: 42, label: label)
    _ = await h.flow.apply(Runners.Effect.relinkDirectory(label, foreign))
    #expect(catalogErr(h.logger).contains("other-org") && catalogErr(h.logger).contains("acme"))
    #expect(await h.catalog.load().first?.directoryPath == dir.path)
    #expect(await h.catalog.load().first?.scope == "acme")
    #expect((groupAccessError(h.logger, id: label) ?? "").contains("Reload group access"))
    _ = await h.flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [2], allowTakeover: true))
    #expect(await h.transport.requests.filter { $0.method == "PUT" }.isEmpty)
    await h.transport.append(groupsPayload([(4, "g")]))
    await h.transport.append(groupRunnersPayload([(42, "r", false)]))
    await h.transport.append(groupReposPayload([1]))
    _ = await h.flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(loadedGroupAccess(h.logger, id: label)?.group?.id == 4)
    await h.transport.append(groupsPayload([(4, "g")]))
    await h.transport.append(groupRunnersPayload([(42, "r", false)]))
    await h.transport.append(.init(status: 204, body: Data()))
    await h.transport.append(groupReposPayload([2]))
    _ = await h.flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [2], allowTakeover: true))
    let puts = await h.transport.requests.filter { $0.method == "PUT" }
    #expect(puts.count == 1)
    #expect(puts.first?.url.path.contains("orgs/acme/") == true)
}

/// R3-F1 bound: a legitimate same-identity move still changes the canonical
/// path, so it invalidates the editor and requires an explicit Load; the
/// reloaded editor then applies to the moved folder.
@Test func relinkSameIdentityMoveRequiresReload() async throws {
    let h = await catalogHarness(transportResponses: [
        groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)]), groupReposPayload([1])
    ])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.relinkmove"
    let a = try makeRunnerDir(parent: h.home, name: "a", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: a, label: label))
    _ = await h.flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(loadedGroupAccess(h.logger, id: label)?.group?.id == 4)
    let b = try makeRunnerDir(parent: h.home, name: "b", agentName: "r", scope: "acme", agentID: 42, label: label)
    _ = await h.flow.apply(Runners.Effect.relinkDirectory(label, b))
    #expect(await h.catalog.load().first?.directoryPath == b.path)
    #expect((groupAccessError(h.logger, id: label) ?? "").contains("Reload group access"))
    _ = await h.flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [2], allowTakeover: true))
    #expect(await h.transport.requests.filter { $0.method == "PUT" }.isEmpty)
    await h.transport.append(groupsPayload([(4, "g")]))
    await h.transport.append(groupRunnersPayload([(42, "r", false)]))
    await h.transport.append(groupReposPayload([1]))
    _ = await h.flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(loadedGroupAccess(h.logger, id: label)?.group?.id == 4)
    await h.transport.append(groupsPayload([(4, "g")]))
    await h.transport.append(groupRunnersPayload([(42, "r", false)]))
    await h.transport.append(.init(status: 204, body: Data()))
    await h.transport.append(groupReposPayload([2]))
    _ = await h.flow.apply(Runners.Effect.applyGroupAccess(label, groupID: 4, repositories: [2], allowTakeover: true))
    #expect(await h.transport.requests.filter { $0.method == "PUT" }.count == 1)
    #expect(loadedGroupAccess(h.logger, id: label)?.repoIDs == [2])
}

// MARK: - R5 reviewer regressions (rev4 verdict, adopted probes)

// The two exact rev4 reviewer probes, adopted as maintained
// production-entry regressions. Each failed on the rev4 candidate (exit 1,
// 4 assertion failures) and passes now. R4-F1 drives the real
// LaunchAgentService plus the real GitHubAuth logout while the final
// stopped inspection awaits; R4-F2 drives the real-auth same-account
// logout/Device Flow re-login, then feeds the emitted actions through the
// production reducer plus a normal local refresh.

// Review R4: logout while the final production launchctl inspection awaits.
private actor ReviewR4LogoutExecutor: CommandExecuting {
    let auth: GitHubAuth.Flow
    private var count = 0
    init(auth: GitHubAuth.Flow) { self.auth = auth }
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        count += 1
        if count == 2 { _ = await auth.apply(GitHubAuth.Effect.logout) }
        return stopped
    }
}

@Test func reviewR4LogoutDuringFinalStoppedInspectionMustRefuseRemoval() async throws {
    let h = await catalogHarness(installerResults: [.init(code: 0, output: "ok")], transportResponses: [removeTokenPayload()])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.finalinspection"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let authTransport = TestTransport([])
    let auth = await GitHubAuth.Flow(deviceFlow: GitHubDeviceFlow(transport: authTransport),
        api: GitHubAPIClient(transport: authTransport),
        refresher: GitHubTokenRefresh(transport: authTransport, store: h.userStore),
        store: h.userStore, identityStore: h.identities, configProvider: { _ in testConfig },
        dispatcher: Relux.Dispatcher(logger: Relux.Testing.Logger()))
    let service = LaunchAgentService(catalog: h.catalog, executor: ReviewR4LogoutExecutor(auth: auth), userID: 501, home: h.home)
    let flow = await Runners.Flow(service: service, catalog: h.catalog, installer: h.installer,
        api: GitHubRunnerAPIClient(transport: h.transport), userStore: h.userStore,
        identities: h.identities, refresher: GitHubTokenRefresh(transport: h.transport, store: h.userStore),
        configProvider: { _ in testConfig }, home: h.home, dispatcher: Relux.Dispatcher(logger: h.logger))
    _ = await flow.apply(Runners.Effect.unregister(label, confirmation: "r"))
    #expect(await h.identities.load() == nil)
    #expect(await h.transport.requests.count == 1)
    #expect(await h.installerExecutor.calls.isEmpty)
    #expect(await h.catalog.load().first?.remoteAgentID == 42)
}

@MainActor @Test(arguments: [false, true])
func reviewR4SessionInvalidationMustReleaseEditorLoading(apply: Bool) async throws {
    let responses: [GitHubHTTPResponse] = apply
        ? [groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)]), .init(status: 204), groupReposPayload([2])]
        : [groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)]), groupReposPayload([1])]
    let h = await catalogHarness(transportResponses: responses)
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.releaseeditor"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let flow = await reviewR3ReloginFlow(h, method: apply ? "PUT" : "GET")
    let effect: Runners.Effect = apply ? .applyGroupAccess(label, groupID: 4, repositories: [2], allowTakeover: true) : .loadGroupAccess(label)
    _ = await flow.apply(effect)
    #expect(await h.identities.load()?.sessionIncarnation != nil)
    #expect(loadedGroupAccess(h.logger, id: label) == nil)
    let state = Runners.State(definitions: [])
    for action in runnersActions(h.logger) { await state.reduce(with: action) }
    // Normal local polling must not leave the editor wedged either.
    await state.reduce(with: Runners.Action.refreshed(await h.service.snapshots()))
    #expect(state.groupAccess[label]?.loading != true)
}

// MARK: - R5 bounds: final installer boundary, overlap, same-flow retry

/// R4-F1 bound: a logout that lands after the final stopped inspection —
/// between the Flow's last check and `config.sh remove` — is refused at the
/// actual installer mutation boundary. Identity load order in unregister:
/// started(1), auth(2), post-token check(3), pre-inspection check(4),
/// post-inspection check(5), installer authority(6); the flip lands on the
/// installer authority check. The minted remove token expires unused, the
/// operation state is released, and an explicit retry in the new session
/// proceeds through the same Flow.
@Test func unregisterRefusesLogoutBetweenFinalInspectionAndConfigRemove() async throws {
    let session = GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo")
    let flipping = FlippingSessionStore(first: session, later: nil, flipAfter: 5)
    let h = await catalogHarness(
        launchResults: [stopped, stopped, stopped, stopped, stopped],
        installerResults: [.init(code: 0, output: "ok")],
        transportResponses: [removeTokenPayload()],
        identitiesOverride: flipping
    )
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.installerboundary"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.unregister(label, confirmation: "r"))
    #expect(await h.transport.requests.count == 1)
    #expect(await h.installerExecutor.calls.isEmpty)
    #expect(await h.catalog.load().first?.remoteAgentID == 42)
    #expect(lastUnregistering(h.logger, id: label) == false)
    // Re-authenticate and retry through the same Flow: removal proceeds.
    await flipping.save(GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo"))
    await h.transport.append(removeTokenPayload(token: "remove-token-2"))
    let _: Relux.ActionResult = await h.flow.apply(Runners.Effect.unregister(label, confirmation: "r"))
    #expect(await h.installerExecutor.calls.count == 1)
    #expect(await h.catalog.load().first?.remoteAgentID == nil)
}

/// Holds the first HTTP send on a latch while later sends pass through, so
/// two overlapping Loads on one Flow interleave deterministically.
private actor LatchFirstSendTransport: GitHubHTTPTransport {
    let base: TestTransport
    private var latched = false
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var sends = 0
    init(_ base: TestTransport) { self.base = base }
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        sends += 1
        if !latched {
            latched = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in gate = continuation }
        }
        return try await base.send(request)
    }
    func release() { gate?.resume(); gate = nil }
}

/// R4-F2 bound: when two Loads overlap on the same Flow, the older
/// completion publishes nothing — it neither clears the newer request's
/// busy state nor overwrites its data. Driven through the production
/// reducer plus a normal local refresh.
@MainActor @Test func editorOverlappingLoadSuppressesStaleCompletion() async throws {
    let h = await catalogHarness(transportResponses: [
        groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)]), groupReposPayload([7]),
        groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)]), groupReposPayload([9])
    ])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.overlap"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let latch = LatchFirstSendTransport(h.transport)
    let flow = await Runners.Flow(service: h.service, catalog: h.catalog, installer: h.installer,
        api: GitHubRunnerAPIClient(transport: latch), userStore: h.userStore,
        identities: h.identities, refresher: GitHubTokenRefresh(transport: latch, store: h.userStore),
        configProvider: { _ in testConfig }, home: h.home, dispatcher: Relux.Dispatcher(logger: h.logger))
    async let first: Relux.ActionResult = flow.apply(Runners.Effect.loadGroupAccess(label))
    // Bounded wait until the first op's initial send is held on the latch;
    // only then start the newer overlapping Load.
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await latch.sends == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await latch.sends == 1)
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(loadedGroupAccess(h.logger, id: label)?.repoIDs == [7])
    await latch.release()
    let _: Relux.ActionResult = await first
    #expect(await h.transport.requests.count == 6)
    #expect(loadedGroupAccess(h.logger, id: label)?.repoIDs == [7])
    let state = Runners.State(definitions: [])
    for action in runnersActions(h.logger) { await state.reduce(with: action) }
    await state.reduce(with: Runners.Action.refreshed(await h.service.snapshots()))
    #expect(state.groupAccess[label]?.loading == false)
    #expect(state.groupAccess[label]?.repoIDs == [7])
}

/// Logs out exactly once, on the first HTTP request, so a retry after
/// re-authentication is not logged out again.
private actor SingleFireLogoutTransport: GitHubHTTPTransport {
    let base: TestTransport
    let identities: any GitHubSessionIdentityStoring
    private var fired = false
    init(_ base: TestTransport, identities: any GitHubSessionIdentityStoring) {
        self.base = base; self.identities = identities
    }
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        let result = try await base.send(request)
        if !fired {
            fired = true
            await identities.delete()
        }
        return result
    }
}

/// R4-F2 bound: after a session invalidation releases the editor busy state,
/// an explicit retry through the SAME Flow in the new session succeeds.
/// Driven through the production reducer plus a normal local refresh.
@MainActor @Test func editorRetryAfterSessionInvalidationSucceedsOnSameFlow() async throws {
    let h = await catalogHarness(transportResponses: [
        groupsPayload([(4, "g")]), groupRunnersPayload([(42, "r", false)])
    ])
    defer { try? FileManager.default.removeItem(at: h.home); try? FileManager.default.removeItem(at: h.catalogFile) }
    let label = "actions.runner.test.editorretry"
    let dir = try makeRunnerDir(parent: h.home, name: "r", agentName: "r", scope: "acme", agentID: 42, label: label)
    try await h.catalog.add(unregisterEntry(dir: dir, label: label))
    let transport = SingleFireLogoutTransport(h.transport, identities: h.identities)
    let flow = await Runners.Flow(service: h.service, catalog: h.catalog, installer: h.installer,
        api: GitHubRunnerAPIClient(transport: transport), userStore: h.userStore,
        identities: h.identities, refresher: GitHubTokenRefresh(transport: transport, store: h.userStore),
        configProvider: { _ in testConfig }, home: h.home, dispatcher: Relux.Dispatcher(logger: h.logger))
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(await h.identities.load() == nil)
    #expect(loadedGroupAccess(h.logger, id: label) == nil)
    let cleanup = groupAccessError(h.logger, id: label) ?? ""
    #expect(cleanup.contains("session changed") && cleanup.contains("Reload group access"))
    #expect(await h.transport.requests.count == 2)
    // Re-authenticate and retry through the same Flow: the released editor proceeds.
    await h.identities.save(GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo"))
    await h.transport.append(groupsPayload([(4, "g")]))
    await h.transport.append(groupRunnersPayload([(42, "r", false)]))
    await h.transport.append(groupReposPayload([11]))
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.loadGroupAccess(label))
    #expect(loadedGroupAccess(h.logger, id: label)?.repoIDs == [11])
    #expect(await h.transport.requests.count == 5)
    let state = Runners.State(definitions: [])
    for action in runnersActions(h.logger) { await state.reduce(with: action) }
    await state.reduce(with: Runners.Action.refreshed(await h.service.snapshots()))
    #expect(state.groupAccess[label]?.loading == false)
    #expect(state.groupAccess[label]?.repoIDs == [11])
}

// MARK: - R6: non-reusable editor operation ownership across re-import

// Adopted exact rev5 probe: remove/re-import must not revive an old editor
// operation owner. Holds the first Load at HTTP, removes and re-imports the
// same runner, starts a second Load, then releases only the first. The newer
// pending Load must keep loading=true with no error.
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
