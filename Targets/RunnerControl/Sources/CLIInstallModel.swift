import AppKit
import RunnerControlCore

/// Install state of the `runner-control` CLI companion (General tab).
@MainActor final class CLIInstallModel: ObservableObject {
    @Published private(set) var statusText: String = ""
    @Published private(set) var available: Bool = false
    @Published private(set) var installed: Bool = false
    @Published private(set) var busy: Bool = false

    private var target: URL?

    init() {
        refresh()
    }

    func refresh() {
        target = CLIInstallerService.bundledBinaryURL()
        guard let target else {
            available = false
            installed = false
            statusText = "Not available in this build."
            return
        }
        available = true
        let primary = CLIInstallerService.status(linkPath: CLIInstallerService.primaryLinkPath, target: target)
        let fallback = CLIInstallerService.status(linkPath: CLIInstallerService.fallbackLinkURL.path, target: target)
        switch (primary, fallback) {
        case (.installedCurrent, _):
            installed = true
            statusText = "Installed: \(CLIInstallerService.primaryLinkPath)"
        case (_, .installedCurrent):
            installed = true
            statusText = "Installed for this user: \(CLIInstallerService.fallbackLinkURL.path) (add ~/.local/bin to PATH)"
        case (.blockedByFile, _), (_, .blockedByFile):
            installed = false
            statusText = "Blocked: a non-symlink file occupies the install path."
        case (.installedOther(let destination), _):
            installed = false
            statusText = "Another install already provides \(CLIInstallerService.primaryLinkPath) (\(destination))."
        case (_, .installedOther):
            installed = false
            statusText = "Another user install already provides the command."
        case (.missing, .missing):
            installed = false
            statusText = "Not installed."
        }
    }

    /// Installs to /usr/local/bin (one admin prompt). Falls back to direct
    /// install when already writable (no prompt in that case).
    func install() {
        guard let target, !busy else { return }
        do {
            try CLIInstallerService.install(target: target, linkPath: CLIInstallerService.primaryLinkPath)
            refresh()
            return
        } catch let error as CLIInstallerService.InstallError {
            switch error {
            case .needsAdmin:
                break
            default:
                statusText = error.localizedDescription
                return
            }
        } catch {
            statusText = error.localizedDescription
            return
        }
        busy = true
        Task {
            await runPrivileged(
                shell: CLIInstallerService.privilegedInstallScript(target: target, linkPath: CLIInstallerService.primaryLinkPath),
                prompt: "Runner Control needs administrator rights to install the runner-control command.",
                cancelledText: "Cancelled. Use “Install for current user” for a no-admin install."
            )
            busy = false
            refresh()
        }
    }

    /// Installs to ~/.local/bin without admin rights.
    func installForUser() {
        guard let target, !busy else { return }
        do {
            try CLIInstallerService.install(target: target, linkPath: CLIInstallerService.fallbackLinkURL.path)
        } catch {
            statusText = error.localizedDescription
            return
        }
        refresh()
    }

    /// Removes our links (primary via admin when needed, user directly).
    /// Foreign files and symlinks are never touched.
    func uninstall() {
        guard let target, !busy else { return }
        let primary = CLIInstallerService.status(linkPath: CLIInstallerService.primaryLinkPath, target: target)
        if primary == .installedCurrent,
           !FileManager.default.isWritableFile(atPath: URL(fileURLWithPath: CLIInstallerService.primaryLinkPath).deletingLastPathComponent().path) {
            busy = true
            Task {
                await runPrivileged(
                    shell: CLIInstallerService.privilegedUninstallScript(target: target, linkPath: CLIInstallerService.primaryLinkPath),
                    prompt: "Runner Control needs administrator rights to remove the runner-control command.",
                    cancelledText: "Cancelled."
                )
                try? CLIInstallerService.uninstall(target: target, linkPath: CLIInstallerService.fallbackLinkURL.path)
                busy = false
                refresh()
            }
            return
        }
        try? CLIInstallerService.uninstall(target: target, linkPath: CLIInstallerService.primaryLinkPath)
        try? CLIInstallerService.uninstall(target: target, linkPath: CLIInstallerService.fallbackLinkURL.path)
        refresh()
    }

    /// Runs osascript off-main (the admin prompt blocks until dismissed).
    private func runPrivileged(shell: String, prompt: String, cancelledText: String) async {
        let source = CLIInstallerService.privilegedAppleScript(shell: shell, prompt: prompt)
        let outcome = await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", source]
            let err = Pipe()
            task.standardError = err
            do {
                try task.run()
            } catch {
                return (false, error.localizedDescription)
            }
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let details = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return (false, details)
            }
            return (true, "")
        }.value
        if !outcome.0 {
            if outcome.1.contains("User canceled") {
                statusText = cancelledText
            } else {
                let trimmed = outcome.1.trimmingCharacters(in: .whitespacesAndNewlines)
                statusText = trimmed.isEmpty ? "Privileged operation failed." : trimmed
            }
        }
    }
}
