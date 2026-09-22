import Foundation

/// Installs the `runner-control` command-line companion shipped inside the
/// app bundle. The GUI button and the CLI's own `install-cli` command share
/// this service, so both install exactly the same binary.
///
/// The installed entry is always a symlink to the binary inside
/// `RunnerControl.app/Contents/Helpers/`, never a copy: Sparkle updates
/// replace the bundle, and the symlink follows automatically.
public enum CLIInstallerService {
    public static let commandName = "runner-control"
    public static let helpersSubpath = "Contents/Helpers/runner-control"
    public static let primaryLinkPath = "/usr/local/bin/runner-control"

    public static var fallbackLinkURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/runner-control")
    }

    public enum LinkStatus: Sendable, Equatable {
        /// Symlink exists and resolves to the expected binary.
        case installedCurrent
        /// Symlink exists but resolves elsewhere (foreign install).
        case installedOther(destination: String)
        /// Nothing at the link path.
        case missing
        /// A non-symlink file occupies the link path. Never touched.
        case blockedByFile
    }

    public enum InstallError: LocalizedError, Sendable, Equatable {
        case bundledBinaryMissing
        case needsAdmin(path: String)
        case blockedByFile(path: String)
        case pointsElsewhere(path: String, destination: String)
        case invalidTarget(path: String)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .bundledBinaryMissing:
                "The bundled \(commandName) binary is missing. Reinstall Runner Control."
            case .needsAdmin(let path):
                "Cannot write \(path) without administrator rights."
            case .blockedByFile(let path):
                "Refusing to replace \(path): it is not a symlink."
            case .pointsElsewhere(let path, let destination):
                "Refusing to remove \(path): it points at \(destination)."
            case .invalidTarget(let path):
                "Refusing to link a missing or non-executable target: \(path)."
            case .io(let message):
                message
            }
        }
    }

    /// The binary this installer manages: the Helpers executable inside the
    /// host app bundle. Nil when the host is not the shipped app layout
    /// (local dev builds without an embedded CLI).
    public static func bundledBinaryURL(hostBundle: Bundle = .main) -> URL? {
        guard let bundleURL = hostBundle.bundleURL as URL?,
              bundleURL.pathExtension == "app" else { return nil }
        let candidate = bundleURL.appendingPathComponent(helpersSubpath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
              !isDir.boolValue,
              FileManager.default.isExecutableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    /// The binary of the currently running process, for CLI self-install
    /// (`runner-control install-cli` links PATH at its own location).
    /// Resolved from the process image, never from argv[0]: when the command
    /// is found via PATH (or sudo), argv[0] is the bare name and a
    /// cwd-relative resolution points at a nonexistent file, which used to
    /// self-install a dangling symlink with success.
    public static func currentExecutableURL() -> URL {
        if let url = Bundle.main.executableURL {
            return url.resolvingSymlinksInPath()
        }
        if let dyld = executablePathViaDyld() {
            return URL(fileURLWithPath: dyld).resolvingSymlinksInPath()
        }
        // Last resort (practically unreachable): historical argv[0] spelling.
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }

    private static func executablePathViaDyld() -> String? {
        var size = UInt32(0)
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Fixed cross-process lock serializing PATH symlink install/uninstall
    /// between the GUI app and the CLI (same user). Lives in /tmp, not
    /// beside the link, so locking never needs the admin rights the link
    /// itself may require. The privileged root script cannot take this
    /// lock (no flock(1) on macOS) and keeps precondition re-checks
    /// instead; concurrent privileged installs last-writer-win.
    public static let pathInstallLockPath = "/tmp/works.relux.runnercontrol.cli-install.lock"

    /// Runs `body` under the PATH-install lease. Non-blocking with bounded
    /// retries: a live installer holds the lock for milliseconds, so a
    /// 1s budget absorbs real contention while a stuck holder still fails
    /// fast instead of hanging the caller.
    public static func withPathInstallLease<T>(_ body: () throws -> T) throws -> T {
        try withPathInstallLease(lockPath: pathInstallLockPath, body)
    }

    /// Test seam: same lease on an injected path so parallel tests never
    /// share the fixed production lock (a held-lock negative test would
    /// otherwise starve unrelated install tests of their retry budget).
    static func withPathInstallLease<T>(lockPath: String, _ body: () throws -> T) throws -> T {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            let code = errno
            throw InstallError.io("Cannot open CLI install lock: \(String(cString: strerror(code))).")
        }
        defer { close(fd) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            throw InstallError.io("Cannot secure CLI install lock: \(String(cString: strerror(code))).")
        }
        for _ in 0 ..< 20 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return try body()
            }
            let code = errno
            guard code == EWOULDBLOCK else {
                throw InstallError.io("Cannot lock CLI install: \(String(cString: strerror(code))).")
            }
            usleep(50_000)
        }
        throw InstallError.io("Another CLI install is in progress; retry.")
    }

    public static func status(linkPath: String, target: URL) -> LinkStatus {
        let values = try? URL(fileURLWithPath: linkPath).resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) ?? ""
            let resolved: String
            if destination.hasPrefix("/") {
                resolved = URL(fileURLWithPath: destination).resolvingSymlinksInPath().path
            } else {
                resolved = URL(fileURLWithPath: linkPath).deletingLastPathComponent()
                    .appendingPathComponent(destination).resolvingSymlinksInPath().path
            }
            if resolved == target.resolvingSymlinksInPath().path {
                return .installedCurrent
            }
            return .installedOther(destination: destination)
        }
        if FileManager.default.fileExists(atPath: linkPath) {
            return .blockedByFile
        }
        return .missing
    }

    /// Creates (or refreshes) the symlink. Refuses to replace non-symlinks
    /// and refuses missing/non-executable targets (never a dangling link
    /// with success). Throws `needsAdmin` when the directory is not
    /// writable. The check-and-swap runs under the PATH-install lease so a
    /// concurrent GUI/CLI install cannot interleave between status and link.
    public static func install(target: URL, linkPath: String) throws {
        try install(target: target, linkPath: linkPath, lockPath: pathInstallLockPath)
    }

    /// Test seam, see `withPathInstallLease(lockPath:_:)`.
    static func install(target: URL, linkPath: String, lockPath: String) throws {
        guard FileManager.default.isExecutableFile(atPath: target.path) else {
            throw InstallError.invalidTarget(path: target.path)
        }
        try withPathInstallLease(lockPath: lockPath) {
            switch status(linkPath: linkPath, target: target) {
            case .installedCurrent:
                return
            case .blockedByFile:
                throw InstallError.blockedByFile(path: linkPath)
            case .installedOther, .missing:
                break
            }
            let linkURL = URL(fileURLWithPath: linkPath)
            let directory = linkURL.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw InstallError.needsAdmin(path: linkPath)
            }
            guard FileManager.default.isWritableFile(atPath: directory.path) else {
                throw InstallError.needsAdmin(path: linkPath)
            }
            if (try? URL(fileURLWithPath: linkPath).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                try? FileManager.default.removeItem(at: linkURL)
            }
            do {
                try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: target.path)
            } catch {
                throw InstallError.io(error.localizedDescription)
            }
        }
    }

    /// Removes the symlink only when it points at `target`. Never deletes
    /// regular files or foreign symlinks. Runs under the PATH-install
    /// lease, serialized against concurrent installs.
    public static func uninstall(target: URL, linkPath: String) throws {
        try uninstall(target: target, linkPath: linkPath, lockPath: pathInstallLockPath)
    }

    /// Test seam, see `withPathInstallLease(lockPath:_:)`.
    static func uninstall(target: URL, linkPath: String, lockPath: String) throws {
        try withPathInstallLease(lockPath: lockPath) {
            switch status(linkPath: linkPath, target: target) {
            case .missing:
                return
            case .blockedByFile:
                throw InstallError.blockedByFile(path: linkPath)
            case .installedOther(let destination):
                throw InstallError.pointsElsewhere(path: linkPath, destination: destination)
            case .installedCurrent:
                break
            }
            guard FileManager.default.isWritableFile(atPath: URL(fileURLWithPath: linkPath).deletingLastPathComponent().path) else {
                throw InstallError.needsAdmin(path: linkPath)
            }
            do {
                try FileManager.default.removeItem(atPath: linkPath)
            } catch {
                throw InstallError.io(error.localizedDescription)
            }
        }
    }

    /// Shell script removing the link, but only when it is a symlink
    /// pointing exactly at `target`. Same refusal rules as `uninstall`.
    public static func privilegedUninstallScript(target: URL, linkPath: String) -> String {
        let link = linkPath.replacingOccurrences(of: "'", with: "'\\''")
        let dest = target.path.replacingOccurrences(of: "'", with: "'\\''")
        return """
        set -e
        link='\(link)'
        dest='\(dest)'
        [ -L "$link" ] || exit 0
        [ "$(readlink "$link")" = "$dest" ] || { echo "points elsewhere, refusing" >&2; exit 1; }
        rm "$link"
        """
    }

    /// Wraps a shell script in an osascript `do shell script ... with
    /// administrator privileges` invocation with a product prompt. Pure
    /// string building; the caller runs `/usr/bin/osascript -e` with it.
    public static func privilegedAppleScript(shell: String, prompt: String) -> String {
        let escapedShell = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escapedShell)\" with administrator privileges with prompt \"\(escapedPrompt)\""
    }

    /// Shell script the GUI runs with administrator privileges for the
    /// primary location. Single-quoted paths; the script itself re-checks
    /// every precondition instead of trusting the caller.
    public static func privilegedInstallScript(target: URL, linkPath: String) -> String {
        let link = linkPath.replacingOccurrences(of: "'", with: "'\\''")
        let dest = target.path.replacingOccurrences(of: "'", with: "'\\''")
        return """
        set -e
        link='\(link)'
        dest='\(dest)'
        [ -x "$dest" ] || { echo "bundled binary missing" >&2; exit 1; }
        if [ -e "$link" ] && [ ! -L "$link" ]; then echo "not a symlink, refusing" >&2; exit 1; fi
        mkdir -p "$(dirname "$link")"
        ln -sf "$dest" "$link"
        """
    }
}
