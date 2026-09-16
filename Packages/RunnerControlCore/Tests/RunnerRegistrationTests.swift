import CryptoKit
import Foundation
import Testing
import Relux
@testable import RunnerControlCore

// MARK: - Registration harness (production entry points, controlled IO)

// TestTransport, jsonResponse, and testConfig are shared from GitHubTransportTests.

private struct RegistrationHarness {
    let flow: RunnerRegistration.Flow
    let logger: Relux.Testing.Logger
    let transport: TestTransport
    let userStore: GitHubKeychainStore
    let identities: InMemoryGitHubSessionIdentityStore
    let registrationTokens: RunnerRegistrationTokenStore
    let installer: RunnerInstallerService
    let home: URL
    let installRoot: URL
}

private func registrationHarness(
    transport: TestTransport,
    downloader: (@Sendable (URL) async throws -> Data)? = nil,
    executor: (any CommandExecuting)? = nil,
    arch: String = "arm64",
    seedAuth: Bool = true
) async -> RegistrationHarness {
    let logger = Relux.Testing.Logger()
    let dispatcher = Relux.Dispatcher(logger: logger)
    let userStore = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let identities = InMemoryGitHubSessionIdentityStore()
    if seedAuth {
        await identities.save(GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo"))
        try? await userStore.save(
            GitHubAuth.TokenRecord(accessToken: "user-token-42", refreshToken: "refresh-42", expiresAt: Date().addingTimeInterval(3600)),
            serverHost: "github.com", userID: 42, clientID: testConfig.clientID
        )
    }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("RegHome-" + UUID().uuidString)
    let installRoot = home.appendingPathComponent("Library/GitHubActions")
    try? FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
    let archCopy = arch
    let installer = RunnerInstallerService(
        installRoot: installRoot,
        downloader: downloader,
        executor: executor,
        currentArch: { archCopy }
    )
    let api = GitHubRunnerAPIClient(transport: transport)
    let registrationTokens = RunnerRegistrationTokenStore(backend: InMemoryRegistrationTokenBackend())
    let refresher = GitHubTokenRefresh(transport: transport, store: userStore)
    let flow = await RunnerRegistration.Flow(
        api: api, installer: installer, registrationTokens: registrationTokens,
        userStore: userStore, identityStore: identities, refresher: refresher,
        configProvider: { _ in testConfig }, dispatcher: dispatcher
    )
    return RegistrationHarness(
        flow: flow, logger: logger, transport: transport, userStore: userStore,
        identities: identities, registrationTokens: registrationTokens,
        installer: installer, home: home, installRoot: installRoot
    )
}

private func registrationActions(_ logger: Relux.Testing.Logger) -> [RunnerRegistration.Action] {
    logger.actions.compactMap { $0 as? RunnerRegistration.Action }
}

private func lastFailure(_ logger: Relux.Testing.Logger) -> (message: String, step: String)? {
    for action in registrationActions(logger).reversed() {
        switch action {
        case .failed(let message, let step): return (message, step)
        case .permissionDenied(let message, let step): return (message, step)
        default: break
        }
    }
    return nil
}

private func orgDraft(
    name: String = "macbook-test",
    dir: String = "macbook-test",
    group: String = "RunnerControl-Mac",
    repos: Set<Int64> = [9],
    allowGroup: Bool = true,
    allowTakeover: Bool = false,
    allowReplace: Bool = false
) -> RunnerRegistration.Draft {
    RunnerRegistration.Draft(
        scope: .organization(org: "acme"),
        runnerName: name,
        labels: ["self-hosted", "macOS"],
        installDirName: dir,
        workFolder: "_work",
        groupName: group,
        selectedRepositoryIDs: repos,
        allowGroupMutation: allowGroup,
        allowGroupTakeover: allowTakeover,
        allowReplace: allowReplace
    )
}

private func repoDraft(dir: String = "personal-app", allowReplace: Bool = false) -> RunnerRegistration.Draft {
    RunnerRegistration.Draft(
        scope: .repository(owner: "octo", name: "app"),
        runnerName: "personal-runner",
        labels: ["self-hosted", "macOS"],
        installDirName: dir,
        workFolder: "_work",
        allowGroupMutation: false,
        allowGroupTakeover: false,
        allowReplace: allowReplace
    )
}

/// The downloads endpoint returns a bare JSON array, not an object.
private func downloadsArrayPayload(_ assets: [[String: Any]]) -> GitHubHTTPResponse {
    // swiftlint:disable:next force_try
    let data = try! JSONSerialization.data(withJSONObject: assets)
    return GitHubHTTPResponse(status: 200, body: data)
}

/// Typed group fixture: heterogeneous literals (Int/String/Bool) need an
/// explicit `[String: Any]` context to compile.
private func groupPayload(id: Int64, name: String, visibility: String, allowsPublic: Bool) -> [String: Any] {
    ["id": id, "name": name, "visibility": visibility, "allows_public_repositories": allowsPublic]
}

private func groupsListPayload(_ groups: [[String: Any]]) -> GitHubHTTPResponse {
    jsonResponse(["runner_groups": groups])
}

// MARK: - Fixture package (real tarball, controlled filesystem)

/// Builds a minimal official-shaped runner package and packs it with the
/// real system tar. Scripts keep their executable bit inside the archive.
private struct FixturePackage {
    let bytes: Data
    let sha256ViaSystem: String

    static func make(withRealConfigScript: Bool = true) async throws -> FixturePackage {
        let files = FileManager.default
        let src = files.temporaryDirectory.appendingPathComponent("FixtureSrc-" + UUID().uuidString)
        let bin = src.appendingPathComponent("bin")
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\nexec \"$(dirname \"$0\")/../run.sh\" \"$@\"\n".write(to: bin.appendingPathComponent("runsvc.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho runner\n".write(to: src.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        if withRealConfigScript {
            let script = """
            #!/bin/sh
            DIR="$(cd "$(dirname "$0")" && pwd)"
            NAME=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --name) NAME="$2"; shift 2;;
                *) shift;;
              esac
            done
            printf '{"agentId":4242,"agentName":"%s","gitHubUrl":"https://github.com/acme","workFolder":"_work"}' "$NAME" > "$DIR/.runner"
            """
            try script.write(to: src.appendingPathComponent("config.sh"), atomically: true, encoding: .utf8)
        } else {
            try "#!/bin/sh\nexit 0\n".write(to: src.appendingPathComponent("config.sh"), atomically: true, encoding: .utf8)
        }
        for path in ["bin/runsvc.sh", "run.sh", "config.sh"] {
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent(path).path)
        }
        let archive = files.temporaryDirectory.appendingPathComponent("fixture-" + UUID().uuidString + ".tar.gz")
        defer { try? files.removeItem(at: src) }
        defer { try? files.removeItem(at: archive) }
        let executor = CommandExecutor()
        let packed = try await executor.run("/usr/bin/tar", ["-czf", archive.path, "-C", src.path, "."])
        guard packed.code == 0 else { throw RunnerError.message("fixture tar failed: \(packed.output)") }
        let bytes = try Data(contentsOf: archive)
        // Independent oracle: system shasum pins the production CryptoKit hasher.
        let hashed = try await executor.run("/usr/bin/shasum", ["-a", "256", archive.path])
        guard hashed.code == 0 else { throw RunnerError.message("shasum missing: \(hashed.output)") }
        let digest = hashed.output.split(separator: " ").first.map(String.init) ?? ""
        guard digest.count == 64 else { throw RunnerError.message("bad shasum output: \(hashed.output)") }
        return FixturePackage(bytes: bytes, sha256ViaSystem: digest)
    }
}

private func fixtureDownloader(_ bytes: Data) -> @Sendable (URL) async throws -> Data {
    let copy = bytes
    return { _ in copy }
}

/// Records config.sh argv and simulates a successful registration by writing
/// `.runner`. Delegates every other command (tar) to the real executor.
private actor SplitExecutor: CommandExecuting {
    private(set) var configCalls: [[String]] = []
    var failure: CommandResult?
    private let real = CommandExecutor()
    private let gitHubURL: String

    init(gitHubURL: String = "https://github.com/acme") {
        self.gitHubURL = gitHubURL
    }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        if executable.hasSuffix("config.sh") {
            configCalls.append(arguments)
            if let failure { return failure }
            let dir = URL(fileURLWithPath: executable).deletingLastPathComponent()
            var name = "unnamed"
            var work = "_work"
            var index = arguments.startIndex
            while index < arguments.endIndex {
                if arguments[index] == "--name", arguments.index(after: index) < arguments.endIndex {
                    name = arguments[arguments.index(after: index)]
                }
                if arguments[index] == "--work", arguments.index(after: index) < arguments.endIndex {
                    work = arguments[arguments.index(after: index)]
                }
                index = arguments.index(after: index)
            }
            let payload = ["agentId": 4242, "agentName": name, "gitHubUrl": gitHubURL, "workFolder": work] as [String: Any]
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: dir.appendingPathComponent(".runner"), options: .atomic)
            return CommandResult(code: 0, output: "Configured")
        }
        return try await real.run(executable, arguments)
    }
}

// MARK: - Reducer and pure gates

@Test @MainActor func registrationReducerRetainsPermissionErrorAcrossDraftEdits() async {
    let state = RunnerRegistration.State()
    await state.reduce(with: ForeignAction())
    #expect(state.phase == .idle)
    let draft = orgDraft()
    await state.reduce(with: RunnerRegistration.Action.draftBegan(draft))
    #expect(state.phase == .drafting)
    await state.reduce(with: RunnerRegistration.Action.permissionDenied(message: "Missing permission: X", step: "resolveGroup"))
    #expect(state.permissionError == "Missing permission: X")
    // Draft edits must retain the permission error by design.
    var edited = draft
    edited.runnerName = "renamed"
    await state.reduce(with: RunnerRegistration.Action.draftUpdated(edited))
    #expect(state.permissionError == "Missing permission: X")
    #expect(state.draft?.runnerName == "renamed")
    await state.reduce(with: RunnerRegistration.Action.permissionDismissed)
    #expect(state.permissionError == nil)
    await state.reduce(with: RunnerRegistration.Action.registered(runnerID: 11, localAgentID: 4242))
    #expect(state.runnerID == 11)
    await state.cleanup()
    #expect(state.phase == .idle)
    #expect(state.draft == nil)
}

@Test func configInvocationIsExactAndOrdered() {
    let orgSpec = RunnerRegistration.ConfigSpec(
        scopeURL: "https://github.com/acme", token: "TOKEN",
        name: "mac1", workFolder: "_work",
        labels: ["self-hosted", "macOS"], runnerGroup: "RunnerControl-Mac",
        replace: true
    )
    let org = RunnerRegistration.ConfigInvocation.arguments(orgSpec)
    #expect(org == [
        "--url", "https://github.com/acme",
        "--token", "TOKEN",
        "--name", "mac1",
        "--work", "_work",
        "--labels", "self-hosted,macOS",
        "--runnergroup", "RunnerControl-Mac",
        "--unattended", "--replace",
    ])
    let repoSpec = RunnerRegistration.ConfigSpec(
        scopeURL: "https://github.com/octo/app", token: "TOKEN",
        name: "r2", workFolder: "_work",
        labels: ["a"], runnerGroup: nil, replace: true
    )
    let repo = RunnerRegistration.ConfigInvocation.arguments(repoSpec)
    #expect(!repo.contains("--runnergroup"))
    #expect(repo == [
        "--url", "https://github.com/octo/app",
        "--token", "TOKEN",
        "--name", "r2",
        "--work", "_work",
        "--labels", "a",
        "--unattended", "--replace",
    ])
}

@Test func configInvocationOmitsReplaceWithoutExplicitConsent() {
    let spec = RunnerRegistration.ConfigSpec(
        scopeURL: "https://github.com/acme", token: "TOKEN",
        name: "mac1", workFolder: "_work",
        labels: ["self-hosted", "macOS"], runnerGroup: "RunnerControl-Mac",
        replace: false
    )
    let args = RunnerRegistration.ConfigInvocation.arguments(spec)
    #expect(!args.contains("--replace"))
    #expect(args.last == "--unattended")
}

@Test func serviceLabelCarriesDiscoveryPrefixAndSanitizes() {
    let label = RunnerRegistration.Flow.serviceLabel(draft: orgDraft())
    #expect(label.hasPrefix("actions.runner."))
    #expect(!label.contains(" "))
    #expect(!label.contains("/"))
    var spaced = orgDraft()
    spaced.installDirName = "a b/c"
    #expect(!RunnerRegistration.Flow.serviceLabel(draft: spaced).contains(" "))
}

@Test func scopeURLsAndKeysAreExact() {
    #expect(RunnerRegistration.Scope.organization(org: "acme").apiPrefix == "orgs/acme")
    #expect(RunnerRegistration.Scope.repository(owner: "o", name: "r").apiPrefix == "repos/o/r")
    #expect(RunnerRegistration.Scope.organization(org: "acme").configURL(serverHost: "github.com") == "https://github.com/acme")
    #expect(RunnerRegistration.Scope.repository(owner: "o", name: "r").configURL(serverHost: "ghe.example.com") == "https://ghe.example.com/o/r")
}

@Test @MainActor func registrationModuleRegistersStateAndFlow() async {
    let transport = TestTransport([])
    let harness = await registrationHarness(transport: transport)
    let state = RunnerRegistration.State()
    let module = RunnerRegistration.Module(state: state, flow: harness.flow)
    #expect(module.states.count == 1)
    #expect(module.sagas.count == 1)
}

// MARK: - Draft gates (no network before validation)

@Test(arguments: [
    ("bad dir", "_work"),
    ("gooddir", "bad work"),
]) func beginDraftRefusesSpacesBeforeAnyNetwork(dir: String, work: String) async {
    let transport = TestTransport([])
    let harness = await registrationHarness(transport: transport)
    var draft = orgDraft()
    draft.installDirName = dir
    draft.workFolder = work
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(draft))
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "beginDraft")
    #expect((failure?.message.contains("space") ?? false))
    #expect(await transport.requests.isEmpty)
}

@Test func installerRefusesSpacesWithoutDownloading() async {
    actor Probe {
        var count = 0
        func next(_ url: URL) async throws -> Data { count += 1; return Data() }
    }
    let probe = Probe()
    let downloader: @Sendable (URL) async throws -> Data = { url in try await probe.next(url) }
    let harness = await registrationHarness(transport: TestTransport([]), downloader: downloader)
    var draft = orgDraft()
    draft.installDirName = "has space"
    let asset = RunnerRegistration.DownloadAsset(
        osName: "osx", architecture: "arm64",
        downloadURL: URL(string: "https://example.com/x.tar.gz")!,
        filename: "x.tar.gz", sha256Checksum: nil
    )
    do {
        _ = try await harness.installer.downloadAndInstall(asset: asset, draft: draft)
        Issue.record("installer admitted spaced path")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .noSpacePath = error else { Issue.record("wrong error: \(error)"); return }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(await probe.count == 0)
}

@Test func beginDraftRequiresNameAndLabels() async {
    let harness = await registrationHarness(transport: TestTransport([]))
    var nameless = orgDraft()
    nameless.runnerName = "   "
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(nameless))
    #expect(lastFailure(harness.logger)?.step == "beginDraft")
    var labelless = orgDraft()
    labelless.labels = []
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(labelless))
    #expect(registrationActions(harness.logger).filter {
        if case .failed = $0 { true } else { false }
    }.count == 2)
}

@Test func unauthenticatedWizardFailsClosedWithoutNetwork() async {
    let transport = TestTransport([])
    let harness = await registrationHarness(transport: transport, seedAuth: false)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "resolveGroup")
    #expect((failure?.message.contains("Sign in") ?? false))
    #expect(await transport.requests.isEmpty)
}

// MARK: - Download selection (architecture-matched, official only)

private func downloadAssets(checksum: String) -> [[String: Any]] {
    [
        ["os": "linux", "architecture": "x64", "download_url": "https://example.com/linux.tar.gz", "filename": "linux.tar.gz"],
        ["os": "osx", "architecture": "x64", "download_url": "https://example.com/osx-x64.tar.gz", "filename": "osx-x64.tar.gz", "sha256_checksum": "x64sum"],
        ["os": "osx", "architecture": "arm64", "download_url": "https://example.com/osx-arm64.tar.gz", "filename": "osx-arm64.tar.gz", "sha256_checksum": checksum],
    ]
}

@Test func prepareDownloadSelectsArchMatchedAsset() async {
    let transport = TestTransport([downloadsArrayPayload(downloadAssets(checksum: "arm64sum"))])
    let harness = await registrationHarness(transport: transport)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.prepareDownload)
    let ready = registrationActions(harness.logger).compactMap { action -> RunnerRegistration.DownloadAsset? in
        if case .downloadReady(let asset) = action { asset } else { nil }
    }
    #expect(ready.count == 1)
    #expect(ready.first?.architecture == "arm64")
    #expect(ready.first?.osName == "osx")
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests.first?.url.path.hasSuffix("/orgs/acme/actions/runners/downloads") ?? false)
    #expect(requests.first?.headers["Authorization"] == "Bearer user-token-42")
}

@Test func prepareDownloadRefusesSubstituteArch() async {
    let assets = [
        ["os": "osx", "architecture": "x64", "download_url": "https://example.com/osx-x64.tar.gz", "filename": "osx-x64.tar.gz", "sha256_checksum": "x64sum"],
        ["os": "linux", "architecture": "arm64", "download_url": "https://example.com/linux.tar.gz", "filename": "linux.tar.gz"],
    ]
    let transport = TestTransport([downloadsArrayPayload(assets)])
    let harness = await registrationHarness(transport: transport, arch: "arm64")
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.prepareDownload)
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "prepareDownload")
    #expect((failure?.message.contains("arm64") ?? false))
    #expect(FileManager.default.fileExists(atPath: harness.installRoot.appendingPathComponent("macbook-test").path) == false)
}

// MARK: - Groups (dedicated per-Mac, explicit scope)

@Test func orgResolveGroupFindsExistingWithoutCreating() async {
    let transport = TestTransport([
        groupsListPayload([
            groupPayload(id: 1, name: "Default", visibility: "all", allowsPublic: true),
            groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true),
        ]),
        jsonResponse(["repositories": [["id": 9], ["id": 10]]]),
    ])
    let harness = await registrationHarness(transport: transport)
    // Explicit takeover: this Mac adopts the pre-existing same-name group.
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    let resolved = registrationActions(harness.logger).compactMap { action -> (RunnerRegistration.RunnerGroup, [Int64])? in
        if case .groupResolved(let group, let ids) = action { (group, ids) } else { nil }
    }
    #expect(resolved.count == 1)
    #expect(resolved.first?.0.id == 5)
    #expect(resolved.first?.0.allowsPublicRepositories == true)
    #expect(resolved.first?.1.sorted() == [9, 10])
    let requests = await transport.requests
    #expect(requests.filter { $0.method == "POST" }.isEmpty)
}

@Test func orgResolveGroupCreatesWithSelectedRepos() async throws {
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 1, name: "Default", visibility: "all", allowsPublic: true)]),
        jsonResponse(groupPayload(id: 7, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true), status: 201),
        jsonResponse(["repositories": [["id": 9]]]),
    ])
    let harness = await registrationHarness(transport: transport)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    let requests = await transport.requests
    let posts = requests.filter { $0.method == "POST" }
    #expect(posts.count == 1)
    let body = try JSONDecoder().decode([String: JSONAny].self, from: posts[0].body ?? Data())
    #expect(body["name"]?.string == "RunnerControl-Mac")
    #expect(body["visibility"]?.string == "selected")
    #expect(body["selected_repository_ids"]?.ints?.sorted() == [9])
    // Dedicated groups opt into public repos so selected PUBLIC repos work.
    #expect(body["allows_public_repositories"]?.bool == true)
    // Creation records ownership for later resolves on this Mac.
    #expect(await harness.installer.loadOwnedGroupID(serverHost: "github.com", org: "acme", name: "RunnerControl-Mac") == 7)
}

/// Minimal JSON reader for asserting request bodies without DTO coupling.
private enum JSONAny: Decodable {
    case string(String)
    case ints([Int64])
    case bool(Bool)
    case other
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var ints: [Int64]? { if case .ints(let values) = self { values } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let values = try? container.decode([Int64].self) { self = .ints(values); return }
        self = .other
    }
}

@Test func repoScopeRefusesGroupResolution() async {
    let transport = TestTransport([])
    let harness = await registrationHarness(transport: transport)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(repoDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "resolveGroup")
    #expect((failure?.message.contains("organization") ?? false))
    #expect(await transport.requests.isEmpty)
}

private func harnessWithResolvedGroup(allow: Bool) async -> RegistrationHarness {
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
    ])
    let harness = await registrationHarness(transport: transport)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowGroup: allow, allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    return harness
}

@Test func repoAccessWithoutExplicitScopeIsRefused() async {
    let harness = await harnessWithResolvedGroup(allow: false)
    let before = await harness.transport.requests.count
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [9, 10]))
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "applyRepositoryAccess")
    #expect((failure?.message.contains("explicit") ?? false))
    #expect(await harness.transport.requests.count == before)
}

@Test func repoAccessToForeignGroupIsRefused() async {
    let harness = await harnessWithResolvedGroup(allow: true)
    let before = await harness.transport.requests.count
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 1, repositories: [9]))
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "applyRepositoryAccess")
    #expect((failure?.message.contains("not this Mac") ?? false))
    #expect(await harness.transport.requests.count == before)
}

@Test func repoAccessAppliesAndConfirmsRealIDs() async throws {
    // Review F2 regression: production PUT …/repositories answers 204 No
    // Content, which the client must accept as success.
    let harness = await harnessWithResolvedGroup(allow: true)
    await harness.transport.append(GitHubHTTPResponse(status: 204, body: Data()))
    await harness.transport.append(jsonResponse(["repositories": [["id": 9], ["id": 10]]]))
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [10, 9]))
    let applied = registrationActions(harness.logger).compactMap { action -> [Int64]? in
        if case .repositoryAccessApplied(let ids) = action { ids } else { nil }
    }
    #expect(applied.last?.sorted() == [9, 10])
    let puts = await harness.transport.requests.filter { $0.method == "PUT" }
    #expect(puts.count == 1)
    #expect(puts.first?.url.path.contains("/orgs/acme/actions/runner-groups/5/repositories") ?? false)
    let body = try JSONDecoder().decode([String: JSONAny].self, from: puts.first?.body ?? Data())
    #expect(body["selected_repository_ids"]?.ints?.sorted() == [9, 10])
}

// MARK: - Install (integrity, runsvc, idempotency)

@Test func downloadVerifiesIntegrityAgainstSystemShasum() async throws {
    let package = try await FixturePackage.make()
    let draft = orgDraft()
    let asset = RunnerRegistration.DownloadAsset(
        osName: "osx", architecture: "arm64",
        downloadURL: URL(string: "https://example.com/osx-arm64.tar.gz")!,
        filename: "osx-arm64.tar.gz", sha256Checksum: package.sha256ViaSystem
    )
    let harness = await registrationHarness(
        transport: TestTransport([]), downloader: fixtureDownloader(package.bytes)
    )
    let directory = try await harness.installer.downloadAndInstall(asset: asset, draft: draft)
    let files = FileManager.default
    #expect(files.fileExists(atPath: directory.appendingPathComponent("run.sh").path))
    let runsvc = directory.appendingPathComponent("runsvc.sh")
    #expect(files.fileExists(atPath: runsvc.path))
    let mode = try files.attributesOfItem(atPath: runsvc.path)[.posixPermissions] as? Int
    #expect(mode == 0o755)
    #expect(await harness.installer.hasCompleted(RunnerInstallerService.stepInstalled, directory: directory))
    // Idempotent: a completed install skips the download entirely.
    actor Counting {
        var count = 0
        func next(_ url: URL) async throws -> Data { count += 1; return Data() }
    }
    let counting = Counting()
    let skipper = RunnerInstallerService(
        installRoot: harness.installRoot,
        downloader: { url in try await counting.next(url) },
        currentArch: { "arm64" }
    )
    _ = try await skipper.downloadAndInstall(asset: asset, draft: draft)
    #expect(await counting.count == 0)
}

@Test func downloadRefusesTamperedBytes() async throws {
    let package = try await FixturePackage.make()
    var tampered = package.bytes
    tampered[tampered.count - 1] ^= 0xFF
    let draft = orgDraft()
    let asset = RunnerRegistration.DownloadAsset(
        osName: "osx", architecture: "arm64",
        downloadURL: URL(string: "https://example.com/osx-arm64.tar.gz")!,
        filename: "osx-arm64.tar.gz", sha256Checksum: package.sha256ViaSystem
    )
    let harness = await registrationHarness(
        transport: TestTransport([]), downloader: fixtureDownloader(tampered)
    )
    do {
        _ = try await harness.installer.downloadAndInstall(asset: asset, draft: draft)
        Issue.record("installer admitted tampered bytes")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .integrityMismatch = error else { Issue.record("wrong error: \(error)"); return }
    }
    let directory = await harness.installer.directory(for: draft.installDirName)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("run.sh").path) == false)
    #expect(await harness.installer.hasCompleted(RunnerInstallerService.stepInstalled, directory: directory) == false)
}

@Test func downloadRefusesMalformedChecksum() async throws {
    let package = try await FixturePackage.make()
    let draft = orgDraft()
    let asset = RunnerRegistration.DownloadAsset(
        osName: "osx", architecture: "arm64",
        downloadURL: URL(string: "https://example.com/osx-arm64.tar.gz")!,
        filename: "osx-arm64.tar.gz", sha256Checksum: "not-a-sha256"
    )
    let harness = await registrationHarness(
        transport: TestTransport([]), downloader: fixtureDownloader(package.bytes)
    )
    do {
        _ = try await harness.installer.downloadAndInstall(asset: asset, draft: draft)
        Issue.record("installer admitted malformed checksum")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .integrityMismatch = error else { Issue.record("wrong error: \(error)"); return }
    }
}

@Test func existingRegistrationBlocksFreshInstall() async throws {
    let package = try await FixturePackage.make()
    let harness = await registrationHarness(
        transport: TestTransport([]), downloader: fixtureDownloader(package.bytes)
    )
    let draft = orgDraft()
    let directory = await harness.installer.directory(for: draft.installDirName)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: directory.appendingPathComponent(".runner"))
    let asset = RunnerRegistration.DownloadAsset(
        osName: "osx", architecture: "arm64",
        downloadURL: URL(string: "https://example.com/x.tar.gz")!,
        filename: "x.tar.gz", sha256Checksum: nil
    )
    do {
        _ = try await harness.installer.downloadAndInstall(asset: asset, draft: draft)
        Issue.record("installer overwrote a registered directory")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .alreadyRegistered = error else { Issue.record("wrong error: \(error)"); return }
    }
}

// MARK: - Configure (exact invocation, no secret leakage)

@Test func runConfigUsesExactInvocation() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor()
    let harness = await registrationHarness(
        transport: TestTransport([]),
        downloader: fixtureDownloader(package.bytes),
        executor: executor
    )
    var draft = orgDraft()
    draft.allowReplace = true
    let asset = RunnerRegistration.DownloadAsset(
        osName: "osx", architecture: "arm64",
        downloadURL: URL(string: "https://example.com/x.tar.gz")!,
        filename: "x.tar.gz", sha256Checksum: package.sha256ViaSystem
    )
    let directory = try await harness.installer.downloadAndInstall(asset: asset, draft: draft)
    let agentID = try await harness.installer.runConfig(
        directory: directory, scopeURL: "https://github.com/acme",
        token: "REG-TOKEN", draft: draft, runnerGroup: "RunnerControl-Mac"
    )
    #expect(agentID == 4242)
    let calls = await executor.configCalls
    #expect(calls.count == 1)
    #expect(calls.first == [
        "--url", "https://github.com/acme",
        "--token", "REG-TOKEN",
        "--name", "macbook-test",
        "--work", "_work",
        "--labels", "self-hosted,macOS",
        "--runnergroup", "RunnerControl-Mac",
        "--unattended", "--replace",
    ])
}

@Test func runConfigOmitsReplaceByDefault() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor()
    let harness = await registrationHarness(
        transport: TestTransport([]),
        downloader: fixtureDownloader(package.bytes),
        executor: executor
    )
    let draft = orgDraft()
    let asset = RunnerRegistration.DownloadAsset(
        osName: "osx", architecture: "arm64",
        downloadURL: URL(string: "https://example.com/x.tar.gz")!,
        filename: "x.tar.gz", sha256Checksum: package.sha256ViaSystem
    )
    let directory = try await harness.installer.downloadAndInstall(asset: asset, draft: draft)
    _ = try await harness.installer.runConfig(
        directory: directory, scopeURL: "https://github.com/acme",
        token: "REG-TOKEN", draft: draft, runnerGroup: "RunnerControl-Mac"
    )
    let calls = await executor.configCalls
    #expect(calls.count == 1)
    #expect(!(calls.first?.contains("--replace") ?? true))
    #expect(calls.first?.last == "--unattended")
}

@Test func runConfigScrubsTokenFromFailure() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor()
    await executor.setFailure(CommandResult(code: 1, output: "config failed for --token SUPER-SECRET-TOKEN tail"))
    let harness = await registrationHarness(
        transport: TestTransport([]),
        downloader: fixtureDownloader(package.bytes),
        executor: executor
    )
    let draft = orgDraft()
    let asset = RunnerRegistration.DownloadAsset(
        osName: "osx", architecture: "arm64",
        downloadURL: URL(string: "https://example.com/x.tar.gz")!,
        filename: "x.tar.gz", sha256Checksum: package.sha256ViaSystem
    )
    let directory = try await harness.installer.downloadAndInstall(asset: asset, draft: draft)
    do {
        try await harness.installer.runConfig(
            directory: directory, scopeURL: "https://github.com/acme",
            token: "SUPER-SECRET-TOKEN", draft: draft, runnerGroup: "RunnerControl-Mac"
        )
        Issue.record("runConfig swallowed a failing script")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .configFailed(let text) = error else { Issue.record("wrong error: \(error)"); return }
        #expect(!text.contains("SUPER-SECRET-TOKEN"))
        #expect(text.contains("[REDACTED]"))
    }
}

private extension SplitExecutor {
    func setFailure(_ result: CommandResult) { failure = result }
}

@Test func runConfigExecutesRealScript() async throws {
    // The fixture config.sh is a real executable shell script: production
    // runConfig must execute it (not only a fake) and read back `.runner`.
    let package = try await FixturePackage.make(withRealConfigScript: true)
    let harness = await registrationHarness(
        transport: TestTransport([]), downloader: fixtureDownloader(package.bytes)
    )
    let draft = orgDraft()
    let asset = RunnerRegistration.DownloadAsset(
        osName: "osx", architecture: "arm64",
        downloadURL: URL(string: "https://example.com/x.tar.gz")!,
        filename: "x.tar.gz", sha256Checksum: package.sha256ViaSystem
    )
    let directory = try await harness.installer.downloadAndInstall(asset: asset, draft: draft)
    let agentID = try await harness.installer.runConfig(
        directory: directory, scopeURL: "https://github.com/acme",
        token: "REG-TOKEN", draft: draft, runnerGroup: "RunnerControl-Mac"
    )
    #expect(agentID == 4242)
    let data = try Data(contentsOf: directory.appendingPathComponent(".runner"))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["agentName"] as? String == "macbook-test")
}

// MARK: - Service (manual LaunchAgent, discovered)

@Test func setupServiceWritesManualPlistFoundByDiscovery() async throws {
    let package = try await FixturePackage.make()
    let harness = await registrationHarness(
        transport: TestTransport([]), downloader: fixtureDownloader(package.bytes)
    )
    let draft = orgDraft()
    let asset = RunnerRegistration.DownloadAsset(
        osName: "osx", architecture: "arm64",
        downloadURL: URL(string: "https://example.com/x.tar.gz")!,
        filename: "x.tar.gz", sha256Checksum: package.sha256ViaSystem
    )
    let directory = try await harness.installer.downloadAndInstall(asset: asset, draft: draft)
    try Data("""
    {"agentId":4242,"agentName":"macbook-test","gitHubUrl":"https://github.com/acme","workFolder":"_work"}
    """.utf8).write(to: directory.appendingPathComponent(".runner"))
    let label = RunnerRegistration.Flow.serviceLabel(draft: draft)
    let plist = try await harness.installer.setupService(directory: directory, label: label)
    let data = try Data(contentsOf: plist)
    let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    #expect(object?["Label"] as? String == label)
    #expect(object?["ProgramArguments"] as? [String] == [directory.appendingPathComponent("runsvc.sh").path])
    #expect(object?["WorkingDirectory"] as? String == directory.path)
    #expect(object?["RunAtLoad"] as? Bool == false)
    // The wizard output must be visible to production discovery.
    let found = RunnerDiscovery.installed(home: harness.home)
    #expect(found.count == 1)
    #expect(found.first?.title == "macbook-test")
    #expect(found.first?.detail == "acme")
}

// MARK: - Recovery and token lifetime

@Test func recoverPartialInstallRefusesWorkingRunner() async throws {
    let harness = await registrationHarness(transport: TestTransport([]))
    let draft = orgDraft()
    let occupied = await harness.installer.directory(for: draft.installDirName)
    try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: occupied.appendingPathComponent(".runner"))
    do {
        try await harness.installer.recoverPartialInstall(directory: occupied, scopeKey: draft.scope.scopeKey)
        Issue.record("recovery deleted a registered runner")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .alreadyRegistered = error else { Issue.record("wrong error: \(error)"); return }
    }
    #expect(FileManager.default.fileExists(atPath: occupied.path))
    let partial = harness.installRoot.appendingPathComponent("partial-dir")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try await harness.installer.recoverPartialInstall(directory: partial, scopeKey: draft.scope.scopeKey)
    #expect(FileManager.default.fileExists(atPath: partial.path) == false)
}

@Test func registrationTokenStoreExpiresShortLivedToken() async throws {
    let store = RunnerRegistrationTokenStore(backend: InMemoryRegistrationTokenBackend())
    let live = RunnerRegistration.ScopedToken(token: "live", expiresAt: Date().addingTimeInterval(60))
    try await store.save(live, scopeKey: "org:acme:dir")
    #expect(await store.load(scopeKey: "org:acme:dir") == live)
    let dead = RunnerRegistration.ScopedToken(token: "dead", expiresAt: Date().addingTimeInterval(-5))
    try await store.save(dead, scopeKey: "org:acme:other")
    #expect(await store.load(scopeKey: "org:acme:other") == nil)
    await store.delete(scopeKey: "org:acme:dir")
    #expect(await store.load(scopeKey: "org:acme:dir") == nil)
}

// MARK: - End-to-end wizard through production Flow effects

private func runnersListPayload(_ runners: [[String: Any]]) -> GitHubHTTPResponse {
    jsonResponse(["runners": runners])
}

@Test func orgWizardEndToEndDeletesTokenAndLeaksNothing() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor()
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-1", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": [["name": "self-hosted"], ["name": "macOS"]]]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: executor
    )
    let draft = orgDraft(allowTakeover: true)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(draft))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    _ = await harness.flow.apply(RunnerRegistration.Effect.setupService)
    let actions = registrationActions(harness.logger)
    let registered = actions.compactMap { action -> (Int64?, Int64?)? in
        if case .registered(let runnerID, let localID) = action { (runnerID, localID) } else { nil }
    }
    // Real IDs: remote GitHub runner ID bound to the verified local agent ID.
    #expect(registered.last?.0 == 4242)
    #expect(registered.last?.1 == 4242)
    #expect(actions.contains { if case .serviceReady = $0 { true } else { false } })
    // The short-lived registration token is deleted immediately after use.
    let scopeKey = RunnerRegistration.Flow.tokenScopeKey(draft: draft)
    #expect(await harness.registrationTokens.load(scopeKey: scopeKey) == nil)
    // No secret leakage: the registration token appears nowhere in
    // dispatched actions, request URLs, headers, or bodies.
    let haystack = actions.map { String(describing: $0) }.joined(separator: "\n")
    #expect(!haystack.contains("REG-SECRET-1"))
    for request in await transport.requests {
        #expect(!request.url.absoluteString.contains("REG-SECRET-1"))
        #expect(!request.headers.values.joined().contains("REG-SECRET-1"))
        if let body = request.body {
            #expect(!String(decoding: body, as: UTF8.self).contains("REG-SECRET-1"))
        }
    }
    // The token reached exactly one place: the config.sh argv in memory.
    let calls = await executor.configCalls
    #expect(calls.count == 1)
    #expect(calls.first?.contains("REG-SECRET-1") ?? false)
    #expect(calls.first?.contains("--runnergroup") ?? false)
    // Wizard output is discoverable and launchable by production code.
    #expect(RunnerDiscovery.installed(home: harness.home).count == 1)
}

@Test func repoWizardOmitsRunnerGroup() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor(gitHubURL: "https://github.com/octo/app")
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-2", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "personal-runner", "labels": [["name": "self-hosted"]]]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: executor
    )
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(repoDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let calls = await executor.configCalls
    #expect(calls.count == 1)
    #expect(!(calls.first?.contains("--runnergroup") ?? true))
    let requests = await transport.requests
    #expect(requests.allSatisfy { !$0.url.path.contains("runner-groups") })
    #expect(requests.contains { $0.url.path.contains("/repos/octo/app/actions/runners/registration-token") })
}

@Test func retryResumesFailedDownloadWithoutDuplicates() async throws {
    let package = try await FixturePackage.make()
    actor Flaky {
        let bytes: Data
        var calls = 0
        init(bytes: Data) { self.bytes = bytes }
        func next(_ url: URL) async throws -> Data {
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
            return bytes
        }
    }
    let flaky = Flaky(bytes: package.bytes)
    let transport = TestTransport([downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem))])
    let harness = await registrationHarness(
        transport: transport,
        downloader: { url in try await flaky.next(url) }
    )
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    #expect(lastFailure(harness.logger)?.step == "downloadAndInstall")
    _ = await harness.flow.apply(RunnerRegistration.Effect.retry)
    let actions = registrationActions(harness.logger)
    #expect(actions.contains { if case .installed = $0 { true } else { false } })
    // The asset resolved once; the retry resumed the download, not the lookup.
    #expect(await transport.requests.count == 1)
    #expect(await flaky.calls == 2)
    let directory = await harness.installer.directory(for: "macbook-test")
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("run.sh").path))
}

@Test func registerIsIdempotentAcrossRetries() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor()
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-3", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: executor
    )
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let tokenPosts = await transport.requests.filter {
        $0.method == "POST" && $0.url.path.contains("registration-token")
    }
    // The retry minted no second token and ran config.sh exactly once:
    // no orphan or duplicate GitHub registrations.
    #expect(tokenPosts.count == 1)
    #expect(await executor.configCalls.count == 1)
    let registered = registrationActions(harness.logger).filter {
        if case .registered = $0 { true } else { false }
    }
    #expect(registered.count == 2)
}

@Test func failedConfigDeletesTokenAndReportsScrubbedError() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor()
    await executor.setFailure(CommandResult(code: 1, output: "bad --token REG-SECRET-9"))
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-9", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: executor
    )
    let draft = orgDraft()
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(draft))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "registerRunner")
    #expect(!(failure?.message.contains("REG-SECRET-9") ?? true))
    let scopeKey = RunnerRegistration.Flow.tokenScopeKey(draft: draft)
    #expect(await harness.registrationTokens.load(scopeKey: scopeKey) == nil)
    _ = await harness.flow.apply(RunnerRegistration.Effect.cancel)
    #expect(registrationActions(harness.logger).contains { if case .cancelled = $0 { true } else { false } })
}

@Test func postConfigAPIFailureDeletesTokenAndReportsError() async throws {
    // Review F6 regression: the single-use token is consumed by config.sh,
    // so a failing follow-up API call must report the error without
    // retaining the token.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor()
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-6", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        GitHubHTTPResponse(status: 500, body: Data("boom".utf8)),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: executor
    )
    let draft = orgDraft()
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(draft))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "registerRunner")
    #expect((failure?.message.contains("500") ?? false))
    #expect(await executor.configCalls.count == 1)
    let scopeKey = RunnerRegistration.Flow.tokenScopeKey(draft: draft)
    #expect(await harness.registrationTokens.load(scopeKey: scopeKey) == nil)
}

// MARK: - Permission errors (retained, explicit clear)

@Test @MainActor func permissionErrorRetainedAcrossEditsUntilRetrySucceeds() async {
    let transport = TestTransport([
        GitHubHTTPResponse(status: 403, body: Data("Resource not accessible by integration".utf8)),
    ])
    let harness = await registrationHarness(transport: transport)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    var edited = orgDraft(allowTakeover: true)
    edited.runnerName = "renamed-mac"
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
    let state = RunnerRegistration.State()
    for action in registrationActions(harness.logger) { await state.reduce(with: action) }
    #expect(state.permissionError?.contains("Missing permission") ?? false)
    #expect(state.draft?.runnerName == "renamed-mac")
    // Access granted later: retry succeeds and clears the retained error.
    await transport.append(groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]))
    await transport.append(jsonResponse(["repositories": [["id": 9]]]))
    let seen = registrationActions(harness.logger).count
    _ = await harness.flow.apply(RunnerRegistration.Effect.retry)
    for action in registrationActions(harness.logger).dropFirst(seen) { await state.reduce(with: action) }
    #expect(state.group?.id == 5)
    #expect(state.permissionError == nil)
}

@Test func forbiddenGroupCreateNamesRequiredPermission() async {
    let transport = TestTransport([
        jsonResponse(["runner_groups": [["id": 1, "name": "Default", "visibility": "all"]]]),
        GitHubHTTPResponse(status: 403, body: Data("Resource not accessible by integration".utf8)),
    ])
    let harness = await registrationHarness(transport: transport)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    let actions = registrationActions(harness.logger)
    #expect(actions.contains {
        if case .permissionDenied(let message, _) = $0, message.contains("Self-hosted runners/write") { true } else { false }
    })
}

// MARK: - Group ownership (name alone never authorizes)

@Test func existingGroupNameWithoutTakeoverIsRefused() async {
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
    ])
    let harness = await registrationHarness(transport: transport)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "resolveGroup")
    #expect((failure?.message.contains("already exists") ?? false))
    #expect((failure?.message.contains("takeover") ?? false))
    // No mutation followed the refused adoption: no POST, PATCH, or PUT.
    let writes = await transport.requests.filter { $0.method != "GET" }
    #expect(writes.isEmpty)
    #expect(await harness.installer.loadOwnedGroupID(serverHost: "github.com", org: "acme", name: "RunnerControl-Mac") == nil)
}

@Test func ownedGroupResolvesWithoutRetakeover() async throws {
    // First run creates the group and records ownership on this Mac.
    let first = TestTransport([
        groupsListPayload([groupPayload(id: 1, name: "Default", visibility: "all", allowsPublic: true)]),
        jsonResponse(groupPayload(id: 7, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true), status: 201),
        jsonResponse(["repositories": [["id": 9]]]),
    ])
    let harness = await registrationHarness(transport: first)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    #expect(await harness.installer.loadOwnedGroupID(serverHost: "github.com", org: "acme", name: "RunnerControl-Mac") == 7)
    // Second run (fresh Flow, same install root) reuses the owned group
    // without asking for takeover again.
    let second = TestTransport([
        groupsListPayload([
            groupPayload(id: 1, name: "Default", visibility: "all", allowsPublic: true),
            groupPayload(id: 7, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true),
        ]),
        jsonResponse(["repositories": [["id": 9]]]),
    ])
    let logger = Relux.Testing.Logger()
    let dispatcher = Relux.Dispatcher(logger: logger)
    let api = GitHubRunnerAPIClient(transport: second)
    let refresher = GitHubTokenRefresh(transport: second, store: harness.userStore)
    let identities = InMemoryGitHubSessionIdentityStore()
    await identities.save(GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo"))
    let flow = await RunnerRegistration.Flow(
        api: api, installer: harness.installer, registrationTokens: harness.registrationTokens,
        userStore: harness.userStore, identityStore: identities, refresher: refresher,
        configProvider: { _ in testConfig }, dispatcher: dispatcher
    )
    _ = await flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await flow.apply(RunnerRegistration.Effect.resolveGroup)
    let resolved = logger.actions.compactMap { $0 as? RunnerRegistration.Action }.compactMap { action -> Int64? in
        if case .groupResolved(let group, _) = action { group.id } else { nil }
    }
    #expect(resolved == [7])
    #expect(await second.requests.filter { $0.method == "POST" }.isEmpty)
}

@Test func takeoverRecordsOwnershipForRetries() async throws {
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
    ])
    let harness = await registrationHarness(transport: transport)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    #expect(await harness.installer.loadOwnedGroupID(serverHost: "github.com", org: "acme", name: "RunnerControl-Mac") == 5)
}

// MARK: - Public repositories (allows_public_repositories)

@Test func resolvePatchesDeniedPublicReposOnOwnedGroup() async throws {
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: false)]),
        jsonResponse(groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)),
        jsonResponse(["repositories": [["id": 9]]]),
    ])
    let harness = await registrationHarness(transport: transport)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    let patches = await transport.requests.filter { $0.method == "PATCH" }
    #expect(patches.count == 1)
    #expect(patches.first?.url.path.contains("/orgs/acme/actions/runner-groups/5") ?? false)
    let body = try JSONDecoder().decode([String: JSONAny].self, from: patches.first?.body ?? Data())
    #expect(body["allows_public_repositories"]?.bool == true)
    let resolved = registrationActions(harness.logger).compactMap { action -> RunnerRegistration.RunnerGroup? in
        if case .groupResolved(let group, _) = action { group } else { nil }
    }
    #expect(resolved.first?.allowsPublicRepositories == true)
}

@Test func resolveSkipsPatchWhenPublicReposAllowed() async {
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
    ])
    let harness = await registrationHarness(transport: transport)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    #expect(await transport.requests.filter { $0.method == "PATCH" }.isEmpty)
}

// MARK: - Remote duplicate names (no silent --replace)

@Test func remoteDuplicateWithoutReplaceIsRefusedBeforeToken() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor()
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([["id": 99, "name": "macbook-test", "labels": []]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: executor
    )
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "registerRunner")
    #expect((failure?.message.contains("already exists in GitHub") ?? false))
    // No registration token was minted and config.sh never ran.
    let tokenPosts = await transport.requests.filter {
        $0.method == "POST" && $0.url.path.contains("registration-token")
    }
    #expect(tokenPosts.isEmpty)
    #expect(await executor.configCalls.isEmpty)
}

@Test func remoteDuplicateWithReplaceProceedsWithFlag() async throws {
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor()
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([["id": 99, "name": "macbook-test", "labels": []]]),
        jsonResponse(["token": "REG-SECRET-5", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: executor
    )
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowReplace: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let calls = await executor.configCalls
    #expect(calls.count == 1)
    #expect(calls.first?.contains("--replace") ?? false)
    let registered = registrationActions(harness.logger).compactMap { action -> Int64? in
        if case .registered(let runnerID, _) = action, let runnerID { runnerID } else { nil }
    }
    // After --replace GitHub lists the new agent, which binds by verified ID.
    #expect(registered.last == 4242)
}

// MARK: - Missing checksum (fail closed)

@Test func downloadRefusesMissingChecksum() async throws {
    let package = try await FixturePackage.make()
    let draft = orgDraft()
    let asset = RunnerRegistration.DownloadAsset(
        osName: "osx", architecture: "arm64",
        downloadURL: URL(string: "https://example.com/osx-arm64.tar.gz")!,
        filename: "osx-arm64.tar.gz", sha256Checksum: nil
    )
    let harness = await registrationHarness(
        transport: TestTransport([]), downloader: fixtureDownloader(package.bytes)
    )
    do {
        _ = try await harness.installer.downloadAndInstall(asset: asset, draft: draft)
        Issue.record("installer admitted a package without a checksum")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .integrityMismatch = error else { Issue.record("wrong error: \(error)"); return }
    }
    let directory = await harness.installer.directory(for: draft.installDirName)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("run.sh").path) == false)
}

// MARK: - Labels (editable with real IDs)

@Test func labelsApplyRequiresRealRunnerIDThenPuts() async throws {
    // Labels bind to the verified local agent on every write: a list that
    // does not contain this agent fails instead of guessing by name, and a
    // retry after convergence PUTs exactly the bound ID.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-7", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        runnersListPayload([]),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        jsonResponse([["id": 1, "name": "self-hosted"]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyLabels(["self-hosted", "macOS", "gpu"]))
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "applyLabels")
    #expect(failure?.message.contains("refusing to guess") ?? false)
    #expect(await transport.requests.filter { $0.method == "PUT" }.isEmpty)
    _ = await harness.flow.apply(RunnerRegistration.Effect.retry)
    let applied = registrationActions(harness.logger).compactMap { action -> [String]? in
        if case .labelsApplied(let labels) = action { labels } else { nil }
    }
    #expect(applied.last == ["self-hosted", "macOS", "gpu"])
    let puts = await transport.requests.filter { $0.method == "PUT" }
    #expect(puts.count == 1)
    #expect(puts.first?.url.path.contains("/orgs/acme/actions/runners/4242/labels") ?? false)
}

// MARK: - R2 regressions: list URLs, identity, invalidation, pagination, service gate

/// Builds a paginated list page with an optional `Link: rel="next"` header.
private func pagedResponse(_ object: Any, next: String? = nil) -> GitHubHTTPResponse {
    // Static test literals always serialize.
    // swiftlint:disable:next force_try
    let data = try! JSONSerialization.data(withJSONObject: object)
    var headers: [String: String] = [:]
    if let next { headers["Link"] = "<\(next)>; rel=\"next\"" }
    return GitHubHTTPResponse(status: 200, headers: headers, body: data)
}

private func hasPerPageQuery(_ url: URL) -> Bool {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(
        URLQueryItem(name: "per_page", value: "100")
    ) == true
}

@Test func orgListRequestsUseQueryNotEncodedPath() async throws {
    // R2-F1: list requests must carry per_page as a real query, not as an
    // encoded "%3F" segment of the path GitHub never parses.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-8", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let lists = await transport.requests.filter {
        $0.method == "GET" && ($0.url.path.contains("runner-groups") || $0.url.path.hasSuffix("/actions/runners"))
    }
    // Groups list, group repositories, runners pre-check, runners post-config.
    #expect(lists.count == 4)
    for request in lists {
        #expect(!request.url.absoluteString.contains("%3F"))
        #expect(hasPerPageQuery(request.url))
    }
    #expect(lists.first?.url.path == "/orgs/acme/actions/runner-groups")
    #expect(lists.contains { $0.url.path == "/orgs/acme/actions/runners" })
}

@Test func repoRunnerListRequestUsesQueryNotEncodedPath() async throws {
    // R2-F1 (repository scope): same query contract on the repo list route.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-9", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "personal-runner", "labels": []]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: SplitExecutor(gitHubURL: "https://github.com/octo/app")
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(repoDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let lists = await transport.requests.filter {
        $0.method == "GET" && $0.url.path.hasSuffix("/actions/runners")
    }
    #expect(lists.count == 2)
    for request in lists {
        #expect(request.url.path == "/repos/octo/app/actions/runners")
        #expect(!request.url.absoluteString.contains("%3F"))
        #expect(hasPerPageQuery(request.url))
    }
}

@Test func labelsWithoutLocalRegistrationAreRefused() async {
    // R2-F2 (repeat-of rev1/F5): a remote name match alone never authorizes
    // a label write. Refused before any network: no GET, no PUT.
    let transport = TestTransport([
        runnersListPayload([["id": 77, "name": "macbook-test", "labels": []]]),
        jsonResponse(["labels": [["name": "gpu"]]]),
    ])
    let harness = await registrationHarness(transport: transport)
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyLabels(["gpu"]))
    #expect(lastFailure(harness.logger)?.step == "applyLabels")
    #expect(await transport.requests.isEmpty)
    #expect(!registrationActions(harness.logger).contains { if case .labelsApplied = $0 { true } else { false } })
}

@Test func labelsWithMismatchedRemoteIdentityAreRefused() async throws {
    // R2-F2: this installation is agent 4242; a same-name foreign 77 in the
    // list must fail the write instead of becoming the PUT target.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-10", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        runnersListPayload([["id": 77, "name": "macbook-test", "labels": []]]),
        jsonResponse(["labels": [["name": "gpu"]]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyLabels(["gpu"]))
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "applyLabels")
    #expect(failure?.message.contains("agent 77") ?? false)
    let foreignWrites = await transport.requests.filter {
        $0.method == "PUT" && $0.url.path.contains("/77/labels")
    }
    #expect(foreignWrites.isEmpty)
    #expect(await transport.requests.filter { $0.method == "PUT" }.isEmpty)
}

@Test func registerRefusesMismatchedRemoteIdentity() async throws {
    // R2-F2 at registration: config wrote agent 4242 but GitHub shows the
    // name as foreign agent 77. The run fails instead of adopting 77, and
    // the consumed token is still deleted.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-11", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 77, "name": "macbook-test", "labels": []]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let draft = orgDraft()
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(draft))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "registerRunner")
    #expect(failure?.message.contains("agent 77") ?? false)
    #expect(!registrationActions(harness.logger).contains { if case .registered = $0 { true } else { false } })
    let scopeKey = RunnerRegistration.Flow.tokenScopeKey(draft: draft)
    #expect(await harness.registrationTokens.load(scopeKey: scopeKey) == nil)
}

@Test func registerReportsNilWhenAgentNotYetListed() async throws {
    // Convergence case: config wrote agent 4242 but GitHub does not list it
    // yet. Registration succeeds with a nil remote ID (retryable) instead of
    // failing or guessing a same-name entry.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-12", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 77, "name": "other-runner", "labels": []]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let registered = registrationActions(harness.logger).compactMap { action -> (Int64?, Int64?)? in
        if case .registered(let runnerID, let localID) = action { (runnerID, localID) } else { nil }
    }
    #expect(registered.count == 1)
    #expect(registered.first?.0 == nil)
    #expect(registered.first?.1 == 4242)
    #expect(registrationActions(harness.logger).contains {
        if case .stepFinished(let step) = $0, step == "registerRunner" { true } else { false }
    })
}

@Test func labelsRefusePlantedUnconfiguredRegistration() async throws {
    // R2-F2: a matching `.runner` planted without this wizard's configured
    // marker is not this operation's registration. Refused without a PUT.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        jsonResponse(["labels": [["name": "gpu"]]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    let directory = await harness.installer.directory(for: "macbook-test")
    try Data(#"{"agentId":4242,"agentName":"macbook-test","gitHubUrl":"https://github.com/acme","workFolder":"_work"}"#.utf8)
        .write(to: directory.appendingPathComponent(".runner"))
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyLabels(["gpu"]))
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "applyLabels")
    #expect(failure?.message.contains("never configured") ?? false)
    #expect(await transport.requests.filter { $0.method == "PUT" }.isEmpty)
}

@Test func changedScopeMustNotReuseRegistrationOrRemoteID() async throws {
    // R2-F3: after a scope/install edit the old registration evidence is
    // dropped. Labels for the new scope are refused; no PUT may reuse the
    // old agent ID under the new scope's route.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-13", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        jsonResponse(["labels": [["name": "gpu"]]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    var edited = orgDraft()
    edited.scope = .repository(owner: "octo", name: "app")
    edited.installDirName = "different-install"
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyLabels(["gpu"]))
    #expect(lastFailure(harness.logger)?.step == "applyLabels")
    let foreignWrites = await transport.requests.filter {
        $0.method == "PUT" && $0.url.path.contains("/repos/octo/app/actions/runners/4242/labels")
    }
    #expect(foreignWrites.isEmpty)
    #expect(await transport.requests.filter { $0.method == "PUT" }.isEmpty)
}

@Test @MainActor func scopeChangeClearsCompletedStepsInState() async {
    // R2-F3 (reducer): a scope edit drops group/install/runner progress and
    // demotes a done wizard back to drafting instead of displaying another
    // registration's evidence.
    let state = RunnerRegistration.State()
    await state.reduce(with: RunnerRegistration.Action.draftBegan(orgDraft()))
    await state.reduce(with: RunnerRegistration.Action.groupResolved(
        RunnerRegistration.RunnerGroup(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublicRepositories: true),
        repositoryIDs: [9]
    ))
    await state.reduce(with: RunnerRegistration.Action.stepFinished("resolveGroup"))
    await state.reduce(with: RunnerRegistration.Action.installed(path: "/tmp/macbook-test"))
    await state.reduce(with: RunnerRegistration.Action.stepFinished("downloadAndInstall"))
    await state.reduce(with: RunnerRegistration.Action.registered(runnerID: 4242, localAgentID: 4242))
    await state.reduce(with: RunnerRegistration.Action.stepFinished("registerRunner"))
    await state.reduce(with: RunnerRegistration.Action.serviceReady(plistPath: "/tmp/macbook-test/manual-service.plist"))
    #expect(state.phase == .done)
    await state.reduce(with: RunnerRegistration.Action.draftUpdated(repoDraft()))
    #expect(state.completedSteps.isEmpty)
    #expect(state.group == nil)
    #expect(state.groupRepositoryIDs.isEmpty)
    #expect(state.installPath == nil)
    #expect(state.runnerID == nil)
    #expect(state.localAgentID == nil)
    #expect(state.phase == .drafting)
    #expect(state.draft?.scope == .repository(owner: "octo", name: "app"))
}

@Test func installDirChangeKeepsGroupButRequiresFreshInstall() async throws {
    // R2-F3 (selective): an install-dir edit keeps the resolved group but
    // drops install/registration progress, so the next register refuses to
    // reuse the old directory while repo access still applies to the group.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-14", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        GitHubHTTPResponse(status: 204, body: Data()),
        jsonResponse(["repositories": [["id": 9], ["id": 10]]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    var edited = orgDraft(allowTakeover: true)
    edited.installDirName = "second-dir"
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "registerRunner")
    #expect(failure?.message.contains("Install the runner package first") ?? false)
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [9, 10]))
    let applied = registrationActions(harness.logger).compactMap { action -> [Int64]? in
        if case .repositoryAccessApplied(let ids) = action { ids } else { nil }
    }
    #expect(applied.last?.sorted() == [9, 10])
    #expect(await transport.requests.filter { $0.method == "PUT" }.count == 1)
}

@Test func groupNameChangeInvalidatesResolvedGroup() async {
    // R2-F3 (selective): a group-name edit drops the resolved group, so repo
    // access against the old ID is refused until the new group resolves.
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
    ])
    let harness = await registrationHarness(transport: transport)
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    var edited = orgDraft(allowTakeover: true)
    edited.groupName = "Other-Mac"
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [9]))
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "applyRepositoryAccess")
    #expect(failure?.message.contains("Resolve the dedicated group first") ?? false)
    #expect(await transport.requests.filter { $0.method == "PUT" }.isEmpty)
}

@Test func retryAfterScopeChangeIsNoop() async throws {
    // R2-F3 (retry): a scope edit clears the failed step, so retry cannot
    // re-run the old scope's failure against the new draft.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([["id": 99, "name": "macbook-test", "labels": []]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    #expect(lastFailure(harness.logger)?.step == "registerRunner")
    let before = await transport.requests.count
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(repoDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.retry)
    #expect(await transport.requests.count == before)
}

@Test func repositoryConfirmationFollowsPagination() async throws {
    // R2-F4: the confirm read follows every page. A first page of [9] with a
    // next link plus a second page of [10] confirms [9, 10], not [9].
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
        GitHubHTTPResponse(status: 204, body: Data()),
        pagedResponse(
            ["total_count": 2, "repositories": [["id": 9]]],
            next: "https://api.github.com/orgs/acme/actions/runner-groups/5/repositories?per_page=100&page=2"
        ),
        jsonResponse(["total_count": 2, "repositories": [["id": 10]]]),
    ])
    let harness = await registrationHarness(transport: transport)
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [9, 10]))
    let confirmed = registrationActions(harness.logger).compactMap { action -> [Int64]? in
        if case .repositoryAccessApplied(let ids) = action { ids } else { nil }
    }
    #expect(confirmed.last.map(Set.init) == Set<Int64>([9, 10]))
    #expect(await transport.requests.contains { $0.url.query?.contains("page=2") == true })
}

@Test func repositoryConfirmationMismatchIsRefused() async {
    // R2-F4: a complete confirm of [9] against requested [9, 10] fails
    // instead of reporting partial access as success. Both directions —
    // missing and extra IDs — fail closed.
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
        GitHubHTTPResponse(status: 204, body: Data()),
        jsonResponse(["repositories": [["id": 9]]]),
    ])
    let harness = await registrationHarness(transport: transport)
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [9, 10]))
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "applyRepositoryAccess")
    #expect(failure?.message.contains("confirmed repositories") ?? false)
    #expect(!registrationActions(harness.logger).contains {
        if case .repositoryAccessApplied = $0 { true } else { false }
    })
    // Extra-IDs direction: confirm [9, 10] against requested [9] also fails.
    let extra = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
        GitHubHTTPResponse(status: 204, body: Data()),
        jsonResponse(["repositories": [["id": 9], ["id": 10]]]),
    ])
    let second = await registrationHarness(transport: extra)
    defer { try? FileManager.default.removeItem(at: second.home) }
    _ = await second.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await second.flow.apply(RunnerRegistration.Effect.resolveGroup)
    _ = await second.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [9]))
    #expect(lastFailure(second.logger)?.step == "applyRepositoryAccess")
    #expect(!registrationActions(second.logger).contains {
        if case .repositoryAccessApplied = $0 { true } else { false }
    })
}

@Test func scopeChangeRefreshesDownloadAsset() async throws {
    // R2-F3: a scope edit drops the resolved download asset, so the next
    // install fetches the new scope's download list instead of reusing the
    // old scope's asset.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes)
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.prepareDownload)
    var edited = orgDraft()
    edited.scope = .repository(owner: "octo", name: "app")
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    let downloads = await transport.requests.filter { $0.url.path.hasSuffix("/actions/runners/downloads") }
    #expect(downloads.count == 2)
    #expect(downloads.contains { $0.url.path == "/repos/octo/app/actions/runners/downloads" })
}

@Test func repositorySecondPageFailurePreservesUnknown() async {
    // R2-F4: a failed second page fails the step. No partial IDs are
    // applied, synced, or reported.
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
        GitHubHTTPResponse(status: 204, body: Data()),
        pagedResponse(
            ["total_count": 2, "repositories": [["id": 9]]],
            next: "https://api.github.com/orgs/acme/actions/runner-groups/5/repositories?per_page=100&page=2"
        ),
        GitHubHTTPResponse(status: 500, body: Data("boom".utf8)),
    ])
    let harness = await registrationHarness(transport: transport)
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [9, 10]))
    #expect(lastFailure(harness.logger)?.step == "applyRepositoryAccess")
    #expect(!registrationActions(harness.logger).contains {
        if case .repositoryAccessApplied = $0 { true } else { false }
    })
}

@Test func runnerListFollowsPaginationForDuplicateGuard() async throws {
    // R2-F4: the pre-token duplicate guard sees the complete runner list. A
    // same-name runner on page 2 refuses the run before any token is minted.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = SplitExecutor()
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        pagedResponse(
            ["runners": [["id": 1, "name": "other-runner", "labels": []]]],
            next: "https://api.github.com/orgs/acme/actions/runners?per_page=100&page=2"
        ),
        runnersListPayload([["id": 99, "name": "macbook-test", "labels": []]]),
    ])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: executor
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "registerRunner")
    #expect(failure?.message.contains("already exists in GitHub") ?? false)
    #expect(await transport.requests.filter {
        $0.method == "POST" && $0.url.path.contains("registration-token")
    }.isEmpty)
    #expect(await executor.configCalls.isEmpty)
    #expect(await transport.requests.contains { $0.url.query?.contains("page=2") == true })
}

@Test func groupListFollowsPagination() async {
    // R2-F4: group resolution sees the complete group list. A dedicated
    // group on page 2 resolves without creating a duplicate.
    let transport = TestTransport([
        pagedResponse(
            ["runner_groups": [["id": 1, "name": "Default", "visibility": "all", "allows_public_repositories": true]]],
            next: "https://api.github.com/orgs/acme/actions/runner-groups?per_page=100&page=2"
        ),
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
    ])
    let harness = await registrationHarness(transport: transport)
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    let resolved = registrationActions(harness.logger).compactMap { action -> Int64? in
        if case .groupResolved(let group, _) = action { group.id } else { nil }
    }
    #expect(resolved == [5])
    #expect(await transport.requests.filter { $0.method == "POST" }.isEmpty)
    #expect(await transport.requests.contains { $0.url.query?.contains("page=2") == true })
}

@Test func serviceCannotClaimDoneBeforeRegistration() async throws {
    // R2-F5: setup without registration fails. No serviceReady, no plist,
    // no done phase from an unregistered install.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem))])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.setupService)
    #expect(lastFailure(harness.logger)?.step == "setupService")
    #expect(!registrationActions(harness.logger).contains { if case .serviceReady = $0 { true } else { false } })
    #expect(!FileManager.default.fileExists(atPath: harness.installRoot.appendingPathComponent("macbook-test/manual-service.plist").path))
}

@Test func serviceRefusesMismatchedLocalRegistration() async throws {
    // R2-F5: a configured marker for another registration's `.runner` (wrong
    // name) refuses service setup instead of completing the wrong identity.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem))])
    let harness = await registrationHarness(
        transport: transport,
        downloader: fixtureDownloader(package.bytes),
        executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let draft = orgDraft()
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(draft))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    let directory = await harness.installer.directory(for: draft.installDirName)
    try await harness.installer.markCompleted(
        RunnerInstallerService.stepConfigured, directory: directory, scopeKey: draft.scope.scopeKey
    )
    try Data(#"{"agentId":4242,"agentName":"someone-else","gitHubUrl":"https://github.com/acme","workFolder":"_work"}"#.utf8)
        .write(to: directory.appendingPathComponent(".runner"))
    _ = await harness.flow.apply(RunnerRegistration.Effect.setupService)
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "setupService")
    #expect(failure?.message.contains("someone-else") ?? false)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("manual-service.plist").path))
}

@Test func verifiedLocalAgentIDRefusesEachMismatchClass() {
    // Pure-gate pin for R2-F2/R2-F5 plus R3-F2/R3-F3: every unverified
    // member fails, the matching member binds.
    let draft = orgDraft()
    let matching = RunnerRegistration.LocalRegistration(
        agentID: 4242, agentName: "macbook-test",
        gitHubURL: "https://github.com/acme", workFolder: "_work"
    )
    let verified = try? RunnerRegistration.Gates.verifiedLocalAgentID(
        local: matching, configured: true, draft: draft, serverHost: "github.com"
    )
    #expect(verified == 4242)
    let cases: [(RunnerRegistration.LocalRegistration?, Bool, String)] = [
        (nil, true, "missing file"),
        (RunnerRegistration.LocalRegistration(agentID: nil, agentName: "macbook-test", gitHubURL: "https://github.com/acme", workFolder: "_work"), true, "missing agentID"),
        (RunnerRegistration.LocalRegistration(agentID: 4242, agentName: "someone-else", gitHubURL: "https://github.com/acme", workFolder: "_work"), true, "wrong name"),
        (RunnerRegistration.LocalRegistration(agentID: 4242, agentName: "macbook-test", gitHubURL: "https://github.com/other/repo", workFolder: "_work"), true, "wrong scope"),
        (RunnerRegistration.LocalRegistration(agentID: 4242, agentName: "macbook-test", gitHubURL: "https://enterprise.example/acme", workFolder: "_work"), true, "foreign server same path"),
        (RunnerRegistration.LocalRegistration(agentID: 4242, agentName: "macbook-test", gitHubURL: "https://github.com/acme", workFolder: "new_work"), true, "wrong work folder"),
        (RunnerRegistration.LocalRegistration(agentID: 4242, agentName: "macbook-test", gitHubURL: "https://github.com/acme", workFolder: nil), true, "missing work folder"),
        (matching, false, "unconfigured marker"),
    ]
    for (local, configured, label) in cases {
        do {
            _ = try RunnerRegistration.Gates.verifiedLocalAgentID(
                local: local, configured: configured, draft: draft, serverHost: "github.com"
            )
            Issue.record("verifiedLocalAgentID admitted \(label)")
        } catch let error as RunnerRegistration.RegistrationError {
            guard case .unverifiedRegistration = error else {
                Issue.record("wrong error for \(label): \(error)")
                continue
            }
        } catch {
            Issue.record("unexpected error for \(label): \(error)")
        }
    }
    #expect(RunnerRegistration.Gates.scopeMatches(address: "https://github.com/ACME/", scope: .organization(org: "acme"), serverHost: "github.com"))
    #expect(!RunnerRegistration.Gates.scopeMatches(address: "https://github.com/acme/app", scope: .organization(org: "acme"), serverHost: "github.com"))
    #expect(RunnerRegistration.Gates.scopeMatches(address: "https://ghe.example.com/octo/app", scope: .repository(owner: "octo", name: "app"), serverHost: "ghe.example.com"))
    #expect(!RunnerRegistration.Gates.scopeMatches(address: "http://github.com/acme", scope: .organization(org: "acme"), serverHost: "github.com"))
    #expect(!RunnerRegistration.Gates.scopeMatches(address: "https://enterprise.example/acme", scope: .organization(org: "acme"), serverHost: "github.com"))
    #expect(RunnerRegistration.Gates.scopeMatches(address: "https://github.com/acme", scope: .organization(org: "acme"), serverHost: "www.github.com"))
}

@Test func boundRemoteRunnerIDBindsByID() {
    // Pure-gate pin for R2-F2: ID binding with fail-closed mismatch/absence.
    let runners = [
        RunnerRegistration.RegisteredRunner(id: 4242, name: "macbook-test", labels: []),
        RunnerRegistration.RegisteredRunner(id: 77, name: "other-runner", labels: []),
    ]
    do {
        let bound = try RunnerRegistration.Gates.boundRemoteRunnerID(
            localAgentID: 4242, name: "macbook-test", runners: runners
        )
        #expect(bound == 4242)
        let missing = try RunnerRegistration.Gates.boundRemoteRunnerID(
            localAgentID: 9999, name: "ghost-runner", runners: runners
        )
        #expect(missing == nil)
    } catch {
        Issue.record("unexpected error for exact/absent binding: \(error)")
    }
    do {
        _ = try RunnerRegistration.Gates.boundRemoteRunnerID(
            localAgentID: 9999, name: "other-runner",
            runners: [RunnerRegistration.RegisteredRunner(id: 77, name: "other-runner", labels: [])]
        )
        Issue.record("boundRemoteRunnerID adopted a same-name foreign runner")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .remoteIdentityMismatch = error else {
            Issue.record("wrong error for foreign name match: \(error)")
            return
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    do {
        _ = try RunnerRegistration.Gates.boundRemoteRunnerID(
            localAgentID: 4242, name: "renamed",
            runners: [RunnerRegistration.RegisteredRunner(id: 4242, name: "macbook-test", labels: [])]
        )
        Issue.record("boundRemoteRunnerID admitted a renamed local agent")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .remoteIdentityMismatch = error else {
            Issue.record("wrong error for renamed agent: \(error)")
            return
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - R3 regressions (adopted reviewer attacks, verbatim production entry)

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

// MARK: - R4: coherent operation identity (in-flight, server, configuration)

// Latch executor: suspends the next config.sh so a draft edit can land
// while registration is in flight through the production Flow entry point.
private actor ConfigLatchExecutor: CommandExecuting {
    private(set) var configCalls: [[String]] = []
    private let gitHubURL: String
    private let failure: CommandResult?
    private let real = CommandExecutor()
    private var latched = false
    var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(gitHubURL: String = "https://github.com/acme", failure: CommandResult? = nil) {
        self.gitHubURL = gitHubURL; self.failure = failure
    }
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        if executable.hasSuffix("config.sh") {
            configCalls.append(arguments)
            if !latched {
                latched = true
                started = true
                waiter?.resume(); waiter = nil
                await withCheckedContinuation { releaseWaiter = $0 }
            }
            if let failure { return failure }
            let dir = URL(fileURLWithPath: executable).deletingLastPathComponent()
            var name = "unnamed"
            var work = "_work"
            var index = arguments.startIndex
            while index < arguments.endIndex {
                if arguments[index] == "--name", arguments.index(after: index) < arguments.endIndex {
                    name = arguments[arguments.index(after: index)]
                }
                if arguments[index] == "--work", arguments.index(after: index) < arguments.endIndex {
                    work = arguments[arguments.index(after: index)]
                }
                index = arguments.index(after: index)
            }
            let payload = ["agentId": 4242, "agentName": name, "gitHubUrl": gitHubURL, "workFolder": work] as [String: Any]
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: dir.appendingPathComponent(".runner"), options: .atomic)
            return CommandResult(code: 0, output: "Configured")
        }
        return try await real.run(executable, arguments)
    }
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

// Latch transport: suspends the matching request whose path contains the
// needle (after skipping `skip` prior matches of the same method), so a
// draft or session edit can land while a GitHub step is in flight. The
// method filter keeps token POSTs from consuming list-GET skip budget.
private actor LatchTransport: GitHubHTTPTransport {
    private let inner: TestTransport
    private let needle: String
    private let method: String?
    private let skip: Int
    private var seen = 0
    private var latched = false
    var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(inner: TestTransport, needle: String, method: String? = nil, skip: Int = 0) {
        self.inner = inner; self.needle = needle; self.method = method; self.skip = skip
    }
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        if !latched, request.url.path.contains(needle), method == nil || request.method == method {
            if seen >= skip {
                latched = true
                started = true
                waiter?.resume(); waiter = nil
                await withCheckedContinuation { releaseWaiter = $0 }
            } else {
                seen += 1
            }
        }
        return try await inner.send(request)
    }
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private func latchedHarness(
    inner: TestTransport, needle: String, method: String? = nil, skip: Int = 0,
    downloader: (@Sendable (URL) async throws -> Data)? = nil,
    executor: (any CommandExecuting)? = nil
) async -> (RegistrationHarness, LatchTransport) {
    let logger = Relux.Testing.Logger()
    let dispatcher = Relux.Dispatcher(logger: logger)
    let latch = LatchTransport(inner: inner, needle: needle, method: method, skip: skip)
    let userStore = GitHubKeychainStore(backend: InMemoryKeychainBackend())
    let identities = InMemoryGitHubSessionIdentityStore()
    await identities.save(GitHubSessionIdentity(serverHost: "github.com", userID: 42, clientID: testConfig.clientID, username: "octo"))
    try? await userStore.save(
        GitHubAuth.TokenRecord(accessToken: "user-token-42", refreshToken: "refresh-42", expiresAt: Date().addingTimeInterval(3600)),
        serverHost: "github.com", userID: 42, clientID: testConfig.clientID
    )
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("RegHome-" + UUID().uuidString)
    let installRoot = home.appendingPathComponent("Library/GitHubActions")
    try? FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
    let installer = RunnerInstallerService(
        installRoot: installRoot, downloader: downloader, executor: executor, currentArch: { "arm64" }
    )
    let api = GitHubRunnerAPIClient(transport: latch)
    let registrationTokens = RunnerRegistrationTokenStore(backend: InMemoryRegistrationTokenBackend())
    let refresher = GitHubTokenRefresh(transport: latch, store: userStore)
    let flow = await RunnerRegistration.Flow(
        api: api, installer: installer, registrationTokens: registrationTokens,
        userStore: userStore, identityStore: identities, refresher: refresher,
        configProvider: { _ in testConfig }, dispatcher: dispatcher
    )
    let harness = RegistrationHarness(
        flow: flow, logger: logger, transport: inner, userStore: userStore,
        identities: identities, registrationTokens: registrationTokens,
        installer: installer, home: home, installRoot: installRoot
    )
    return (harness, latch)
}

@Test @MainActor func inFlightRegistrationCannotAttributeOldConfigToNewDraft() async throws {
    // R3-F1 class at the registration boundary: config suspends, the draft
    // renames, the old config's success must not become the new draft's.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = ConfigLatchExecutor()
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-R4", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
    ])
    let harness = await registrationHarness(
        transport: transport, downloader: fixtureDownloader(package.bytes), executor: executor
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    let operation = Task { await harness.flow.apply(RunnerRegistration.Effect.registerRunner) }
    await executor.waitStarted()
    var renamed = orgDraft()
    renamed.runnerName = "renamed-runner"
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(renamed))
    await executor.release()
    _ = await operation.value
    let state = RunnerRegistration.State()
    for item in registrationActions(harness.logger) { await state.reduce(with: item) }
    #expect(state.draft?.runnerName == "renamed-runner")
    #expect(state.runnerID == nil)
    #expect(!state.completedSteps.contains("registerRunner"))
    #expect(!registrationActions(harness.logger).contains { if case .registered = $0 { true } else { false } })
}

@Test @MainActor func inFlightGroupCannotResolveForEditedDraft() async throws {
    // R3-F1 class at the group boundary: the groups list suspends, the
    // draft re-targets another group, the old resolution must not land.
    let inner = TestTransport([
        groupsListPayload([groupPayload(id: 1, name: "Default", visibility: "all", allowsPublic: true)]),
        jsonResponse(groupPayload(id: 7, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true), status: 201),
        jsonResponse(["repositories": [["id": 9]]]),
    ])
    let (harness, latch) = await latchedHarness(inner: inner, needle: "runner-groups")
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    let operation = Task { await harness.flow.apply(RunnerRegistration.Effect.resolveGroup) }
    await latch.waitStarted()
    var edited = orgDraft()
    edited.groupName = "Other-Mac"
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
    await latch.release()
    _ = await operation.value
    let state = RunnerRegistration.State()
    for item in registrationActions(harness.logger) { await state.reduce(with: item) }
    #expect(state.draft?.groupName == "Other-Mac")
    #expect(state.group == nil)
    #expect(!state.completedSteps.contains("resolveGroup"))
}

@Test @MainActor func inFlightLabelsCannotWriteForEditedDraft() async throws {
    // R3-F1 class at the labels boundary: the labels runners-list fetch
    // suspends (downloads plus the two registration fetches pass through),
    // the draft renames, and the stale write is dropped before any PUT.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let inner = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-R4L", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        jsonResponse(["labels": [["name": "gpu"]]]),
    ])
    let (harness, latch) = await latchedHarness(
        inner: inner, needle: "/actions/runners", method: "GET", skip: 3,
        downloader: fixtureDownloader(package.bytes), executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let operation = Task { await harness.flow.apply(RunnerRegistration.Effect.applyLabels(["gpu"])) }
    await latch.waitStarted()
    var renamed = orgDraft()
    renamed.runnerName = "renamed-runner"
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(renamed))
    await latch.release()
    _ = await operation.value
    let state = RunnerRegistration.State()
    for item in registrationActions(harness.logger) { await state.reduce(with: item) }
    #expect(state.draft?.runnerName == "renamed-runner")
    #expect(await inner.requests.filter { $0.method == "PUT" }.isEmpty)
    #expect(!registrationActions(harness.logger).contains { if case .labelsApplied = $0 { true } else { false } })
}

@Test @MainActor func nonIdentityEditDuringInstallDoesNotCancel() async throws {
    // Editable selections never abandon in-flight work: a labels edit while
    // downloading still completes the install for the visible draft.
    let package = try await FixturePackage.make()
    let latch = ReviewDownloadLatch()
    let transport = TestTransport([downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem))])
    let harness = await registrationHarness(transport: transport, downloader: { _ in await latch.download(package.bytes) })
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    let operation = Task { await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall) }
    await latch.waitStarted()
    var edited = orgDraft()
    edited.labels = ["self-hosted", "macOS", "gpu"]
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
    await latch.release()
    _ = await operation.value
    let state = RunnerRegistration.State()
    for item in registrationActions(harness.logger) { await state.reduce(with: item) }
    #expect(state.draft?.labels.contains("gpu") == true)
    #expect(state.installPath != nil)
    #expect(state.completedSteps.contains("downloadAndInstall"))
}

@Test func serverChangeBetweenStepsInvalidatesGroupAndRunner() async throws {
    // R3-F2 session class: after resolving on github.com, the session moves
    // to another server. Cached group/runner progress must not authorize
    // writes there; the step re-resolves instead of reusing.
    let transport = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
    ])
    let harness = await registrationHarness(transport: transport)
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    await harness.identities.save(GitHubSessionIdentity(serverHost: "enterprise.example", userID: 7, clientID: testConfig.clientID, username: "octo"))
    try? await harness.userStore.save(
        GitHubAuth.TokenRecord(accessToken: "enterprise-token", refreshToken: "refresh-e", expiresAt: Date().addingTimeInterval(3600)),
        serverHost: "enterprise.example", userID: 7, clientID: testConfig.clientID
    )
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [9, 10]))
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "applyRepositoryAccess")
    #expect(failure?.message.contains("Resolve the dedicated group first") ?? false)
    #expect(await transport.requests.filter { $0.method == "PUT" }.isEmpty)
}

@Test func groupOwnershipIsScopedToServer() async throws {
    // R3-F2 ownership class: the same org/name on another server is not
    // owned. www.github.com aliases github.com; enterprise does not.
    let harness = await registrationHarness(transport: TestTransport([]))
    defer { try? FileManager.default.removeItem(at: harness.home) }
    try await harness.installer.saveOwnedGroupID(serverHost: "github.com", org: "acme", name: "RunnerControl-Mac", groupID: 5)
    #expect(await harness.installer.loadOwnedGroupID(serverHost: "github.com", org: "acme", name: "RunnerControl-Mac") == 5)
    #expect(await harness.installer.loadOwnedGroupID(serverHost: "www.github.com", org: "acme", name: "RunnerControl-Mac") == 5)
    #expect(await harness.installer.loadOwnedGroupID(serverHost: "enterprise.example", org: "acme", name: "RunnerControl-Mac") == nil)
    #expect(await harness.installer.loadOwnedGroupID(serverHost: "github.com", org: "acme", name: "Other-Mac") == nil)
}

@Test func enterpriseGroupDoesNotReuseGithubOwnership() async throws {
    // Flow entry: github.com ownership never adopts an enterprise group with
    // the same name. Without explicit takeover the enterprise resolve refuses.
    let harness = await registrationHarness(transport: TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
    ]))
    defer { try? FileManager.default.removeItem(at: harness.home) }
    try await harness.installer.saveOwnedGroupID(serverHost: "github.com", org: "acme", name: "RunnerControl-Mac", groupID: 5)
    await harness.identities.save(GitHubSessionIdentity(serverHost: "enterprise.example", userID: 7, clientID: testConfig.clientID, username: "octo"))
    try? await harness.userStore.save(
        GitHubAuth.TokenRecord(accessToken: "enterprise-token", refreshToken: "refresh-e", expiresAt: Date().addingTimeInterval(3600)),
        serverHost: "enterprise.example", userID: 7, clientID: testConfig.clientID
    )
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "resolveGroup")
    #expect(failure?.message.contains("already exists") ?? false)
    #expect(await harness.transport.requests.filter { $0.method != "GET" }.isEmpty)
}

@Test func groupChangeRefusesOldConfiguredSuccess() async throws {
    // R3-F3 configuration class: `.runner` does not record the group, so the
    // marker does. A group edit never claims the old group's config.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-G", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
    ])
    let harness = await registrationHarness(
        transport: transport, downloader: fixtureDownloader(package.bytes), executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    var edited = orgDraft()
    edited.groupName = "Other-Mac"
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
    let before = registrationActions(harness.logger).count
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let after = Array(registrationActions(harness.logger).dropFirst(before))
    #expect(!after.contains { if case .registered = $0 { true } else { false } })
    #expect(lastFailure(harness.logger)?.step == "registerRunner")
    #expect(lastFailure(harness.logger)?.message.contains("Other-Mac") ?? false)
}

@Test func runConfigRefusesWorkFolderMismatchOnResume() async throws {
    // Direct installer pin: the configured-marker resume verifies work
    // folder instead of returning the stale agent ID.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let harness = await registrationHarness(
        transport: TestTransport([]), downloader: fixtureDownloader(package.bytes), executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    let draft = orgDraft()
    let asset = RunnerRegistration.DownloadAsset(
        osName: "osx", architecture: "arm64",
        downloadURL: URL(string: "https://example.com/x.tar.gz")!,
        filename: "x.tar.gz", sha256Checksum: package.sha256ViaSystem
    )
    let directory = try await harness.installer.downloadAndInstall(asset: asset, draft: draft)
    _ = try await harness.installer.runConfig(
        directory: directory, scopeURL: "https://github.com/acme",
        token: "TOKEN", draft: draft, runnerGroup: "RunnerControl-Mac"
    )
    var changed = draft
    changed.workFolder = "new_work"
    do {
        _ = try await harness.installer.runConfig(
            directory: directory, scopeURL: "https://github.com/acme",
            token: "TOKEN2", draft: changed, runnerGroup: "RunnerControl-Mac"
        )
        Issue.record("runConfig admitted a work-folder mismatch on resume")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .unverifiedRegistration(let text) = error else {
            Issue.record("wrong error for work-folder resume: \(error)")
            return
        }
        #expect(text.contains("new_work"))
    }
}

@Test @MainActor func inFlightLabelsAbandonedWhenLabelsEdited() async throws {
    // Directive class: labels stay editable, but a labels edit abandons the
    // in-flight applyLabels so the older completion can never overwrite the
    // newer visible selection. Re-applying then applies the new values.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let inner = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-SECRET-R4S", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
        jsonResponse(["labels": [["name": "gpu"], ["name": "fast"]]]),
    ])
    let (harness, latch) = await latchedHarness(
        inner: inner, needle: "/actions/runners", method: "GET", skip: 3,
        downloader: fixtureDownloader(package.bytes), executor: SplitExecutor()
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    let operation = Task { await harness.flow.apply(RunnerRegistration.Effect.applyLabels(["gpu"])) }
    await latch.waitStarted()
    var edited = orgDraft()
    edited.labels = ["gpu", "fast"]
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
    await latch.release()
    _ = await operation.value
    #expect(await inner.requests.filter { $0.method == "PUT" }.isEmpty)
    #expect(!registrationActions(harness.logger).contains { if case .labelsApplied = $0 { true } else { false } })
    let mid = RunnerRegistration.State()
    for item in registrationActions(harness.logger) { await mid.reduce(with: item) }
    #expect(mid.draft?.labels == ["gpu", "fast"])
    // Recovery: applying the visible values now PUTs exactly those.
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyLabels(["gpu", "fast"]))
    let puts = await inner.requests.filter { $0.method == "PUT" }
    #expect(puts.count == 1)
    #expect(puts.first?.url.path.contains("/orgs/acme/actions/runners/4242/labels") ?? false)
    #expect(registrationActions(harness.logger).contains {
        if case .labelsApplied(let labels) = $0, labels == ["gpu", "fast"] { true } else { false }
    })
}

@Test @MainActor func inFlightAccessAbandonedWhenRepositoriesEdited() async throws {
    // Directive class: repository selection stays editable, but an edit
    // abandons the in-flight apply so the older write can never be reported
    // as the newer selection applied. The newer selection survives for retry.
    let inner = TestTransport([
        groupsListPayload([groupPayload(id: 5, name: "RunnerControl-Mac", visibility: "selected", allowsPublic: true)]),
        jsonResponse(["repositories": [["id": 9]]]),
        GitHubHTTPResponse(status: 204, body: Data()),
        GitHubHTTPResponse(status: 204, body: Data()),
        jsonResponse(["repositories": [["id": 9], ["id": 10]]]),
    ])
    let (harness, latch) = await latchedHarness(inner: inner, needle: "repositories", method: "PUT", skip: 0)
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft(allowTakeover: true)))
    _ = await harness.flow.apply(RunnerRegistration.Effect.resolveGroup)
    let operation = Task {
        await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [9]))
    }
    await latch.waitStarted()
    var edited = orgDraft(allowTakeover: true)
    edited.selectedRepositoryIDs = [9, 10]
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(edited))
    await latch.release()
    _ = await operation.value
    #expect(!registrationActions(harness.logger).contains {
        if case .repositoryAccessApplied = $0 { true } else { false }
    })
    let mid = RunnerRegistration.State()
    for item in registrationActions(harness.logger) { await mid.reduce(with: item) }
    #expect(mid.draft?.selectedRepositoryIDs == [9, 10])
    // Recovery: applying the visible selection confirms exactly those IDs.
    _ = await harness.flow.apply(RunnerRegistration.Effect.applyRepositoryAccess(groupID: 5, repositories: [9, 10]))
    #expect(registrationActions(harness.logger).contains {
        if case .repositoryAccessApplied(let ids) = $0, Set(ids) == [9, 10] { true } else { false }
    })
}

@Test func operationIdentityNormalizationAndChangeDetection() {
    // Pure pin: server aliasing and the identity/editable split that drives
    // generation invalidation.
    #expect(RunnerRegistration.OperationIdentity.normalizeServerHost("www.github.com") == "github.com")
    #expect(RunnerRegistration.OperationIdentity.normalizeServerHost("GitHub.com") == "github.com")
    #expect(RunnerRegistration.OperationIdentity.normalizeServerHost("enterprise.example") == "enterprise.example")
    let base = orgDraft()
    var changed = base
    changed.labels = ["self-hosted", "macOS", "gpu"]
    #expect(!RunnerRegistration.Gates.identityFieldsChanged(old: base, new: changed))
    changed = base
    changed.selectedRepositoryIDs = [9, 10]
    #expect(!RunnerRegistration.Gates.identityFieldsChanged(old: base, new: changed))
    changed = base
    changed.allowReplace = true
    #expect(!RunnerRegistration.Gates.identityFieldsChanged(old: base, new: changed))
    changed = base
    changed.runnerName = "other"
    #expect(RunnerRegistration.Gates.identityFieldsChanged(old: base, new: changed))
    changed = base
    changed.installDirName = "other-dir"
    #expect(RunnerRegistration.Gates.identityFieldsChanged(old: base, new: changed))
    changed = base
    changed.workFolder = "new_work"
    #expect(RunnerRegistration.Gates.identityFieldsChanged(old: base, new: changed))
    changed = base
    changed.groupName = "Other-Mac"
    #expect(RunnerRegistration.Gates.identityFieldsChanged(old: base, new: changed))
    changed = base
    changed.scope = .repository(owner: "octo", name: "app")
    #expect(RunnerRegistration.Gates.identityFieldsChanged(old: base, new: changed))
    let repoBase = repoDraft()
    var repoChanged = repoBase
    repoChanged.groupName = "Ignored-For-Repo"
    #expect(!RunnerRegistration.Gates.identityFieldsChanged(old: repoBase, new: repoChanged))
}

// MARK: - R5: operation owner + directory lease (verbatim reviewer R4 attacks)

// Adopted verbatim from TASK-260916-13diw4_review-attacks-rev4.swift: the two
// R4 findings (repeat-of R3-F1) as committed named regressions through the
// production Flow entry point.

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

@Test @MainActor func reviewerStaleFailureCannotUnlockNewOperation() async throws {
    // R4-F2 regression, R8 serialization shape: the new generation's
    // download is refused installer-busy while the old owns the installer.
    // When the old then fails, its stale exit mutates nothing — the new
    // generation's busy failure stands (nothing cleared, nothing planted) —
    // and retry after settle installs the new directory.
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
    _ = await h.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    #expect(lastFailure(h.logger)?.step == "downloadAndInstall")
    #expect(lastFailure(h.logger)?.message.contains("busy") ?? false)
    await latch.release(1)
    _ = await old.value
    let failures = registrationActions(h.logger).filter {
        if case .failed = $0 { true } else { false }
    }
    #expect(failures.count == 1, "Stale old failure must plant nothing and clear nothing")
    #expect(lastFailure(h.logger)?.message.contains("busy") ?? false)
    // The retry's download is the latch's second call (which succeeds);
    // choreograph its release like the original two-download shape.
    let retried = Task { await h.flow.apply(RunnerRegistration.Effect.retry) }
    await latch.waitStarted(2)
    await latch.release(2)
    _ = await retried.value
    let state = RunnerRegistration.State()
    for item in registrationActions(h.logger) { await state.reduce(with: item) }
    #expect(state.installPath?.hasSuffix("new-install") ?? false)
    #expect(state.completedSteps.contains("downloadAndInstall"))
    #expect(state.failedStep == nil)
}

// MARK: - R5: lifecycle ownership across begin/update/cancel/reset

// Latch downloader: suspends the FIRST download so an abandoning edit can
// land while an install is in flight; later downloads pass through. Counts
// every call so tests prove a refused retry started no second download.
private actor CountingLatchDownloader {
    private let bytes: Data
    private(set) var calls = 0
    private var latched = false
    var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(bytes: Data) { self.bytes = bytes }
    func download(_ url: URL) async throws -> Data {
        calls += 1
        if !latched {
            latched = true
            started = true
            waiter?.resume(); waiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return bytes
    }
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@Test @MainActor func beginDraftDuringDownloadKeepsDirectoryLease() async throws {
    // R5/R4-F1 at the beginDraft boundary: a new draft for the SAME directory
    // releases the UI lock but never the live install's installer-wide lease.
    // A retry while the first install runs is refused retryably (no second
    // download); after the first settles stale, retry reuses it.
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
    await downloads.waitStarted()
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
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

@Test @MainActor func resetDuringDownloadKeepsDirectoryLeaseUntilSettled() async throws {
    // R5/R4-F1 at the reset boundary: reset releases the UI lock at once,
    // but the live install keeps the installer-wide lease until it settles.
    // An install for the fresh draft is refused while live and reuses the
    // settled install on retry.
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
    await downloads.waitStarted()
    _ = await harness.flow.apply(RunnerRegistration.Effect.reset)
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    #expect(await downloads.calls == 1, "Second download must not start while the reset-abandoned install is live")
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

@Test @MainActor func cancelDuringConfigKeepsLeaseAndRecoversAfterSettle() async throws {
    // R5/R4-F1 at the cancel boundary: cancel releases the UI lock at once,
    // but the live config.sh keeps the installer-wide lease. A register
    // while it runs starts no second config (busy, token deleted); after it
    // settles stale, retry resumes the verified registration.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = ConfigLatchExecutor()
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-OLD", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([]),
        jsonResponse(["token": "REG-BUSY", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
        runnersListPayload([["id": 4242, "name": "macbook-test", "labels": []]]),
    ])
    let harness = await registrationHarness(
        transport: transport, downloader: fixtureDownloader(package.bytes), executor: executor
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    let old = Task { await harness.flow.apply(RunnerRegistration.Effect.registerRunner) }
    await executor.waitStarted()
    _ = await harness.flow.apply(RunnerRegistration.Effect.cancel)
    _ = await harness.flow.apply(RunnerRegistration.Effect.registerRunner)
    #expect(await executor.configCalls.count == 1, "Second config.sh must not run while the cancelled config still owns this directory")
    #expect(lastFailure(harness.logger)?.step == "registerRunner")
    #expect(lastFailure(harness.logger)?.message.contains("busy") ?? false)
    await executor.release()
    _ = await old.value
    _ = await harness.flow.apply(RunnerRegistration.Effect.retry)
    let actions = registrationActions(harness.logger)
    #expect(actions.contains {
        if case .registered(let runnerID, let localAgentID) = $0 {
            runnerID == 4242 && localAgentID == 4242
        } else { false }
    })
    let state = RunnerRegistration.State()
    for item in actions { await state.reduce(with: item) }
    #expect(state.completedSteps.contains("registerRunner"))
    let scopeKey = RunnerRegistration.Flow.tokenScopeKey(draft: orgDraft())
    #expect(await harness.registrationTokens.load(scopeKey: scopeKey) == nil, "Both minted tokens are deleted")
}

@Test @MainActor func secondInstallForAnyDirectoryRefusedWhileInstallerBusy() async throws {
    // R8: ONE active installer mutation per app instance. While an install
    // for dirA is live (then abandoned), an install for a DIFFERENT
    // physical directory is refused as installer-busy — no second download
    // starts. After the first settles, retry starts the new directory's own
    // install. Supersedes the R5 per-directory concurrency expectation.
    let package = try await FixturePackage.make()
    let downloads = CountingLatchDownloader(bytes: package.bytes)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
    ])
    let harness = await registrationHarness(
        transport: transport, downloader: { url in try await downloads.download(url) }
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    let old = Task { await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall) }
    await downloads.waitStarted()
    var moved = orgDraft()
    moved.installDirName = "new-install"
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(moved))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    #expect(await downloads.calls == 1, "Second install for any directory must be refused while the installer is busy")
    #expect(lastFailure(harness.logger)?.step == "downloadAndInstall")
    #expect(lastFailure(harness.logger)?.message.contains("busy") ?? false)
    await downloads.release()
    _ = await old.value
    _ = await harness.flow.apply(RunnerRegistration.Effect.retry)
    #expect(await downloads.calls == 2, "Retry after settle starts the new directory's own install")
    let state = RunnerRegistration.State()
    for item in registrationActions(harness.logger) { await state.reduce(with: item) }
    #expect(state.installPath?.hasSuffix("new-install") ?? false)
    #expect(state.completedSteps.contains("downloadAndInstall"))
    let installed = registrationActions(harness.logger).filter {
        if case .installed = $0 { true } else { false }
    }
    #expect(installed.count == 1, "Abandoned install must not attest a second path")
}

@Test @MainActor func staleRegisterFailureDoesNotOverwriteBusyFailure() async throws {
    // R5/R4-F2 for the register step, R8 serialization shape: while a
    // config.sh is live, the moved draft's install is refused
    // installer-busy. When the old config then fails, its stale exit
    // records nothing: the busy refusal stands and retry after settle
    // installs the new directory. Supersedes the R5 concurrent-install
    // expectation of staleRegisterFailureDoesNotUnlockOrPlantFailure.
    let package = try await FixturePackage.make(withRealConfigScript: false)
    let executor = ConfigLatchExecutor(failure: CommandResult(code: 1, output: "config exploded"))
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
        runnersListPayload([]),
        jsonResponse(["token": "REG-OLD", "expires_at": "2030-01-01T00:00:00Z"], status: 201),
    ])
    let harness = await registrationHarness(
        transport: transport, downloader: fixtureDownloader(package.bytes), executor: executor
    )
    defer { try? FileManager.default.removeItem(at: harness.home) }
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(orgDraft()))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    let old = Task { await harness.flow.apply(RunnerRegistration.Effect.registerRunner) }
    await executor.waitStarted()
    var moved = orgDraft()
    moved.installDirName = "new-install"
    _ = await harness.flow.apply(RunnerRegistration.Effect.updateDraft(moved))
    _ = await harness.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    #expect(lastFailure(harness.logger)?.step == "downloadAndInstall")
    #expect(lastFailure(harness.logger)?.message.contains("busy") ?? false)
    await executor.release()
    _ = await old.value
    let failures = registrationActions(harness.logger).filter {
        if case .failed = $0 { true } else { false }
    }
    #expect(failures.count == 1, "Stale register failure must plant nothing and clear nothing")
    _ = await harness.flow.apply(RunnerRegistration.Effect.retry)
    let state = RunnerRegistration.State()
    for item in registrationActions(harness.logger) { await state.reduce(with: item) }
    #expect(state.installPath?.hasSuffix("new-install") ?? false)
    #expect(state.completedSteps.contains("downloadAndInstall"))
    #expect(state.failedStep == nil)
}

// MARK: - R6: canonical directory lease (repeat-of R4-F1 / R5-F1)

/// Bounded latch wait: polls the config latch's started flag so a config.sh
/// that never starts (for example a gate error thrown before the latch)
/// becomes a reported failure carrying the Flow diagnostics instead of an
/// infinite hang. The timeout is generous — latches normally fire in well
/// under a second — and the regression assertions below are unchanged.
private func waitForConfigStart(_ executor: ConfigLatchExecutor, timeoutSeconds: Double) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while true {
        if await executor.started { return true }
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

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
    // Gate errors before the latch must fail fast with diagnostics, never
    // hang in the wait below: without an install the register step cannot
    // reach config.sh.
    if let setupFailure = lastFailure(h.logger) {
        #expect(
            Bool(false),
            "Setup failed before the config latch: [\(setupFailure.step)] \(setupFailure.message)"
        )
        return
    }
    let old = Task { await h.flow.apply(RunnerRegistration.Effect.registerRunner) }
    guard await waitForConfigStart(executor, timeoutSeconds: 30) else {
        let detail = lastFailure(h.logger).map { "[\($0.step)] \($0.message)" } ?? "no Flow failure recorded"
        #expect(Bool(false), "config.sh never started within 30s; Flow failure: \(detail)")
        await executor.release()
        _ = await old.value
        return
    }
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

// R8: the R6 ancestor lease-key unit test is removed with the per-path
// lease identity it covered. Symlink-alias concurrency is still proven
// through the production Flow by reviewerSymlinkAliasCannotBypassDirectoryLease.

private actor DownloadCounter {
    private let bytes: Data
    private(set) var calls = 0
    init(bytes: Data) { self.bytes = bytes }
    func download(_ url: URL) async throws -> Data {
        calls += 1
        return bytes
    }
}

// MARK: - R7: missing-leaf case-equivalence (repeat-of R5-F1 / R6-F1)

@Test @MainActor func reviewerCaseAliasMissingLeafCannotBypassDirectoryLease() async throws {
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
    #expect(await downloads.calls == 1, "Second download must not start while the first owns this directory")
    #expect(lastFailure(harness.logger)?.step == "downloadAndInstall")
    #expect(lastFailure(harness.logger)?.message.contains("busy") ?? false)
    await downloads.release()
    _ = await old.value
    let lower = harness.installRoot.appendingPathComponent("macbook-test")
    let upper = harness.installRoot.appendingPathComponent("MACBOOK-TEST")
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

// R8: the R7 forced-sensitive concurrency control and the lease-key
// folding unit test are removed with the per-path lease identity they
// covered. Case-alias concurrency is still proven through the production
// Flow by reviewerCaseAliasMissingLeafCannotBypassDirectoryLease and
// reviewerUnicodeCaseAliasCannotBypassDirectoryLease; deliberate
// serialization of distinct directories by
// secondInstallForAnyDirectoryRefusedWhileInstallerBusy.

@Test @MainActor func finderAliasInstallFolderIsRefusedBeforeDownload() async throws {
    // R6 alias control: a Finder-alias install folder is refused before any
    // download side effect, through the production Flow entry point.
    let package = try await FixturePackage.make()
    let counter = DownloadCounter(bytes: package.bytes)
    let transport = TestTransport([
        downloadsArrayPayload(downloadAssets(checksum: package.sha256ViaSystem)),
    ])
    let h = await registrationHarness(
        transport: transport, downloader: { url in try await counter.download(url) }
    )
    defer { try? FileManager.default.removeItem(at: h.home) }
    let target = h.home.appendingPathComponent("real-target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let aliasURL = h.installRoot.appendingPathComponent("alias-dir")
    let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile)
    try URL.writeBookmarkData(bookmark, to: aliasURL)
    var draft = orgDraft()
    draft.installDirName = "alias-dir"
    _ = await h.flow.apply(RunnerRegistration.Effect.beginDraft(draft))
    _ = await h.flow.apply(RunnerRegistration.Effect.downloadAndInstall)
    #expect(await counter.calls == 0, "Alias path must be refused before any download side effect")
    let failure = lastFailure(h.logger)
    #expect(failure?.step == "downloadAndInstall")
    #expect(failure?.message.contains("alias") ?? false)
}

// MARK: - R7-F1 Unicode alias (repeat-of R6-F1), retained under R8

// Adopted verbatim from TASK-260916-13diw4_review-attack-rev7.swift: the
// runner-σ/runner-ς production-Flow regression. Under the R8
// installer-wide lease it passes without any path comparison: the second
// mutation is refused installer-busy for ANY directory while the first is
// live, so the Unicode equivalence class cannot bypass the gate.

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
