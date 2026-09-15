import Foundation
import Testing
import Relux
@testable import RunnerControlCore

struct ForeignAction: Relux.Action {}
struct ForeignEffect: Relux.Effect {}

@Test @MainActor func reducerPreservesUnrelatedActionsAndCleansState() async {
    let state = Runners.State()
    let original = state.runners
    await state.reduce(with: ForeignAction())
    #expect(state.runners == original)
    await state.reduce(with: Runners.Action.changing(original[0].id, true))
    await state.reduce(with: Runners.Action.failed("Permission denied"))
    #expect(state.changing.contains(original[0].id))
    #expect(state.lastError == "Permission denied")
    await state.reduce(with: Runners.Action.refreshed(original.map { .init(definition: $0.definition, status: .running) }))
    #expect(state.activeCount == 2)
    await state.cleanup()
    #expect(state.activeCount == 0)
    #expect(state.changing.isEmpty)
    #expect(state.lastError == nil)
}

@Test(arguments: [
    (CommandResult(code: 0, output: "state = running\npid = 23"), Runners.Status.running),
    (CommandResult(code: 0, output: "state = exited"), .failed),
    (CommandResult(code: 113, output: "Could not find service foo"), .stopped),
    (CommandResult(code: 1, output: "Operation not permitted"), .unknown),
    (CommandResult(code: 113, output: "Could not find domain"), .unknown)
]) func distinguishesStoppedFromPermissionFailure(value: (CommandResult, Runners.Status)) {
    #expect(LaunchAgentService.status(from: value.0) == value.1)
}

actor FakeExecutor: CommandExecuting {
    private var results: [CommandResult]
    private(set) var calls: [[String]] = []
    init(_ results: [CommandResult]) { self.results = results }
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        calls.append([executable] + arguments)
        guard !results.isEmpty else { throw RunnerError.message("Unexpected command") }
        return results.removeFirst()
    }
}
struct Fixture {
    let root: URL
    let definition: Runners.Definition
    init(suffix: String = "", work: String = "_work") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RunnerControl-" + UUID().uuidString + suffix)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        definition = .init(id: "works.relux.runnercontrol.test." + UUID().uuidString, title: "Test", detail: "Fixture", directory: root, githubURL: URL(string: "https://example.com")!)
        let script = root.appendingPathComponent("runsvc.sh")
        try "#!/bin/sh\nexec /bin/sleep 120\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let plist: [String: Any] = ["Label": definition.id, "ProgramArguments": [script.path], "WorkingDirectory": root.path, "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: definition.plist)
        try JSONSerialization.data(withJSONObject: ["workFolder": work]).write(to: root.appendingPathComponent(".runner"))
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
let stopped = CommandResult(code: 113, output: "Could not find service test")
let running = CommandResult(code: 0, output: "state = running")

@Test func startIsIdempotentAndStopUsesServiceIdentity() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let executor = FakeExecutor([running, running, .init(code: 0, output: ""), stopped])
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor, userID: 501)
    try await service.setEnabled(true, id: fixture.definition.id)
    try await service.setEnabled(false, id: fixture.definition.id)
    let calls = await executor.calls
    #expect(calls.count == 4)
    #expect(calls[2] == ["/bin/launchctl", "bootout", "gui/501/" + fixture.definition.id])
}

@Test func startWaitsForRunningState() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let executor = FakeExecutor([stopped, .init(code: 0, output: ""), running])
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor, userID: 501)
    try await service.setEnabled(true, id: fixture.definition.id)
    let calls = await executor.calls
    #expect(calls[1] == ["/bin/launchctl", "bootstrap", "gui/501", fixture.definition.plist.path])
}

@Test(arguments: [false, true]) func rejectsSpacesBeforeLaunching(inWorkFolder: Bool) async throws {
    let fixture = try Fixture(suffix: inWorkFolder ? "" : " bad", work: inWorkFolder ? "bad path" : "_work")
    defer { fixture.clean() }
    let executor = FakeExecutor([])
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor)
    await #expect(throws: (any Error).self) { try await service.setEnabled(true, id: fixture.definition.id) }
    #expect(await executor.calls.isEmpty)
}

@Test func permissionErrorsNeverTriggerBootstrap() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let executor = FakeExecutor([.init(code: 1, output: "Operation not permitted")])
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor)
    await #expect(throws: (any Error).self) { try await service.setEnabled(true, id: fixture.definition.id) }
    #expect(await executor.calls.count == 1)
}

@Test func canStopAfterRegistrationIsDeleted() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".runner"))
    let executor = FakeExecutor([running, .init(code: 0, output: ""), stopped])
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor)
    try await service.setEnabled(false, id: fixture.definition.id)
    #expect(await executor.calls.count == 3)
}

actor FailingService: RunnerServicing {
    func snapshots() async -> [Runners.Snapshot] { [] }
    func setEnabled(_ enabled: Bool, id: String) async throws { throw RunnerError.message("Denied") }
}
@Test @MainActor func flowPublishesFailureAndClearsPendingState() async {
    let logger = Relux.Testing.Logger()
    let dispatcher = Relux.Dispatcher(logger: logger)
    let flow = await Runners.Flow(service: FailingService(), dispatcher: dispatcher)
    let _: Relux.ActionResult = await flow.apply(Runners.Effect.setEnabled("test", true))
    let actions = logger.actions.compactMap { $0 as? Runners.Action }
    #expect(actions.count == 4)
    guard case .changing("test", true) = actions[0],
          case .failed("Denied") = actions[1],
          case .changing("test", false) = actions[3] else {
        Issue.record("Flow did not balance start/failure/finish actions"); return
    }
    let _: Relux.ActionResult = await flow.apply(ForeignEffect())
    #expect(logger.actions.count == 4)
}

@Test func commandExecutorHandlesLargeOutputAndExitStatus() async throws {
    let runner = CommandExecutor()
    let result = try await runner.run("/usr/bin/printf", ["%050000d", "1"])
    #expect(result.code == 0)
    #expect(result.output.count == 50000)
    let failed = try await runner.run("/usr/bin/false", [])
    #expect(failed.code != 0)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_LAUNCH_AGENT_INTEGRATION"] == "1"))
func realLaunchAgentLifecycleWithoutGitHubJobs() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let service = LaunchAgentService(definitions: [fixture.definition])
    do {
        try await service.setEnabled(true, id: fixture.definition.id)
        #expect(await service.snapshots().first?.status == .running)
        try await service.setEnabled(true, id: fixture.definition.id)
        try await service.setEnabled(false, id: fixture.definition.id)
        #expect(await service.snapshots().first?.status == .stopped)
        try await service.setEnabled(false, id: fixture.definition.id)
    } catch {
        try? await service.setEnabled(false, id: fixture.definition.id)
        throw error
    }
}
