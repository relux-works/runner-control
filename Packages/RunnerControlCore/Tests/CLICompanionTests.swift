import Foundation
import Testing
@testable import RunnerControlCore

// MARK: - CLIInstallerService (symlink install into PATH)

private func installerFixture() throws -> (root: URL, target: URL, lock: String) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RC-CLI-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("runner-control")
    try "#!/bin/sh\n".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    return (root, target, root.appendingPathComponent("test-install.lock").path)
}

@Test func installCreatesSymlinkAndIsIdempotent() throws {
    let fixture = try installerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let link = fixture.root.appendingPathComponent("bin/runner-control").path
    #expect(CLIInstallerService.status(linkPath: link, target: fixture.target) == .missing)
    try CLIInstallerService.install(target: fixture.target, linkPath: link, lockPath: fixture.lock)
    #expect(CLIInstallerService.status(linkPath: link, target: fixture.target) == .installedCurrent)
    // Second install is a no-op, not an error.
    try CLIInstallerService.install(target: fixture.target, linkPath: link, lockPath: fixture.lock)
    #expect(CLIInstallerService.status(linkPath: link, target: fixture.target) == .installedCurrent)
}

@Test func installRefusesNonSymlink() throws {
    let fixture = try installerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let link = fixture.root.appendingPathComponent("runner-control").path
    try "foreign".write(to: URL(fileURLWithPath: link), atomically: true, encoding: .utf8)
    #expect(CLIInstallerService.status(linkPath: link, target: fixture.target) == .blockedByFile)
    do {
        try CLIInstallerService.install(target: fixture.target, linkPath: link, lockPath: fixture.lock)
        Issue.record("expected blockedByFile")
    } catch let error as CLIInstallerService.InstallError {
        #expect(error == .blockedByFile(path: link))
    }
    #expect((try? String(contentsOf: URL(fileURLWithPath: link), encoding: .utf8)) == "foreign")
}

@Test func installAdoptsForeignSymlink() throws {
    let fixture = try installerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let link = fixture.root.appendingPathComponent("bin/runner-control").path
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: link).deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/usr/bin/false")
    if case .installedOther = CLIInstallerService.status(linkPath: link, target: fixture.target) {
    } else {
        Issue.record("expected installedOther")
    }
    try CLIInstallerService.install(target: fixture.target, linkPath: link, lockPath: fixture.lock)
    #expect(CLIInstallerService.status(linkPath: link, target: fixture.target) == .installedCurrent)
}

@Test func installRefusesMissingTarget() throws {
    // A PATH-spelled self-install used to link a nonexistent target with
    // success, leaving a dangling symlink. Pre-fix this created the link.
    let fixture = try installerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let link = fixture.root.appendingPathComponent("bin/runner-control").path
    let missing = fixture.root.appendingPathComponent("no-such-binary")
    do {
        try CLIInstallerService.install(target: missing, linkPath: link, lockPath: fixture.lock)
        Issue.record("expected invalidTarget")
    } catch let error as CLIInstallerService.InstallError {
        #expect(error == .invalidTarget(path: missing.path))
    }
    #expect(!FileManager.default.fileExists(atPath: link))
}

@Test func installRefusesNonExecutableTarget() throws {
    let fixture = try installerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let link = fixture.root.appendingPathComponent("bin/runner-control").path
    let plain = fixture.root.appendingPathComponent("plain.txt")
    try "x".write(to: plain, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
    do {
        try CLIInstallerService.install(target: plain, linkPath: link, lockPath: fixture.lock)
        Issue.record("expected invalidTarget")
    } catch let error as CLIInstallerService.InstallError {
        #expect(error == .invalidTarget(path: plain.path))
    }
    #expect(!FileManager.default.fileExists(atPath: link))
}

@Test func pathInstallLeaseRefusesWhileHeld() throws {
    // Hold a PATH-install lock the way a concurrent installer would
    // (separate open conflicts even in-process on macOS): install must
    // fail fast with a retryable error instead of interleaving. Uses an
    // injected path so parallel tests never share one lock.
    let fixture = try installerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let held = open(fixture.lock, O_CREAT | O_RDWR, 0o600)
    #expect(held >= 0)
    defer { close(held) }
    #expect(flock(held, LOCK_EX | LOCK_NB) == 0)
    let link = fixture.root.appendingPathComponent("bin/runner-control").path
    do {
        try CLIInstallerService.install(target: fixture.target, linkPath: link, lockPath: fixture.lock)
        Issue.record("expected busy lease refusal")
    } catch let error as CLIInstallerService.InstallError {
        if case .io(let message) = error {
            #expect(message.contains("in progress"))
        } else {
            Issue.record("wrong error: \(error)")
        }
    }
    #expect(!FileManager.default.fileExists(atPath: link))
}

@Test func pathInstallDefaultsToFixedLock() throws {
    // The only fixed-path user in the suite: hold the production lock and
    // prove the default entry points route through it. Every other test
    // uses an injected path, so nothing can starve or be starved here.
    let held = open(CLIInstallerService.pathInstallLockPath, O_CREAT | O_RDWR, 0o600)
    #expect(held >= 0)
    defer { close(held) }
    #expect(flock(held, LOCK_EX | LOCK_NB) == 0)
    let fixture = try installerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let link = fixture.root.appendingPathComponent("bin/runner-control").path
    do {
        try CLIInstallerService.install(target: fixture.target, linkPath: link)
        Issue.record("expected busy lease refusal on the fixed path")
    } catch let error as CLIInstallerService.InstallError {
        if case .io(let message) = error {
            #expect(message.contains("in progress"))
        } else {
            Issue.record("wrong error: \(error)")
        }
    }
    #expect(!FileManager.default.fileExists(atPath: link))
}

@Test func pathInstallLeaseSerializesConcurrentInstalls() async throws {
    // Concurrent installs to distinct links all succeed: the lease
    // serializes rather than refusing or deadlocking.
    let fixture = try installerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0 ..< 8 {
            group.addTask {
                let link = fixture.root.appendingPathComponent("bin\(index)/runner-control").path
                try CLIInstallerService.install(target: fixture.target, linkPath: link, lockPath: fixture.lock)
            }
        }
        try await group.waitForAll()
    }
    for index in 0 ..< 8 {
        let link = fixture.root.appendingPathComponent("bin\(index)/runner-control").path
        #expect(CLIInstallerService.status(linkPath: link, target: fixture.target) == .installedCurrent)
    }
}

@Test func currentExecutableURLResolvesToRealBinary() {
    // The process image path must exist and be executable regardless of
    // argv[0] spelling (bare name via PATH, symlink, sudo).
    let url = CLIInstallerService.currentExecutableURL()
    #expect(FileManager.default.isExecutableFile(atPath: url.path))
}

@Test func uninstallRemovesOnlyOwnSymlink() throws {
    let fixture = try installerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let own = fixture.root.appendingPathComponent("own").path
    try CLIInstallerService.install(target: fixture.target, linkPath: own, lockPath: fixture.lock)
    try CLIInstallerService.uninstall(target: fixture.target, linkPath: own, lockPath: fixture.lock)
    #expect(CLIInstallerService.status(linkPath: own, target: fixture.target) == .missing)
    // Missing link: no-op.
    try CLIInstallerService.uninstall(target: fixture.target, linkPath: own, lockPath: fixture.lock)

    let foreign = fixture.root.appendingPathComponent("foreign").path
    try FileManager.default.createSymbolicLink(atPath: foreign, withDestinationPath: "/usr/bin/false")
    do {
        try CLIInstallerService.uninstall(target: fixture.target, linkPath: foreign, lockPath: fixture.lock)
        Issue.record("expected pointsElsewhere")
    } catch let error as CLIInstallerService.InstallError {
        if case .pointsElsewhere = error {} else { Issue.record("wrong error: \(error)") }
    }
    #expect(FileManager.default.fileExists(atPath: foreign))

    let regular = fixture.root.appendingPathComponent("regular").path
    try "x".write(to: URL(fileURLWithPath: regular), atomically: true, encoding: .utf8)
    do {
        try CLIInstallerService.uninstall(target: fixture.target, linkPath: regular, lockPath: fixture.lock)
        Issue.record("expected blockedByFile")
    } catch let error as CLIInstallerService.InstallError {
        #expect(error == .blockedByFile(path: regular))
    }
}

@Test func privilegedScriptsRecheckPreconditions() {
    let install = CLIInstallerService.privilegedInstallScript(
        target: URL(fileURLWithPath: "/Applications/RunnerControl.app/Contents/Helpers/runner-control"),
        linkPath: "/usr/local/bin/runner-control"
    )
    #expect(install.contains("ln -sf"))
    #expect(install.contains("not a symlink, refusing"))
    #expect(install.contains("[ -x \"$dest\" ]"))
    let uninstall = CLIInstallerService.privilegedUninstallScript(
        target: URL(fileURLWithPath: "/Applications/RunnerControl.app/Contents/Helpers/runner-control"),
        linkPath: "/usr/local/bin/runner-control"
    )
    #expect(uninstall.contains("points elsewhere, refusing"))
    #expect(uninstall.contains("[ -L \"$link\" ] || exit 0"))
    let wrapped = CLIInstallerService.privilegedAppleScript(shell: "echo \"hi\"", prompt: "Prompt \"x\"")
    #expect(wrapped.contains("with administrator privileges"))
    #expect(wrapped.contains("\\\"hi\\\""))
    #expect(wrapped.contains("Prompt \\\"x\\\""))
}

// MARK: - Installer cross-process lease (flock)

@Test func installRootLockRoundTrip() throws {
    // Same-process acquire/release/reacquire. Note: on macOS a second
    // LOCK_EX|NB on the same file from the SAME process via a separate open
    // IS refused with EWOULDBLOCK, so same-process exclusion also holds;
    // cross-process refusal is covered by the test below with a helper
    // child holding the lock.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RC-Lock-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try RunnerInstallerService.lockInstallRoot(root, pathForError: root.path)
    close(first)
    let second = try RunnerInstallerService.lockInstallRoot(root, pathForError: root.path)
    close(second)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(RunnerInstallerService.installerLockFileName).path))
}

@Test func installRootLockRefusesForeignProcessHolder() throws {
    // A child process holds the flock via the same primitive (sh + a tiny
    // Swift helper would need a build; flock(1) is absent on macOS, so the
    // child execs THIS test bundle's logic through an inline swift script
    // that opens + flock()s the file and sleeps). Fallback when swift is
    // unavailable: skip rather than fake the assertion.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RC-LockX-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let lockPath = root.appendingPathComponent(RunnerInstallerService.installerLockFileName).path
    FileManager.default.createFile(atPath: lockPath, contents: nil)
    let helper = root.appendingPathComponent("hold.swift")
    try """
    import Foundation
    let fd = open(CommandLine.arguments[1], O_RDWR)
    precondition(fd >= 0 && flock(fd, LOCK_EX) == 0)
    print("HELD", terminator: "")
    fflush(stdout)
    sleep(20)
    """.write(to: helper, atomically: true, encoding: .utf8)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    child.arguments = [helper.path, lockPath]
    let out = Pipe()
    child.standardOutput = out
    child.standardError = FileHandle.nullDevice
    do {
        try child.run()
    } catch {
        // No swift runner in this environment: the cross-process refusal
        // is unproven. Fail loudly instead of passing vacuously — a
        // missing fixture must never turn this negative test green.
        Issue.record("swift helper unavailable; foreign-holder refusal unproven")
        return
    }
    defer { child.terminate() }
    // Watchdog: a stuck helper can never hang the suite (termination EOFs
    // the pipe and unblocks the read below).
    DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
        if child.isRunning { child.terminate() }
    }
    // Wait until the child reports the held lock.
    var sawHeld = false
    let handle = out.fileHandleForReading
    while !sawHeld {
        let data = handle.availableData
        if data.isEmpty { break }
        if String(data: data, encoding: .utf8)?.contains("HELD") == true { sawHeld = true; break }
        if child.isRunning == false { break }
    }
    guard sawHeld else {
        // Helper could not start (offline swift, first-run delay): the
        // cross-process refusal is unproven. Fail loudly, never skip.
        Issue.record("swift helper never held the lock; foreign-holder refusal unproven")
        return
    }
    do {
        let fd = try RunnerInstallerService.lockInstallRoot(root, pathForError: root.path)
        close(fd)
        Issue.record("expected installerBusy while a foreign process holds the lock")
    } catch let error as RunnerRegistration.RegistrationError {
        if case .installerBusy = error {} else { Issue.record("wrong error: \(error)") }
    }
}

@Test func installRootLockFailsClosedWhenLockUnusable() throws {
    // A lock path that cannot be opened (here: a directory sitting where
    // the lock file belongs) must refuse mutations, not admit them
    // unserialized. Pre-fix this returned nil (fail open) and two
    // independent owners could enter downloadAndInstall concurrently.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RC-LockD-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(RunnerInstallerService.installerLockFileName),
        withIntermediateDirectories: true
    )
    do {
        let fd = try RunnerInstallerService.lockInstallRoot(root, pathForError: root.path)
        close(fd)
        Issue.record("expected installerUnavailable when the lock file cannot be opened")
    } catch let error as RunnerRegistration.RegistrationError {
        if case .installerUnavailable = error {} else { Issue.record("wrong error: \(error)") }
    }
}
