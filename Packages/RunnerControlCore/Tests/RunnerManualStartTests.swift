import Foundation
import Testing
@testable import RunnerControlCore

// MARK: - Manual start (RunAtLoad=false) command-boundary regression
//
// Production entry point: LaunchAgentService.setEnabled(_:id:) in
// Packages/RunnerControlCore/Sources/Runners+Service.swift.
// Executor boundary: /bin/launchctl via CommandExecuting.run.
//
// Live defect (2026-09-16): enabling a newly installed RunAtLoad=false
// service timed out with an incorrect stop message. bootstrap loads the
// job without starting it (print shows exit 0, state not running,
// runs=0), so the poll for running never succeeds. The fix issues an
// explicit `kickstart` (never `-k`) after bootstrap when the loaded job
// is idle, and reports start/stop confirmation failures accurately.

private let idleNotRunning = CommandResult(
    code: 0, output: "state = not running\nruns = 0\nlast exit code = (never exited)"
)

/// Stateful launchd model for the RunAtLoad=false lifecycle: prints report
/// stopped before bootstrap, idle after bootstrap, and running only after
/// an explicit kickstart. A fixed-queue fake cannot model this gate —
/// it would hand the kickstart result to the next poll — so old code
/// (no kickstart) provably times out here while fixed code succeeds.
private actor ManualStartGateExecutor: CommandExecuting {
    private(set) var calls: [[String]] = []
    private let initialPrint: CommandResult
    private let kickstartResult: CommandResult
    private let autoStartAfterBootstrap: Bool
    private let stuckAfterKickstart: Bool
    private let stuckAfterBootout: Bool
    private var bootstrapped = false
    private var kickstarted = false
    private var bootedOut = false

    init(
        initialPrint: CommandResult = CommandResult(code: 113, output: "Could not find service test"),
        kickstartResult: CommandResult = CommandResult(code: 0, output: ""),
        autoStartAfterBootstrap: Bool = false,
        stuckAfterKickstart: Bool = false,
        stuckAfterBootout: Bool = false
    ) {
        self.initialPrint = initialPrint
        self.kickstartResult = kickstartResult
        self.autoStartAfterBootstrap = autoStartAfterBootstrap
        self.stuckAfterKickstart = stuckAfterKickstart
        self.stuckAfterBootout = stuckAfterBootout
    }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        calls.append([executable] + arguments)
        switch arguments.first {
        case "print":
            if bootedOut {
                return stuckAfterBootout
                    ? running
                    : CommandResult(code: 113, output: "Could not find service test")
            }
            if !bootstrapped { return initialPrint }
            if kickstarted { return stuckAfterKickstart ? idleNotRunning : running }
            return autoStartAfterBootstrap ? running : idleNotRunning
        case "bootstrap":
            bootstrapped = true
            bootedOut = false
            return CommandResult(code: 0, output: "")
        case "kickstart":
            kickstarted = true
            return kickstartResult
        case "bootout":
            bootedOut = true
            bootstrapped = false
            kickstarted = false
            return CommandResult(code: 0, output: "")
        default:
            throw RunnerError.message("Unexpected command \(arguments)")
        }
    }
}

/// Fixture plist rewritten to the given RunAtLoad policy. Label, entry
/// point and working directory are preserved so start validation passes.
private func makeManualFixture(runAtLoad: Bool) throws -> Fixture {
    let fixture = try Fixture()
    let plistURL = fixture.definition.plist
    guard var plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: plistURL), format: nil
    ) as? [String: Any] else {
        throw RunnerError.message("Fixture plist unreadable")
    }
    plist["RunAtLoad"] = runAtLoad
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: plistURL)
    return fixture
}

@Test func manualStartKickstartsLoadedButIdleService() async throws {
    let fixture = try makeManualFixture(runAtLoad: false)
    defer { fixture.clean() }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("ManualHome-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let executor = ManualStartGateExecutor()
    let service = LaunchAgentService(
        definitions: [fixture.definition], executor: executor, userID: 501, home: home
    )
    let before = try Data(contentsOf: fixture.definition.plist)
    try await service.setEnabled(true, id: fixture.definition.id)
    let calls = await executor.calls
    let key = "gui/501/" + fixture.definition.id
    #expect(calls.contains(["/bin/launchctl", "bootstrap", "gui/501", fixture.definition.plist.path]))
    #expect(calls.contains(["/bin/launchctl", "kickstart", key]))
    #expect(calls.filter { $0.contains("kickstart") }.count == 1)
    #expect(!calls.contains(where: { $0.contains("-k") }))
    #expect(try Data(contentsOf: fixture.definition.plist) == before)
    let plist = try PropertyListSerialization.propertyList(from: before, format: nil) as? [String: Any]
    #expect((plist?["RunAtLoad"] as? Bool) == false)
    let loginCopy = home.appendingPathComponent("Library/LaunchAgents/\(fixture.definition.id).plist")
    #expect(!FileManager.default.fileExists(atPath: loginCopy.path))
}

@Test func manualAutoStartSkipsKickstartWhenRunning() async throws {
    let fixture = try makeManualFixture(runAtLoad: true)
    defer { fixture.clean() }
    let executor = ManualStartGateExecutor(autoStartAfterBootstrap: true)
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor, userID: 501)
    try await service.setEnabled(true, id: fixture.definition.id)
    let calls = await executor.calls
    #expect(calls.contains(["/bin/launchctl", "bootstrap", "gui/501", fixture.definition.plist.path]))
    #expect(!calls.contains(where: { $0.contains("kickstart") }))
}

@Test func manualEnableIdempotentWhenRunning() async throws {
    let fixture = try makeManualFixture(runAtLoad: false)
    defer { fixture.clean() }
    let executor = ManualStartGateExecutor(initialPrint: running)
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor, userID: 501)
    try await service.setEnabled(true, id: fixture.definition.id)
    let calls = await executor.calls
    #expect(calls.count == 1)
    #expect(calls.first == ["/bin/launchctl", "print", "gui/501/" + fixture.definition.id])
}

@Test func manualDisableNeverKickstarts() async throws {
    let fixture = try makeManualFixture(runAtLoad: false)
    defer { fixture.clean() }
    let executor = FakeExecutor([running, CommandResult(code: 0, output: ""), stopped])
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor, userID: 501)
    try await service.setEnabled(false, id: fixture.definition.id)
    let calls = await executor.calls
    #expect(calls.contains(["/bin/launchctl", "bootout", "gui/501/" + fixture.definition.id]))
    #expect(!calls.contains(where: { $0.contains("kickstart") || $0.contains("bootstrap") }))
}

@Test func manualDisableFailedServiceNeverKickstarts() async throws {
    let fixture = try makeManualFixture(runAtLoad: false)
    defer { fixture.clean() }
    let executor = FakeExecutor([
        idleNotRunning, CommandResult(code: 0, output: ""), idleNotRunning, stopped
    ])
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor, userID: 501)
    try await service.setEnabled(false, id: fixture.definition.id)
    let calls = await executor.calls
    #expect(calls.contains(["/bin/launchctl", "bootout", "gui/501/" + fixture.definition.id]))
    #expect(!calls.contains(where: { $0.contains("kickstart") }))
}

@Test func manualStartSurfacesKickstartFailure() async throws {
    let fixture = try makeManualFixture(runAtLoad: false)
    defer { fixture.clean() }
    let executor = ManualStartGateExecutor(
        kickstartResult: CommandResult(code: 1, output: "kick failed: No such process")
    )
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor, userID: 501)
    do {
        try await service.setEnabled(true, id: fixture.definition.id)
        Issue.record("Enable admitted a failed kickstart")
    } catch {
        #expect(error.localizedDescription.contains("kick failed"))
        #expect(!error.localizedDescription.contains("остановку"))
    }
    let calls = await executor.calls
    #expect(calls.filter { $0.contains("kickstart") }.count == 1)
}

@Test func manualEnableTimeoutReportsStart() async throws {
    let fixture = try makeManualFixture(runAtLoad: false)
    defer { fixture.clean() }
    let executor = ManualStartGateExecutor(stuckAfterKickstart: true)
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor, userID: 501)
    do {
        try await service.setEnabled(true, id: fixture.definition.id)
        Issue.record("Enable admitted a stuck start")
    } catch {
        #expect(error.localizedDescription.contains("запуск"))
        #expect(!error.localizedDescription.contains("остановку"))
    }
    #expect(await executor.calls.contains(["/bin/launchctl", "kickstart", "gui/501/" + fixture.definition.id]))
}

@Test func manualDisableTimeoutReportsStop() async throws {
    let fixture = try makeManualFixture(runAtLoad: false)
    defer { fixture.clean() }
    let executor = ManualStartGateExecutor(initialPrint: running, stuckAfterBootout: true)
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor, userID: 501)
    do {
        try await service.setEnabled(false, id: fixture.definition.id)
        Issue.record("Disable admitted a stuck stop")
    } catch {
        #expect(error.localizedDescription.contains("остановку"))
        #expect(!error.localizedDescription.contains("запуск"))
    }
    #expect(!(await executor.calls.contains(where: { $0.contains("kickstart") })))
}

@Test func manualEnableRefusesUnknownState() async throws {
    let fixture = try makeManualFixture(runAtLoad: false)
    defer { fixture.clean() }
    let executor = FakeExecutor([CommandResult(code: 1, output: "Operation not permitted")])
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor, userID: 501)
    do {
        try await service.setEnabled(true, id: fixture.definition.id)
        Issue.record("Enable admitted an unknown service state")
    } catch {
        #expect(error.localizedDescription.contains("Operation not permitted"))
    }
    #expect(await executor.calls.count == 1)
}

@Test func manualStartBlockedWhenRegistrationDamaged() async throws {
    let fixture = try makeManualFixture(runAtLoad: false)
    defer { fixture.clean() }
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".runner"))
    let executor = FakeExecutor([])
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor, userID: 501)
    do {
        try await service.setEnabled(true, id: fixture.definition.id)
        Issue.record("Enable admitted damaged registration")
    } catch {
        #expect(error.localizedDescription.contains("Рабочий каталог"))
    }
    #expect(await executor.calls.isEmpty)
}

@Test func manualFailedStateRecoversViaKickstart() async throws {
    let fixture = try makeManualFixture(runAtLoad: false)
    defer { fixture.clean() }
    let executor = ManualStartGateExecutor(initialPrint: idleNotRunning)
    let service = LaunchAgentService(definitions: [fixture.definition], executor: executor, userID: 501)
    try await service.setEnabled(true, id: fixture.definition.id)
    let calls = await executor.calls
    let key = "gui/501/" + fixture.definition.id
    #expect(calls.contains(["/bin/launchctl", "bootout", key]))
    #expect(calls.contains(["/bin/launchctl", "bootstrap", "gui/501", fixture.definition.plist.path]))
    #expect(calls.contains(["/bin/launchctl", "kickstart", key]))
    #expect(!calls.contains(where: { $0.contains("-k") }))
}
