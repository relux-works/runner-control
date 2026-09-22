import ArgumentParser
import Foundation
import Testing
import RunnerControlCore
@testable import RunnerControlCLI

private func snapshot(id: String, title: String, localID: String? = nil) -> Runners.Snapshot {
    let definition = Runners.Definition(
        id: id, title: title, detail: "", directory: URL(fileURLWithPath: "/tmp/" + id),
        githubURL: URL(string: "https://github.com/example")!, localID: localID
    )
    return Runners.Snapshot(definition: definition, status: .stopped)
}

@Test func resolvesByServiceLabelFirst() throws {
    let rows = [snapshot(id: "actions.runner.a", title: "A"), snapshot(id: "actions.runner.b", title: "B")]
    #expect(try RunnerMatching.resolve("actions.runner.b", in: rows).id == "actions.runner.b")
}

@Test func resolvesByLocalIDAndName() throws {
    let rows = [snapshot(id: "actions.runner.a", title: "Mac One", localID: "local-1")]
    #expect(try RunnerMatching.resolve("local-1", in: rows).id == "actions.runner.a")
    #expect(try RunnerMatching.resolve("Mac One", in: rows).id == "actions.runner.a")
    #expect(try RunnerMatching.resolve("MAC ONE", in: rows).id == "actions.runner.a")
}

@Test func ambiguousNameListsCandidates() {
    let rows = [snapshot(id: "actions.runner.a", title: "Mac"), snapshot(id: "actions.runner.b", title: "mac")]
    do {
        _ = try RunnerMatching.resolve("mac", in: rows)
        Issue.record("expected ambiguity failure")
    } catch let failure as CLIFailure {
        #expect(failure.message.contains("actions.runner.a"))
        #expect(failure.message.contains("actions.runner.b"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func unknownRunnerListsKnown() {
    let rows = [snapshot(id: "actions.runner.a", title: "A")]
    do {
        _ = try RunnerMatching.resolve("nope", in: rows)
        Issue.record("expected unknown failure")
    } catch let failure as CLIFailure {
        #expect(failure.message.contains("actions.runner.a"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func runnerDTOExposesStableKeys() throws {
    let dto = RunnerDTO(snapshot: snapshot(id: "actions.runner.a", title: "A", localID: "local-1"))
    let json = try Output.encode(dto)
    for key in ["\"id\"", "\"localID\"", "\"displayTitle\"", "\"directory\"", "\"status\"", "\"controller\"", "\"githubURL\""] {
        #expect(json.contains(key), "missing \(key)")
    }
    #expect(!json.contains("token"))
}

@Test func tableAlignsColumns() {
    let rendered = Output.table(rows: [("A", "1"), ("Longer", "2")])
    #expect(rendered == "A       1\nLonger  2")
}

@Test func hostAppURLFindsBundleAboveBinary() {
    let exe = "/Applications/RunnerControl.app/Contents/Helpers/runner-control"
    #expect(CLIConfig.hostAppURL(executablePath: exe)?.path == "/Applications/RunnerControl.app")
    #expect(CLIConfig.hostAppURL(executablePath: "/usr/local/bin/runner-control") == nil)
}

@Test func clientIDFallsBackToEmbeddedConstant() {
    #expect(CLIConfig.clientID(executablePath: "/usr/local/bin/runner-control") == CLIConfig.embeddedClientID)
}

@Test func configProviderBuildsServerHosts() throws {
    let provider = CLIConfig.configProvider(executablePath: "/usr/local/bin/runner-control")
    let github = try provider(nil)
    #expect(github.clientID == CLIConfig.embeddedClientID)
    #expect(github.apiBaseURL.absoluteString == "https://api.github.com")
    let enterprise = try provider("ghe.example.com")
    #expect(enterprise.apiBaseURL.absoluteString == "https://ghe.example.com/api/v3")
}

@Test func parsesAppcastVersion() {
    let xml = """
    <rss><channel><item><title>1.3.0</title>
    <sparkle:shortVersionString>1.3.0</sparkle:shortVersionString>
    </item></channel></rss>
    """
    #expect(AppSettings.parseShortVersion(from: Data(xml.utf8)) == "1.3.0")
    #expect(AppSettings.parseShortVersion(from: Data("<rss/>".utf8)) == nil)
}

@Test(arguments: [
    ("1.3.0", "1.2.0", true),
    ("1.2.0", "1.2.0", false),
    ("1.2.0", "1.3.0", false),
    ("1.10.0", "1.9.9", true),
    ("2.0", "1.99.99", true),
]) func comparesVersionsNumerically(candidate: String, current: String, expected: Bool) {
    #expect(AppSettings.isNewer(candidate, than: current) == expected)
}

@Test func registerDraftRequiresExactlyOneScope() throws {
    let missing = try RegisterCommand.parse([])
    #expect(throws: CLIFailure.self) { try missing.makeDraft() }
    let both = try RegisterCommand.parse(["--org", "acme", "--repo", "acme/app"])
    do {
        _ = try both.makeDraft()
        Issue.record("expected scope failure")
    } catch let failure as CLIFailure {
        #expect(failure.code == .usage)
    }
}

@Test func registerDraftRejectsMalformedRepo() throws {
    let command = try RegisterCommand.parse(["--repo", "not-a-scope"])
    do {
        _ = try command.makeDraft()
        Issue.record("expected repo-format failure")
    } catch let failure as CLIFailure {
        #expect(failure.code == .usage)
    }
}

@Test func registerDraftParsesValidFlags() throws {
    let command = try RegisterCommand.parse([
        "--repo", "acme/app", "--name", "builder", "--label", "a,b",
        "--dir", "builder-1", "--repo-id", "11,22", "--allow-replace",
    ])
    let draft = try command.makeDraft()
    #expect(draft.scope == .repository(owner: "acme", name: "app"))
    #expect(draft.runnerName == "builder")
    #expect(draft.labels == ["a", "b"])
    #expect(draft.installDirName == "builder-1")
    #expect(draft.selectedRepositoryIDs == [11, 22])
    #expect(draft.allowReplace == true)
    #expect(draft.allowGroupMutation == false)
}

@Test func idListParsing() throws {
    #expect(try Parse.idList("1, 2,,3", flag: "--x") == [1, 2, 3])
    #expect(try Parse.idList("", flag: "--x") == [])
    do {
        _ = try Parse.idList("1,nope", flag: "--x")
        Issue.record("expected usage failure")
    } catch let failure as CLIFailure {
        #expect(failure.code == .usage)
    }
}

@Test func defaultDirNameStaysValid() {
    #expect(RegisterCommand.defaultDirName(runnerName: "MacBook IV") == "macbook-iv")
    #expect(RegisterCommand.defaultDirName(runnerName: "a/b c") == "a-b-c")
    #expect(RegisterCommand.defaultDirName(runnerName: "///") == "---")
}

@Test func powerTargetsRejectsMixedSelection() {
    // Pure validation: --all with explicit refs is a usage error without
    // touching any runtime (only one headless boot per process is allowed).
    do {
        _ = try powerTargets(snapshots: [snapshot(id: "a", title: "A")], all: true, refs: ["x"])
        Issue.record("expected usage failure")
    } catch let failure as CLIFailure {
        #expect(failure.code == .usage)
    } catch {
        Issue.record("wrong error: \(error)")
    }
    do {
        _ = try powerTargets(snapshots: [], all: true, refs: [])
        Issue.record("expected empty-catalog failure")
    } catch let failure as CLIFailure {
        #expect(failure.code == .failed)
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test @MainActor func headlessBootRestoresDisconnected() async {
    // Hermetic: in-memory credential + identity stores, stub transport, stub
    // service. restoreSession short-circuits on the missing identity (no
    // network); discover only reads. The real catalog file is never written.
    let runtime = await HeadlessRuntime.boot(
        service: StubService(), transport: StubTransport(), store: InMemoryKeychainStore(),
        identities: InMemoryGitHubSessionIdentityStore(), configProvider: nil
    )
    await action { GitHubAuth.Effect.restoreSession }
    #expect(runtime.githubState.connection == .disconnected)
    await action { Runners.Effect.discover }
    #expect(runtime.state.catalogError == nil)
}

struct StubService: RunnerServicing {
    func snapshots() async -> [Runners.Snapshot] { [] }
    func setEnabled(_ enabled: Bool, id: String) async throws {}
}

struct InMemoryKeychainStore: GitHubCredentialStoring {
    let backend = InMemoryKeychainBackend()
    func save(_ record: GitHubAuth.TokenRecord, serverHost: String, userID: Int64, clientID: String) async throws {
        try backend.save(Data(), service: "t", account: "a")
    }
    func load(serverHost: String, userID: Int64, clientID: String) async -> GitHubAuth.TokenRecord? { nil }
    func delete(serverHost: String, userID: Int64, clientID: String) async {}
    func deleteAll(serverHost: String, clientID: String) async {}
}

struct StubTransport: GitHubHTTPTransport {
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        GitHubHTTPResponse(status: 500, headers: [:], body: Data())
    }
}

@Test func parseErrorsMapToUsageExceptHelp() {
    // Unknown flags, bad values, missing arguments: exit 1, never
    // ArgumentParser's 64. Help/version keep native handling.
    let usage = RunnerControl.mapParseError(CleanExit.message("Unknown option '--bogus'"))
    #expect(usage == .nativePassthrough)
    struct Boom: Error {}
    let mapped = RunnerControl.mapParseError(Boom())
    guard case .exit(let code, _) = mapped else {
        Issue.record("expected mapped exit"); return
    }
    #expect(code == .usage)
    #expect(RunnerControl.mapParseError(CleanExit.helpRequest()) == .nativePassthrough)
}

@Test func runErrorsKeepCLICodesAndFailOthers() {
    // CLIFailure codes pass through; any other operational error
    // (URLError, decoding, unexpected) is failed(2), never usage(1).
    let login = RunnerControl.mapRunError(CLIFailure(.needsLogin, "nope"))
    guard case .exit(let loginCode, let loginMessage) = login else {
        Issue.record("expected mapped exit"); return
    }
    #expect(loginCode == .needsLogin)
    #expect(loginMessage == "nope")
    let net = RunnerControl.mapRunError(URLError(.cannotConnectToHost))
    guard case .exit(let netCode, let netMessage) = net else {
        Issue.record("expected mapped exit"); return
    }
    #expect(netCode == .failed)
    #expect(!netMessage.isEmpty)
    #expect(RunnerControl.mapRunError(CleanExit.helpRequest()) == .nativePassthrough)
}

