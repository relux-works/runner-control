import ArgumentParser
import Foundation
import RunnerControlCore

public struct RegisterCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "register",
        abstract: "Create and register a runner (same wizard steps as the GUI: group, download, install, register, service)."
    )
    @OptionGroup public var globals: GlobalOptions
    @Option(name: .long, help: "Organization scope (mutually exclusive with --repo).")
    public var org: String?
    @Option(name: .long, help: "Repository scope as owner/name (mutually exclusive with --org).")
    public var repo: String?
    @Option(name: .long, help: "Runner name (default: this Mac's name, like the GUI prefill).")
    public var name: String?
    @Option(name: .long, help: "Comma-separated labels (default: self-hosted,macOS — same field as the GUI wizard).")
    public var label: String = "self-hosted, macOS"
    @Option(name: .long, help: "Install directory name under ~/Library/GitHubActions (default: derived from the name).")
    public var dir: String?
    @Option(name: .long, help: "Work folder name (default _work).")
    public var work: String = "_work"
    @Option(name: .long, help: "Dedicated per-Mac group name, org scope (default: RunnerControl-<Mac>).")
    public var group: String?
    @Option(name: .long, help: "Comma-separated repository IDs the dedicated group may access.")
    public var repoID: String?
    @Flag(name: .long, help: "Confirm that group mutations apply only to the resolved dedicated group.")
    public var allowGroupMutation: Bool = false
    @Flag(name: .long, help: "Confirm adopting a pre-existing group as this Mac's dedicated group.")
    public var allowTakeover: Bool = false
    @Flag(name: .long, help: "Confirm replacing an existing GitHub registration with the same name.")
    public var allowReplace: Bool = false
    @Flag(name: .long, help: "Re-sync labels via API after registration (the wizard's “apply labels” button).")
    public var syncLabels: Bool = false
    public init() {}

    @MainActor public func run() async throws {
        let draft = try makeDraft()
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.requireLogin()
        try Confirmations.ensureYes(
            globals,
            message: "Register runner “\(draft.runnerName)” (\(draft.scope.detail)) at ~/Library/GitHubActions/\(draft.installDirName)?"
        )
        await action { RunnerRegistration.Effect.beginDraft(draft) }
        try throwRegistrationError(runtime, step: "beginDraft")

        if case .organization = draft.scope {
            Output.warn("Resolving dedicated group…")
            await action { RunnerRegistration.Effect.resolveGroup }
            try throwRegistrationError(runtime, step: "resolveGroup")
        }
        Output.warn("Preparing download…")
        await action { RunnerRegistration.Effect.prepareDownload }
        try throwRegistrationError(runtime, step: "prepareDownload")
        if let filename = runtime.registrationState.asset?.filename {
            Output.warn("Downloading \(filename)…")
        }
        await action { RunnerRegistration.Effect.downloadAndInstall }
        try throwRegistrationError(runtime, step: "downloadAndInstall")
        Output.warn("Registering with GitHub…")
        await action { RunnerRegistration.Effect.registerRunner }
        try throwRegistrationError(runtime, step: "registerRunner")
        Output.warn("Setting up the service (login start off)…")
        await action { RunnerRegistration.Effect.setupService }
        try throwRegistrationError(runtime, step: "setupService")
        if !draft.selectedRepositoryIDs.isEmpty {
            guard let groupID = runtime.registrationState.group?.id else {
                throw CLIFailure(.failed, "Repository access needs an organization scope with a resolved group.")
            }
            Output.warn("Applying repository access…")
            await action { RunnerRegistration.Effect.applyRepositoryAccess(groupID: groupID, repositories: draft.selectedRepositoryIDs) }
            try throwRegistrationError(runtime, step: "applyRepositoryAccess")
        }
        if syncLabels {
            Output.warn("Syncing labels…")
            await action { RunnerRegistration.Effect.applyLabels(draft.labels) }
            try throwRegistrationError(runtime, step: "applyLabels")
        }
        // The new service joins the same catalog the GUI reads; refresh the
        // local list so the result reflects the just-registered runner.
        await action { Runners.Effect.loadCatalog }
        let dto = RegistrationDTO(state: runtime.registrationState)
        if globals.json {
            Output.json(dto)
        } else {
            Output.text("Registered \(draft.runnerName) → \(dto.installPath ?? ""). Enabling stays a separate action: `runners on`.")
        }
    }

    @MainActor private func throwRegistrationError(_ runtime: HeadlessRuntime, step: String) throws {
        if let permission = runtime.registrationState.permissionError {
            throw CLIFailure(.failed, permission)
        }
        if let error = runtime.registrationState.error {
            if let failedStep = runtime.registrationState.failedStep {
                throw CLIFailure(.failed, "\(failedStep): \(error)")
            }
            throw CLIFailure(.failed, error)
        }
    }

    func makeDraft() throws -> RunnerRegistration.Draft {
        let orgName = (org ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let repoValue = (repo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (orgName.isEmpty, repoValue.isEmpty) {
        case (true, true):
            throw CLIFailure(.usage, "Pass --org ORG or --repo owner/name.")
        case (false, false):
            throw CLIFailure(.usage, "Pass either --org or --repo, not both.")
        case (false, true):
            break
        case (true, false):
            let parts = repoValue.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                throw CLIFailure(.usage, "--repo must spell owner/name.")
            }
        }
        let macName = Host.current().localizedName ?? "Mac"
        let runnerName = (name ?? macName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runnerName.isEmpty else {
            throw CLIFailure(.usage, "Runner name must not be empty.")
        }
        let repoParts = repoValue.split(separator: "/", omittingEmptySubsequences: true)
        return RunnerRegistration.DraftSnapshot.make(
            organizationScope: !orgName.isEmpty,
            org: orgName,
            repoOwner: repoParts.count == 2 ? String(repoParts[0]) : "",
            repoName: repoParts.count == 2 ? String(repoParts[1]) : "",
            runnerName: runnerName,
            labelsText: label,
            installDirName: dir ?? Self.defaultDirName(runnerName: runnerName),
            workFolder: work,
            groupName: group ?? RunnerRegistration.Draft.defaultGroupName(hostName: macName),
            selectedRepositoryIDs: Set(try Parse.idList(repoID ?? "", flag: "--repo-id")),
            allowGroupMutation: allowGroupMutation,
            allowGroupTakeover: allowTakeover,
            allowReplace: allowReplace
        )
    }

    /// Default install directory: the GUI leaves the field empty and lets
    /// gates validate; the CLI derives a valid spelling from the name so
    /// one-shot harness runs need no extra flag. Same validity rules.
    static func defaultDirName(runnerName: String) -> String {
        let cleaned = runnerName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "runner" : cleaned
    }
}
