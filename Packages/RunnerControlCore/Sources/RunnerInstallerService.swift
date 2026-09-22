import CryptoKit
import Foundation

/// Filesystem installer for downloaded GitHub Actions runners.
///
/// Production path: download bytes → SHA-256 verify → tar extract →
/// `bin/runsvc.sh` copied into the root and chmodded (as official `svc.sh`
/// would) → exact `config.sh` invocation → manual LaunchAgent plist.
/// All side effects stay below `installRoot`; tests inject a temporary root,
/// a fake downloader, and fixtures instead of touching production runners.
public actor RunnerInstallerService {
    public static let markerFileName = ".runnercontrol-install.json"
    public static let installOS = "osx"

    private let installRoot: URL
    private let downloader: @Sendable (URL) async throws -> Data
    private let executor: any CommandExecuting
    private let currentArch: @Sendable () -> String
    private let hasher: @Sendable (Data) -> String

    public init(
        installRoot: URL? = nil,
        downloader: (@Sendable (URL) async throws -> Data)? = nil,
        executor: (any CommandExecuting)? = nil,
        currentArch: (@Sendable () -> String)? = nil,
        hasher: (@Sendable (Data) -> String)? = nil
    ) {
        self.installRoot = installRoot
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/GitHubActions")
        self.downloader = downloader ?? { url in
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
        self.executor = executor ?? CommandExecutor()
        self.currentArch = currentArch ?? {
            #if arch(arm64)
            return "arm64"
            #else
            return "x64"
            #endif
        }
        self.hasher = hasher ?? { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    public nonisolated var root: URL { installRoot }
    public nonisolated var architecture: String { currentArch() }

    /// Single installer-wide mutation lease. The registration wizard runs
    /// ONE active mutating installer operation per app instance
    /// (download/extract, config.sh, service setup, partial recovery),
    /// for ANY directory. Acquired synchronously before the first await and
    /// released only when the owning operation settles, so actor reentrancy
    /// can never admit two concurrent mutations — no path-identity
    /// comparison, and therefore no filesystem-alias bypass class
    /// (symlinks, case variants, Unicode equivalences). Abandoning a UI
    /// generation does not release this resource; only the settling side
    /// effect does. Ordinary start/stop of already-installed runners and
    /// multiple installed CI runners are unaffected: they never take this
    /// lease.
    private var activeOperation: UUID?
    /// Directory the lease owner is mutating. Diagnostic only: refusal never
    /// compares paths, it refuses whenever a lease is held.
    private var activePath: String?
    /// Open file descriptor holding the cross-process lock for the active
    /// operation. flock releases automatically if the process dies, so a
    /// crashed owner can never wedge the installer for other processes.
    private var activeLockFD: Int32?
    /// Lock file name below the install root. Production app and CLI share
    /// the same root and therefore the same lock; tests inject temporary
    /// roots and stay isolated from each other and from production.
    nonisolated static let installerLockFileName = ".runnercontrol-installer.lock"

    public func directory(for installDirName: String) -> URL {
        installRoot.appendingPathComponent(installDirName)
    }

    private nonisolated static func isSymlink(atPath path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// Backstop for the alias ancestor walk. Real install paths hold a
    /// handful of components (macOS PATH_MAX bounds lexical components to
    /// roughly 512); lexical parents strictly shorten, so production never
    /// reaches this. It exists only so a non-fixpoint parent step — the
    /// hosted-CI `deletingLastPathComponent` spin, where
    /// `parent.path == current.path` never becomes true — terminates by
    /// refusing instead of hanging the caller.
    nonisolated static let maxAliasWalkAncestors = 4096

    /// Lexical parent of a path string, or nil at a root. Pure string
    /// operation: every non-root input maps to a strictly shorter string,
    /// so iteration always terminates regardless of Foundation version.
    /// Trailing slashes are tolerated; a lone relative component resolves
    /// to `"."` and `"."` itself is a root.
    nonisolated static func lexicalParent(of path: String) -> String? {
        var current = path
        while current.hasSuffix("/") && current.count > 1 { current.removeLast() }
        if current.isEmpty || current == "." || current == "/" { return nil }
        if let slash = current.lastIndex(of: "/") {
            if slash == current.startIndex { return "/" }
            return String(current[..<slash])
        }
        return "."
    }

    /// Refuses Finder-alias installation paths before any side effect. A
    /// Finder alias is not a transparent directory like a symlink: operating
    /// through its spelling would not operate on the target, so alias
    /// spellings are rejected instead of being followed. Symlinks are not
    /// refused here — and must be excluded explicitly because
    /// `isAliasFileKey` is also true for symlinks such as the system `/var`
    /// and `/tmp` links every temporary path resolves through. Concurrent
    /// symlink-alias mutations are serialized by the installer-wide lease,
    /// which compares nothing about paths.
    ///
    /// The ancestor walk is lexical and bounded: the start path is
    /// standardized once, parents are derived by string prefix (never by
    /// `deletingLastPathComponent`, whose root fixpoint varies across
    /// Foundation versions and spun forever on hosted CI), and a walk that
    /// still has not reached a root after `maxAliasWalkAncestors` steps
    /// refuses fail-closed instead of hanging.
    nonisolated static func ensureNoAlias(at directory: URL) throws {
        try ensureNoAlias(at: directory, parentStep: Self.lexicalParent(of:))
    }

    /// Traversal seam for the alias walk. Production passes
    /// `lexicalParent(of:)`; tests inject the legacy Foundation step to
    /// model the hosted-CI behavior the bound defends against.
    nonisolated static func ensureNoAlias(
        at directory: URL,
        parentStep: (String) -> String?
    ) throws {
        var current: String? = URL(fileURLWithPath: directory.path).standardizedFileURL.path
        var checked = 0
        while let path = current {
            guard checked < maxAliasWalkAncestors else {
                throw RunnerRegistration.RegistrationError.invalidDraft(
                    "Installation path '\(directory.path)' could not be verified against Finder aliases " +
                        "(ancestor walk did not terminate). Choose a direct folder path instead of an alias."
                )
            }
            checked += 1
            if FileManager.default.fileExists(atPath: path),
               !isSymlink(atPath: path),
               (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true {
                throw RunnerRegistration.RegistrationError.invalidDraft(
                    "Installation path '\(directory.path)' resolves through a Finder alias at '\(path)'. Choose a direct folder path instead of an alias."
                )
            }
            current = parentStep(path)
        }
    }

    /// Acquires the installer-wide mutation lease for `directory`.
    /// Synchronous: callers must invoke it before their first await so the
    /// check-and-set is atomic under actor isolation. Throws a retryable
    /// `installerBusy` whenever ANY live operation holds the lease,
    /// regardless of directory — there is no path comparison to bypass.
    /// The lease is also held cross-process via a flock file lock below
    /// the install root, so the GUI app and the CLI (separate processes)
    /// serialize installer mutations exactly like two operations in one
    /// process. Returns the owner token; the caller must hold it across
    /// awaits and release that exact token when the operation settles.
    private func acquireMutationLease(for directory: URL) throws -> UUID {
        try Self.ensureNoAlias(at: directory)
        guard activeOperation == nil else {
            throw RunnerRegistration.RegistrationError.installerBusy(path: directory.path)
        }
        let lockFD = try Self.lockInstallRoot(installRoot, pathForError: directory.path)
        let token = UUID()
        activeOperation = token
        activePath = directory.path
        activeLockFD = lockFD
        return token
    }

    /// Releases the installer-wide lease, but only for its exact owner. A
    /// token that does not match the current owner releases nothing, so a
    /// stale or foreign completion can never unlock a newer operation.
    /// Closing the lock descriptor releases the cross-process lock.
    private func releaseMutationLease(_ token: UUID) {
        guard activeOperation == token else { return }
        activeOperation = nil
        activePath = nil
        if let fd = activeLockFD {
            activeLockFD = nil
            close(fd)
        }
    }

    /// Non-blocking exclusive lock on the install root. Another process
    /// (GUI app vs CLI) holding the lock refuses with retryable
    /// `installerBusy`. Every other lock failure fails CLOSED with
    /// `installerUnavailable`: running a mutation with no proof of
    /// exclusivity would admit two installer owners (a second process may
    /// be mid-mutation behind the same broken lock path). The caller owns
    /// the returned descriptor and releases the lock by closing it.
    nonisolated static func lockInstallRoot(_ root: URL, pathForError: String) throws -> Int32 {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw RunnerRegistration.RegistrationError.installerUnavailable(
                "Cannot create installer lock directory \(root.path): \(error.localizedDescription). Refusing to run installer mutations unserialized."
            )
        }
        let lockURL = root.appendingPathComponent(installerLockFileName)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            let code = errno
            throw RunnerRegistration.RegistrationError.installerUnavailable(
                "Cannot open installer lock \(lockURL.path): \(String(cString: strerror(code))). Refusing to run installer mutations unserialized."
            )
        }
        // Close-on-exec: installer mutations spawn children (tar, config.sh)
        // while holding this descriptor. An inherited copy in a long-lived
        // child would keep the flock held after this process closes (and
        // releases) it, manufacturing phantom installerBusy refusals.
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            close(fd)
            throw RunnerRegistration.RegistrationError.installerUnavailable(
                "Cannot secure installer lock \(lockURL.path): \(String(cString: strerror(code))). Refusing to run installer mutations unserialized."
            )
        }
        // Contended acquisition spins briefly before refusing: a genuine
        // holder (another install running seconds) still refuses, but a
        // transient EWOULDBLOCK under massive process/thread parallelism
        // resolves into a correct acquisition instead of a phantom busy.
        // Bounded well under any real mutation window; the in-process
        // activeOperation guard ahead of this call already covers the
        // same-installer case, so this spin never waits on our own actor.
        var attempts = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EWOULDBLOCK, attempts < 30 {
                attempts += 1
                usleep(2_000)
                continue
            }
            close(fd)
            if code == EWOULDBLOCK {
                throw RunnerRegistration.RegistrationError.installerBusy(path: pathForError)
            }
            throw RunnerRegistration.RegistrationError.installerUnavailable(
                "Cannot lock \(lockURL.path): \(String(cString: strerror(code))). Refusing to run installer mutations unserialized."
            )
        }
        return fd
    }

    /// Point probe: refuses while the installer lease is held by a live
    /// operation, for ANY directory, in this or another process. The file
    /// lock is probed and released immediately, never held past this
    /// check — use `withInstallerHeld` for mutations that must stay
    /// serialized across their own writes.
    private func requireIdleInstaller(_ directory: URL) throws {
        try Self.ensureNoAlias(at: directory)
        guard activeOperation == nil else {
            throw RunnerRegistration.RegistrationError.installerBusy(path: directory.path)
        }
        close(try Self.lockInstallRoot(installRoot, pathForError: directory.path))
    }

    /// Runs a synchronous mutation while holding the installer lease both
    /// in-process and cross-process for the whole body. Synchronous bodies
    /// cannot interleave on this actor, so the lease is set and released
    /// around the call; the flock descriptor is held (not probe-closed)
    /// until the writes settle, closing the probe-then-write race where a
    /// foreign async mutation could start mid-write.
    private func withInstallerHeld<T>(directory: URL, _ body: () throws -> T) throws -> T {
        try Self.ensureNoAlias(at: directory)
        guard activeOperation == nil else {
            throw RunnerRegistration.RegistrationError.installerBusy(path: directory.path)
        }
        let fd = try Self.lockInstallRoot(installRoot, pathForError: directory.path)
        let token = UUID()
        activeOperation = token
        activePath = directory.path
        defer {
            if activeOperation == token {
                activeOperation = nil
                activePath = nil
            }
            close(fd)
        }
        return try body()
    }

    // MARK: - Idempotency markers

    public struct Marker: Codable, Sendable, Equatable {
        public var scopeKey: String
        public var completedSteps: Set<String>
        /// Server the directory was configured against (`.runner` host is
        /// authoritative; this records the config-time expectation so a
        /// group/server change cannot reuse an old configured marker).
        public var serverHost: String?
        /// Dedicated group passed to `config.sh --runnergroup` (org scope).
        /// `.runner` does not record it, so the marker must: a group-name
        /// edit never claims the old group's configuration as its own.
        public var groupName: String?
        public init(
            scopeKey: String, completedSteps: Set<String> = [],
            serverHost: String? = nil, groupName: String? = nil
        ) {
            self.scopeKey = scopeKey; self.completedSteps = completedSteps
            self.serverHost = serverHost; self.groupName = groupName
        }
    }

    public static let stepDownloaded = "downloaded"
    public static let stepInstalled = "installed"
    public static let stepConfigured = "configured"
    public static let stepServiceReady = "serviceReady"

    public func loadMarker(directory: URL) -> Marker? {
        let url = directory.appendingPathComponent(Self.markerFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    private func storeMarker(_ marker: Marker, directory: URL) throws {
        let data = try JSONEncoder().encode(marker)
        try data.write(to: directory.appendingPathComponent(Self.markerFileName), options: .atomic)
    }

    public func markCompleted(
        _ step: String, directory: URL, scopeKey: String,
        serverHost: String? = nil, groupName: String? = nil
    ) throws {
        var marker = loadMarker(directory: directory) ?? Marker(scopeKey: scopeKey)
        marker.completedSteps.insert(step)
        if let serverHost { marker.serverHost = serverHost }
        if let groupName { marker.groupName = groupName }
        try storeMarker(marker, directory: directory)
    }

    public func hasCompleted(_ step: String, directory: URL) -> Bool {
        loadMarker(directory: directory)?.completedSteps.contains(step) == true
    }

    // MARK: - Install

    /// Downloads, verifies, and extracts the official package. Idempotent:
    /// a completed `installed` marker with matching scope and server skips
    /// the work. Refuses to overwrite an already-registered directory (no
    /// duplicates).
    public func downloadAndInstall(
        asset: RunnerRegistration.DownloadAsset,
        draft: RunnerRegistration.Draft,
        serverHost: String? = nil
    ) async throws -> URL {
        try RunnerRegistration.Gates.validateNoSpace(
            installDirName: draft.installDirName, workFolder: draft.workFolder
        )
        let directory = self.directory(for: draft.installDirName)
        if directory.path.contains(" ") {
            throw RunnerRegistration.RegistrationError.noSpacePath("Installation path must not contain spaces.")
        }
        // Installer-wide ownership for the whole mutation, acquired before
        // the first await (reuse check included): any second mutation while
        // this install is live — same directory or not — is refused
        // retryably instead of starting a second download/extract. The owner
        // token is held across awaits and only that exact token releases.
        let lease = try acquireMutationLease(for: directory)
        defer { releaseMutationLease(lease) }
        let files = FileManager.default
        if let marker = loadMarker(directory: directory),
           marker.completedSteps.contains(Self.stepInstalled),
           marker.scopeKey == draft.scope.scopeKey,
           Self.markerServerMatches(marker: marker, serverHost: serverHost),
           files.fileExists(atPath: directory.appendingPathComponent("run.sh").path) {
            return directory
        }
        if files.fileExists(atPath: directory.appendingPathComponent(".runner").path) {
            throw RunnerRegistration.RegistrationError.alreadyRegistered(name: draft.runnerName)
        }
        let bytes: Data
        do {
            bytes = try await downloader(asset.downloadURL)
        } catch {
            throw RunnerRegistration.RegistrationError.network("Runner download failed: \(error.localizedDescription)")
        }
        // Fail closed: the official downloads endpoint documents
        // `sha256_checksum`, and an install without a verified digest is
        // refused rather than trusted on TLS alone.
        guard let expected = asset.sha256Checksum, !expected.isEmpty else {
            throw RunnerRegistration.RegistrationError.integrityMismatch
        }
        let actual = hasher(bytes)
        guard actual.lowercased() == expected.lowercased() else {
            throw RunnerRegistration.RegistrationError.integrityMismatch
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = files.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + asset.filename)
        defer { try? files.removeItem(at: archive) }
        try bytes.write(to: archive, options: .atomic)
        let result = try await executor.run("/usr/bin/tar", ["-xzf", archive.path, "-C", directory.path])
        guard result.code == 0 else {
            throw RunnerRegistration.RegistrationError.network(
                "Runner archive extraction failed: \(String(result.output.prefix(300)))"
            )
        }
        // Official packages keep runsvc.sh under bin/ until svc.sh installs it;
        // a bare extraction leaves the root copy absent, so install it here.
        try installRunsvc(directory: directory)
        try markCompleted(
            Self.stepDownloaded, directory: directory,
            scopeKey: draft.scope.scopeKey, serverHost: serverHost
        )
        try markCompleted(
            Self.stepInstalled, directory: directory,
            scopeKey: draft.scope.scopeKey, serverHost: serverHost
        )
        return directory
    }

    /// Server binding for install reuse. A marker written without a server
    /// (pre-revision-4) never satisfies a server-bound request: the next
    /// install re-verifies instead of reusing unknown provenance. Direct
    /// installer calls without a server (unit fixtures) keep the legacy
    /// scope-only reuse.
    static func markerServerMatches(marker: Marker, serverHost: String?) -> Bool {
        guard let want = serverHost else { return true }
        guard let have = marker.serverHost else { return false }
        return RunnerRegistration.OperationIdentity.normalizeServerHost(have)
            == RunnerRegistration.OperationIdentity.normalizeServerHost(want)
    }

    /// Copies official `bin/runsvc.sh` into the installation root and makes
    /// it executable, mirroring what official `svc.sh install` would do.
    public func installRunsvc(directory: URL) throws {
        let files = FileManager.default
        let source = directory.appendingPathComponent("bin/runsvc.sh")
        let target = directory.appendingPathComponent("runsvc.sh")
        guard files.fileExists(atPath: source.path) else {
            throw RunnerRegistration.RegistrationError.network("Runner package is missing bin/runsvc.sh.")
        }
        if files.fileExists(atPath: target.path) {
            try files.removeItem(at: target)
        }
        try files.copyItem(at: source, to: target)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    }

    // MARK: - Configure

    /// Runs the exact `config.sh` invocation. Skips when a previous attempt
    /// already registered this directory (marker + `.runner` present), so
    /// retries never create orphan or duplicate GitHub registrations.
    /// Returns the local agent ID read back from `.runner`.
    @discardableResult
    public func runConfig(
        directory: URL,
        scopeURL: String,
        token: String,
        draft: RunnerRegistration.Draft,
        runnerGroup: String?
    ) async throws -> Int64? {
        try await runConfig(
            directory: directory, scopeURL: scopeURL, token: token,
            draft: draft, runnerGroup: runnerGroup, replace: draft.allowReplace
        )
    }

    /// Explicit-`replace` variant. Production callers pass
    /// `draft.allowReplace`; tests drive both values.
    @discardableResult
    public func runConfig(
        directory: URL,
        scopeURL: String,
        token: String,
        draft: RunnerRegistration.Draft,
        runnerGroup: String?,
        replace: Bool
    ) async throws -> Int64? {
        let files = FileManager.default
        let scopeHost = URL(string: scopeURL)?.host ?? ""
        // Installer-wide ownership for the whole config, acquired before the
        // first await (resume checks included): any second mutation while
        // this config.sh is live is refused retryably instead of invoking
        // another config.sh. The lease is released only when this operation
        // settles; an abandoned UI generation never releases it. The owner
        // token is held across awaits and only that exact token releases.
        let lease = try acquireMutationLease(for: directory)
        defer { releaseMutationLease(lease) }
        if hasCompleted(Self.stepConfigured, directory: directory),
           files.fileExists(atPath: directory.appendingPathComponent(".runner").path) {
            // Idempotent resume never returns a stale ID: the existing
            // configuration must still match this draft on this server.
            let local = readLocalRegistration(directory: directory)
            let verified = try RunnerRegistration.Gates.verifiedLocalAgentID(
                local: local, configured: true, draft: draft, serverHost: scopeHost
            )
            try Self.verifyConfiguredGroup(
                marker: loadMarker(directory: directory), runnerGroup: runnerGroup, draft: draft
            )
            return verified
        }
        if files.fileExists(atPath: directory.appendingPathComponent(".runner").path),
           hasCompleted(Self.stepConfigured, directory: directory) {
            let local = readLocalRegistration(directory: directory)
            let verified = try RunnerRegistration.Gates.verifiedLocalAgentID(
                local: local, configured: true, draft: draft, serverHost: scopeHost
            )
            try Self.verifyConfiguredGroup(
                marker: loadMarker(directory: directory), runnerGroup: runnerGroup, draft: draft
            )
            return verified
        }
        let spec = RunnerRegistration.ConfigSpec(
            scopeURL: scopeURL, token: token, name: draft.runnerName,
            workFolder: draft.workFolder, labels: draft.labels,
            runnerGroup: runnerGroup, replace: replace
        )
        let args = RunnerRegistration.ConfigInvocation.arguments(spec)
        let executable = directory.appendingPathComponent("config.sh").path
        guard files.fileExists(atPath: executable) else {
            throw RunnerRegistration.RegistrationError.network("Runner package is missing config.sh.")
        }
        let result = try await executor.run(executable, args)
        guard result.code == 0 else {
            // Never echo the token: config output may repeat arguments.
            let scrubbed = GitHubAuth.Redaction.sanitize(result.output, secrets: [token])
            throw RunnerRegistration.RegistrationError.configFailed(String(scrubbed.prefix(700)))
        }
        guard files.fileExists(atPath: directory.appendingPathComponent(".runner").path) else {
            throw RunnerRegistration.RegistrationError.configFailed(
                "config.sh reported success but .runner is missing."
            )
        }
        try markCompleted(
            Self.stepConfigured, directory: directory, scopeKey: draft.scope.scopeKey,
            serverHost: scopeHost, groupName: runnerGroup
        )
        return readAgentID(directory: directory)
    }

    /// `.runner` does not record the org group, so the configured marker
    /// does. A resume whose marker names another group (or predates group
    /// recording) refuses instead of claiming the old group's configuration
    /// as the new draft's. Repository scope never configures a group.
    static func verifyConfiguredGroup(
        marker: Marker?, runnerGroup: String?, draft: RunnerRegistration.Draft
    ) throws {
        switch draft.scope {
        case .repository:
            return
        case .organization:
            break
        }
        let wanted = (runnerGroup ?? draft.groupName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let have = marker?.groupName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !have.isEmpty else {
            throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                "Directory '\(draft.installDirName)' was configured before group recording. Reconfigure for group '\(wanted)' instead of reusing the old configuration."
            )
        }
        guard have == wanted else {
            throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                "Local registration was configured for group '\(have)', not '\(wanted)'. Reconfigure instead of reusing the old group's configuration."
            )
        }
    }

    // MARK: - Dedicated-group ownership

    public static let ownershipFileName = ".runnercontrol-groups.json"

    private func ownershipFile() -> URL {
        installRoot.appendingPathComponent(Self.ownershipFileName)
    }

    private static func ownershipKey(serverHost: String, org: String, name: String) -> String {
        "\(RunnerRegistration.OperationIdentity.normalizeServerHost(serverHost))\u{0}\(org.lowercased())\u{0}\(name)"
    }

    /// Returns the locally recorded dedicated-group ID for
    /// `server` + `org` + `name`, or nil when this Mac never created (or
    /// took over) that group on that server. Name matches on GitHub alone
    /// never count as ownership, and ownership on one server never
    /// authorizes adoption on another.
    public func loadOwnedGroupID(serverHost: String, org: String, name: String) -> Int64? {
        guard let data = try? Data(contentsOf: ownershipFile()),
              let table = try? JSONDecoder().decode([String: Int64].self, from: data) else { return nil }
        return table[Self.ownershipKey(serverHost: serverHost, org: org, name: name)]
    }

    public func saveOwnedGroupID(serverHost: String, org: String, name: String, groupID: Int64) throws {
        let file = ownershipFile()
        var table: [String: Int64] = [:]
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) {
            table = decoded
        }
        table[Self.ownershipKey(serverHost: serverHost, org: org, name: name)] = groupID
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(table)
        try data.write(to: file, options: .atomic)
    }

    /// Reads the local `.runner` identity without touching credentials.
    /// Returns nil only when the file is missing or unparseable; a present
    /// but incomplete file returns a partial struct so verification can name
    /// the exact missing field instead of crashing.
    public func readLocalRegistration(directory: URL) -> RunnerRegistration.LocalRegistration? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".runner")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var agentID: Int64?
        if let id = object["agentId"] as? Int64 { agentID = id }
        else if let id = object["agentId"] as? Int { agentID = Int64(id) }
        else if let id = object["agentId"] as? NSNumber { agentID = id.int64Value }
        return RunnerRegistration.LocalRegistration(
            agentID: agentID,
            agentName: object["agentName"] as? String,
            gitHubURL: object["gitHubUrl"] as? String,
            workFolder: object["workFolder"] as? String
        )
    }

    /// Reads the local agent ID from `.runner` without touching credentials.
    public func readAgentID(directory: URL) -> Int64? {
        readLocalRegistration(directory: directory)?.agentID
    }

    // MARK: - Manual LaunchAgent

    /// Writes the manual service plist (RunAtLoad off for new runners) and
    /// validates it matches the directory. Never bootstraps the service:
    /// enabling is the user's separate action.
    @discardableResult
    public func setupService(directory: URL, label: String) throws -> URL {
        guard !directory.path.contains(" ") else {
            throw RunnerRegistration.RegistrationError.noSpacePath("Installation path must not contain spaces.")
        }
        // The lease is held for the whole rewrite: a foreign mutation
        // starting after a point probe would otherwise overlap these writes.
        return try withInstallerHeld(directory: directory) {
            let files = FileManager.default
            guard files.fileExists(atPath: directory.appendingPathComponent("runsvc.sh").path) else {
                throw RunnerRegistration.RegistrationError.network(
                    "runsvc.sh is missing; reinstall before setting up the service."
                )
            }
            let plist = directory.appendingPathComponent("manual-service.plist")
            let payload: [String: Any] = [
                "Label": label,
                "ProgramArguments": [directory.appendingPathComponent("runsvc.sh").path],
                "WorkingDirectory": directory.path,
                "RunAtLoad": false
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
            try data.write(to: plist, options: .atomic)
            let scopeKey = loadMarker(directory: directory)?.scopeKey ?? ""
            try markCompleted(Self.stepServiceReady, directory: directory, scopeKey: scopeKey)
            return plist
        }
    }

    /// Removes a failed partial install so retries start clean. Refuses to
    /// touch directories that already hold a registration (`.runner`) or an
    /// unknown marker scope: recovery never deletes a working runner.
    public func recoverPartialInstall(directory: URL, scopeKey: String) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: directory.path) else { return }
        // The lease is held for the whole deletion: a foreign mutation
        // starting after a point probe would otherwise overlap it.
        try withInstallerHeld(directory: directory) {
            guard !files.fileExists(atPath: directory.appendingPathComponent(".runner").path) else {
                throw RunnerRegistration.RegistrationError.alreadyRegistered(name: directory.lastPathComponent)
            }
            if let marker = loadMarker(directory: directory), marker.scopeKey != scopeKey {
                throw RunnerRegistration.RegistrationError.alreadyInstalled(path: directory.path)
            }
            try files.removeItem(at: directory)
        }
    }

    // MARK: - Catalog operations (shared lease)

    /// Public idle check for catalog file mutations (RunAtLoad edits,
    /// relink path updates). Refuses while ANY installer mutation is live,
    /// for ANY directory. Retry after the owner settles.
    public func requireIdle(for directory: URL) throws {
        try requireIdleInstaller(directory)
    }

    /// Runs the exact `config.sh remove` invocation to unregister a runner
    /// from GitHub. Holds the app-wide installer lease across the process so
    /// no registration, install, recovery or second unregister can overlap,
    /// including alias spellings of the same directory. Never deletes the
    /// working directory or the service manifest: files stay for re-registration
    /// or explicit file deletion. The remove token is scrubbed from errors.
    /// The optional `sessionAuthority` is enforced after the lease is held
    /// and immediately before `config.sh remove` begins: a logout or login
    /// replacement that lands between the caller's final check and this
    /// boundary refuses the removal instead of running it under stale
    /// authority. Callers without a session pass nil and keep the legacy
    /// behavior.
    public func unregister(
        directory: URL, removeToken: String,
        sessionAuthority: (@Sendable () async -> Bool)? = nil
    ) async throws {
        let lease = try acquireMutationLease(for: directory)
        defer { releaseMutationLease(lease) }
        let files = FileManager.default
        let executable = directory.appendingPathComponent("config.sh").path
        guard files.fileExists(atPath: executable) else {
            throw RunnerRegistration.RegistrationError.network("Runner package is missing config.sh.")
        }
        guard files.fileExists(atPath: directory.appendingPathComponent(".runner").path) else {
            throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                "No local registration at '\(directory.path)'. Nothing to unregister."
            )
        }
        if let sessionAuthority, await sessionAuthority() == false {
            throw RunnerRegistration.RegistrationError.sessionInvalidated
        }
        let result = try await executor.run(executable, ["remove", "--token", removeToken, "--unattended"])
        guard result.code == 0 else {
            let scrubbed = GitHubAuth.Redaction.sanitize(result.output, secrets: [removeToken])
            throw RunnerRegistration.RegistrationError.configFailed(String(scrubbed.prefix(700)))
        }
    }

    /// Updates an existing service manifest to a new directory after the user
    /// explicitly relinks a moved folder. Preserves every other key,
    /// including the imported RunAtLoad policy. Refuses while the installer
    /// lease is held by a live mutation.
    public func updateServicePaths(plist: URL, directory: URL) throws {
        guard !directory.path.contains(" ") else {
            throw RunnerRegistration.RegistrationError.noSpacePath("Installation path must not contain spaces.")
        }
        // The lease is held for the whole rewrite: a foreign mutation
        // starting after a point probe would otherwise overlap these writes.
        try withInstallerHeld(directory: directory) {
            guard let data = try? Data(contentsOf: plist),
                  var object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw RunnerRegistration.RegistrationError.network("Service manifest is unreadable.")
            }
            object["WorkingDirectory"] = directory.path
            object["ProgramArguments"] = [directory.appendingPathComponent("runsvc.sh").path]
            let out = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            try out.write(to: plist, options: .atomic)
        }
    }
}
