import ArgumentParser
import Foundation
import RunnerControlCore

/// Destructive-operation confirmations. The GUI always confirms stopping a
/// service and requires a typed name for unregister; the CLI mirrors both:
/// `--yes` (or an interactive TTY prompt) for stops, `--confirm NAME` for
/// unregister. Non-TTY without flags refuses instead of guessing.
public enum Confirmations {
    public static func ensureYes(_ globals: GlobalOptions, message: String) throws {
        if globals.yes { return }
        guard Output.isTTY() else {
            throw CLIFailure(.failed, "\(message)\nRefusing without --yes in non-interactive mode.")
        }
        let answer = Output.readLine(prompt: "\(message)\nContinue? [y/N] ") ?? ""
        guard answer.lowercased() == "y" || answer.lowercased() == "yes" else {
            throw CLIFailure(.failed, "Aborted.")
        }
    }
}

public struct RunnersCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "runners",
        abstract: "List, power, import, and configure local runners.",
        subcommands: [
            RunnersList.self, RunnersShow.self, RunnersOn.self, RunnersOff.self,
            RunnersDiscover.self, RunnersAdd.self, RunnersRemove.self,
            RunnersUnregister.self, RunnersAlias.self, RunnersLoginStart.self,
            RunnersRelink.self, RunnersLogs.self, RunnersGroupAccess.self,
        ]
    )
    public init() {}
}

public struct RunnersList: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "list", abstract: "List catalog runners with local power state.")
    @OptionGroup public var globals: GlobalOptions
    @Flag(name: .long, help: "Refresh GitHub online/busy/labels first (needs sign-in).")
    public var remote: Bool = false
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.throwCatalogError()
        if remote {
            if case .connected = runtime.githubState.connection {
                await action { Runners.Effect.refreshRemote }
            } else {
                Output.warn("Not signed in: showing local state only.")
            }
        }
        if let syncError = runtime.state.remoteSyncError {
            Output.warn("GitHub: \(syncError)")
        }
        let dtos = runtime.state.runners.map(RunnerDTO.init)
        if globals.json {
            Output.json(dtos)
        } else if dtos.isEmpty {
            Output.text("No runners. See `runners discover` and `runners add`.")
        } else {
            for dto in dtos {
                let mark = dto.status == "running" ? "●" : "○"
                Output.text("\(mark) \(dto.displayTitle) [\(dto.status)] \(dto.id)")
            }
        }
    }
}

public struct RunnersShow: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "show", abstract: "Show full detail for one runner.")
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "Service label, local ID, or agent name.")
    public var runner: String
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.throwCatalogError()
        let snapshot = try RunnerMatching.resolve(runner, in: runtime.state.runners)
        let dto = RunnerDTO(snapshot: snapshot)
        if globals.json {
            Output.json(dto)
        } else {
            Output.text(Output.table(rows: showRows(dto)))
            if let remote = dto.remote {
                Output.text("GitHub: \(remote.signature)")
                if !remote.labels.isEmpty {
                    Output.text("Labels: \(remote.labels.joined(separator: ", "))")
                }
            }
            Output.text("Page: \(dto.githubURL)")
        }
    }

    private func showRows(_ dto: RunnerDTO) -> [(String, String)] {
        var rows = [
            ("Title", dto.displayTitle),
            ("Status", dto.status),
            ("ID", dto.id),
            ("Directory", dto.directory),
            ("Service", dto.plist),
            ("Control", dto.controller),
        ]
        if let message = dto.message, !message.isEmpty { rows.append(("Note", message)) }
        if let runAtLoad = dto.runAtLoad { rows.append(("RunAtLoad", runAtLoad ? "on" : "off")) }
        if let login = dto.loginEnabled { rows.append(("Login start", login ? "on" : "off")) }
        if !dto.detail.isEmpty { rows.append(("Scope", dto.detail)) }
        if let agentID = dto.remoteAgentID { rows.append(("Agent ID", String(agentID))) }
        return rows
    }
}

public struct RunnersOn: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "on", abstract: "Enable (start) runners.")
    @OptionGroup public var globals: GlobalOptions
    @Flag(name: .long, help: "Target every catalog runner.")
    public var all: Bool = false
    @Argument(help: "Service labels, local IDs, or agent names.")
    public var runners: [String] = []
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.throwCatalogError()
        let targets = try powerTargets(snapshots: runtime.state.runners, all: all, refs: runners)
        await action { Runners.Effect.setEnabledMany(targets.map(\.id), true) }
        try runtime.throwLastError()
        try runtime.throwCatalogError()
        try emitPowerResult(runtime, enabled: true)
    }

    @MainActor func emitPowerResult(_ runtime: HeadlessRuntime, enabled: Bool) throws {
        let dtos = runtime.state.runners.map(RunnerDTO.init)
        if globals.json {
            Output.json(dtos)
        } else {
            for dto in dtos where dto.status == (enabled ? "running" : "stopped") {
                Output.text("\(dto.displayTitle): \(dto.status)")
            }
        }
    }
}

public struct RunnersOff: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "off",
        abstract: "Disable (stop) runners. Stopping can interrupt a build; confirmation is required."
    )
    @OptionGroup public var globals: GlobalOptions
    @Flag(name: .long, help: "Target every catalog runner.")
    public var all: Bool = false
    @Argument(help: "Service labels, local IDs, or agent names.")
    public var runners: [String] = []
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.throwCatalogError()
        let targets = try powerTargets(snapshots: runtime.state.runners, all: all, refs: runners)
        let warnings = targets.map { Runners.StopConfirmation.message(remote: $0.remote, runnerTitle: $0.definition.displayTitle) }
        try Confirmations.ensureYes(globals, message: warnings.joined(separator: "\n"))
        await action { Runners.Effect.setEnabledMany(targets.map(\.id), false) }
        try runtime.throwLastError()
        try runtime.throwCatalogError()
        if globals.json {
            Output.json(runtime.state.runners.map(RunnerDTO.init))
        } else {
            for target in targets {
                let status = runtime.state.runners.first(where: { $0.id == target.id })?.status.rawValue ?? "?"
                Output.text("\(target.definition.displayTitle): \(status)")
            }
        }
    }
}

func powerTargets(snapshots: [Runners.Snapshot], all: Bool, refs: [String]) throws -> [Runners.Snapshot] {
    if all, !refs.isEmpty {
        throw CLIFailure(.usage, "Pass either --all or explicit runners, not both.")
    }
    if all {
        guard !snapshots.isEmpty else {
            throw CLIFailure(.failed, "No runners in the catalog.")
        }
        return snapshots
    }
    guard !refs.isEmpty else {
        throw CLIFailure(.usage, "Pass at least one runner or --all.")
    }
    return try RunnerMatching.resolveMany(refs, in: snapshots)
}

public struct RunnersDiscover: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "discover",
        abstract: "Find installed runners not yet in the catalog (read-only)."
    )
    @OptionGroup public var globals: GlobalOptions
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.throwCatalogError()
        await action { Runners.Effect.discover }
        let dtos = runtime.state.candidates.map(CandidateDTO.init)
        if globals.json {
            Output.json(dtos)
        } else if dtos.isEmpty {
            Output.text("No new installs found.")
        } else {
            for dto in dtos {
                let flag = dto.isImportable ? "+" : "!"
                Output.text("\(flag) \(dto.directory) \(dto.agentName ?? "")\(dto.issues.isEmpty ? "" : " — " + dto.issues.joined(separator: "; "))")
            }
        }
    }
}

public struct RunnersAdd: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Import a runner folder into the catalog (never changes the existing service)."
    )
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "Runner installation directory.")
    public var path: String
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.throwCatalogError()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        await action { Runners.Effect.importFolder(url) }
        try runtime.throwCatalogError()
        if globals.json {
            Output.json(runtime.state.runners.map(RunnerDTO.init))
        } else {
            Output.text("Imported \(url.path).")
        }
    }
}

public struct RunnersRemove: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove the catalog entry only. Files, GitHub registration, and running services stay."
    )
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "Service label, local ID, or agent name.")
    public var runner: String
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.throwCatalogError()
        let snapshot = try RunnerMatching.resolve(runner, in: runtime.state.runners)
        await action { Runners.Effect.removeFromApp(snapshot.id) }
        // removeFromApp reports "service keeps running" via catalogFailed:
        // surface it as a warning, not a failure, matching the GUI banner.
        if globals.json {
            Output.json(RemoveDTO(runners: runtime.state.runners.map(RunnerDTO.init), note: runtime.state.catalogError))
        } else if let note = runtime.state.catalogError {
            Output.text(note)
        } else {
            Output.text("Removed \(snapshot.definition.displayTitle) from the app.")
        }
    }
}

public struct RunnersUnregister: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "unregister",
        abstract: "Unregister a stopped runner from GitHub. Files and the service manifest stay for re-registration."
    )
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "Service label, local ID, or agent name.")
    public var runner: String
    @Option(name: .long, help: "Typed confirmation: the agent name (same as the GUI dialog).")
    public var confirm: String?
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.requireLogin()
        try runtime.throwCatalogError()
        let snapshot = try RunnerMatching.resolve(runner, in: runtime.state.runners)
        let confirmation = try typedConfirmation(snapshot)
        await action { Runners.Effect.unregister(snapshot.id, confirmation: confirmation) }
        try runtime.throwCatalogError()
        if globals.json {
            Output.json(runtime.state.runners.map(RunnerDTO.init))
        } else {
            Output.text("Unregistered \(snapshot.definition.displayTitle) from GitHub.")
        }
    }

    @MainActor private func typedConfirmation(_ snapshot: Runners.Snapshot) throws -> String {
        if let confirm, !confirm.isEmpty { return confirm }
        guard Output.isTTY() else {
            throw CLIFailure(.usage, "Pass --confirm \"\(snapshot.definition.title)\".")
        }
        let typed = Output.readLine(prompt: "Type the agent name (\(snapshot.definition.title)) to unregister: ") ?? ""
        guard !typed.isEmpty else {
            throw CLIFailure(.failed, "Aborted.")
        }
        return typed
    }
}

public struct RunnersAlias: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "alias", abstract: "Set or clear the display name override.")
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "Service label, local ID, or agent name.")
    public var runner: String
    @Argument(help: "Display name. Omit with --clear.")
    public var name: String?
    @Flag(name: .long, help: "Clear the override and show the registration name.")
    public var clear: Bool = false
    public init() {}

    @MainActor public func run() async throws {
        if clear, name != nil {
            throw CLIFailure(.usage, "Pass either a name or --clear, not both.")
        }
        if !clear, (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIFailure(.usage, "Pass a display name or --clear.")
        }
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.throwCatalogError()
        let snapshot = try RunnerMatching.resolve(runner, in: runtime.state.runners)
        let alias: String? = clear ? nil : name
        await action { Runners.Effect.setAlias(snapshot.id, alias) }
        try runtime.throwCatalogError()
        if globals.json {
            Output.json(runtime.state.runners.map(RunnerDTO.init))
        } else {
            Output.text(clear ? "Alias cleared." : "Alias set.")
        }
    }
}

public struct RunnersLoginStart: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "login-start",
        abstract: "Set the CI autostart (RunAtLoad) policy of one runner's service."
    )
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "Service label, local ID, or agent name.")
    public var runner: String
    @Argument(help: "on or off.")
    public var state: String
    public init() {}

    @MainActor public func run() async throws {
        let value: Bool
        switch state.lowercased() {
        case "on": value = true
        case "off": value = false
        default: throw CLIFailure(.usage, "State must be on or off.")
        }
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.throwCatalogError()
        let snapshot = try RunnerMatching.resolve(runner, in: runtime.state.runners)
        await action { Runners.Effect.setRunAtLoad(snapshot.id, value) }
        try runtime.throwCatalogError()
        if globals.json {
            Output.json(runtime.state.runners.map(RunnerDTO.init))
        } else {
            Output.text("\(snapshot.definition.displayTitle): login start \(value ? "on" : "off").")
        }
    }
}

public struct RunnersRelink: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "relink",
        abstract: "Point a catalog entry at a moved installation directory."
    )
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "Service label, local ID, or agent name.")
    public var runner: String
    @Argument(help: "New installation directory.")
    public var path: String
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.throwCatalogError()
        let snapshot = try RunnerMatching.resolve(runner, in: runtime.state.runners)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        await action { Runners.Effect.relinkDirectory(snapshot.id, url) }
        try runtime.throwCatalogError()
        if globals.json {
            Output.json(runtime.state.runners.map(RunnerDTO.init))
        } else {
            Output.text("Relinked to \(url.path).")
        }
    }
}

public struct RunnersLogs: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show the redacted log tail (same preview as the GUI)."
    )
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "Service label, local ID, or agent name.")
    public var runner: String
    @Flag(name: .long, help: "List resolved log file paths instead of the tail.")
    public var files: Bool = false
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.throwCatalogError()
        let snapshot = try RunnerMatching.resolve(runner, in: runtime.state.runners)
        if files {
            let paths = RunnerDiagnostics.logFiles(definition: snapshot.definition).map(\.path)
            if globals.json {
                Output.json(paths)
            } else {
                paths.forEach(Output.text)
            }
            return
        }
        await action { Runners.Effect.loadLog(snapshot.id) }
        try runtime.throwCatalogError()
        let title = runtime.state.logPreviewTitle ?? snapshot.definition.displayTitle
        let excerpt = runtime.state.logPreview ?? "No log output yet."
        if globals.json {
            Output.json(["title": title, "excerpt": excerpt])
        } else {
            Output.text("=== \(title) ===")
            Output.text(excerpt)
        }
    }
}

public struct RunnersGroupAccess: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "group-access",
        abstract: "Show or apply repository access for an organization runner's dedicated group."
    )
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "Service label, local ID, or agent name.")
    public var runner: String
    @Option(name: .long, help: "Comma-separated repository IDs to grant (applies instead of showing; pass an empty value to clear all access).")
    public var set: String?
    @Flag(name: .long, help: "Confirm adopting a pre-existing group as this Mac's dedicated group.")
    public var takeover: Bool = false
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.requireLogin()
        try runtime.throwCatalogError()
        let snapshot = try RunnerMatching.resolve(runner, in: runtime.state.runners)
        let allowTakeover = takeover
        await action { Runners.Effect.loadGroupAccess(snapshot.id) }
        guard let access = runtime.state.groupAccess[snapshot.id] else {
            throw CLIFailure(.failed, runtime.state.catalogError ?? "Group access unavailable.")
        }
        if let error = access.error {
            throw CLIFailure(.failed, error)
        }
        guard let set else {
            if globals.json {
                Output.json(GroupAccessDTO(access))
            } else {
                Output.text(Output.table(rows: [
                    ("Group", access.group.map { "\($0.name) (id \($0.id), \($0.visibility))" } ?? "—"),
                    ("Owned by this Mac", access.owned ? "yes" : "no"),
                    ("Repositories", access.repoIDs.map(String.init).sorted().joined(separator: ", ")),
                ]))
            }
            return
        }
        // Explicit --set always applies, even when empty (clear all access).
        // Only an omitted flag shows the current state (handled above).
        let wanted = try Parse.idList(set, flag: "--set")
        guard let groupID = access.group?.id else {
            throw CLIFailure(.failed, "No dedicated group to apply to.")
        }
        if !access.owned, !allowTakeover {
            throw CLIFailure(.failed, "Group \(groupID) is not this Mac's dedicated group. Pass --takeover to explicitly adopt it.")
        }
        let confirmMessage = wanted.isEmpty
            ? "Clear all repository access for group \(groupID)?"
            : "Apply repository access \(wanted.sorted().map(String.init).joined(separator: ", ")) to group \(groupID)?"
        try Confirmations.ensureYes(globals, message: confirmMessage)
        await action { Runners.Effect.applyGroupAccess(snapshot.id, groupID: groupID, repositories: Set(wanted), allowTakeover: allowTakeover) }
        try runtime.throwCatalogError()
        guard let updated = runtime.state.groupAccess[snapshot.id], updated.error == nil else {
            throw CLIFailure(.failed, runtime.state.groupAccess[snapshot.id]?.error ?? runtime.state.catalogError ?? "Apply failed.")
        }
        if globals.json {
            Output.json(GroupAccessDTO(updated))
        } else {
            Output.text("Applied.")
        }
    }
}
