import AppKit
import ArgumentParser
import Foundation
import RunnerControlCore

/// Global flags shared by every command.
public struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit exactly one JSON document on stdout.")
    public var json: Bool = false

    @Flag(name: [.long, .short], help: "Confirm a mutating operation without prompting.")
    public var yes: Bool = false

    public init() {}
    public init(json: Bool, yes: Bool) {
        self.json = json
        self.yes = yes
    }
}

public struct AuthCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "GitHub sign-in and App installations (session is shared with the GUI app).",
        subcommands: [AuthStatus.self, AuthLogin.self, AuthLogout.self, AuthInstallations.self, AuthInstallation.self]
    )
    public init() {}
}

public struct AuthStatus: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the shared GitHub session.")
    @OptionGroup public var globals: GlobalOptions
    public init() {}
    public init(globals: GlobalOptions) { self.globals = globals }

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        let dto = AuthStatusDTO(state: runtime.githubState)
        if globals.json {
            Output.json(dto)
        } else if dto.connected, let username = dto.username {
            Output.text("Signed in as @\(username) (\(dto.serverHost))")
            Output.text("Installations: \(dto.installations.count), selected: \(dto.selectedInstallationID.map(String.init) ?? "—")")
            if let syncError = dto.syncError { Output.text("Sync: \(syncError)") }
        } else {
            Output.text("Not signed in (\(dto.phase)). Run `runner-control auth login`.")
        }
    }
}

public struct AuthLogin: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "login", abstract: "Sign in with GitHub Device Flow (same as the GUI).")
    @OptionGroup public var globals: GlobalOptions
    @Option(name: .long, help: "GitHub host (default github.com).")
    public var host: String?
    @Option(name: .long, help: "Seconds to wait for browser approval (default 900).")
    public var timeout: Int?
    @Flag(name: .long, help: "Open the verification page in the default browser.")
    public var open: Bool = false
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        if case .connected(let username, let host) = runtime.githubState.connection {
            if globals.json {
                Output.json(AuthStatusDTO(state: runtime.githubState))
            } else {
                Output.text("Already signed in as @\(username) (\(host)).")
            }
            return
        }
        let serverHost = host
        await action { GitHubAuth.Effect.beginLogin(serverHost: serverHost) }
        if let error = loginFailedMessage(runtime) {
            throw CLIFailure(.failed, error)
        }
        let shouldOpen = open
        let outcome = await runtime.waitForLogin(timeout: timeout.map(TimeInterval.init)) { userCode, uri in
            Output.warn("Open \(uri.absoluteString) and enter code: \(userCode)")
            if shouldOpen {
                NSWorkspace.shared.open(uri)
            }
        }
        switch outcome {
        case .connected(let username, let host):
            await runtime.restore()
            if globals.json {
                Output.json(AuthStatusDTO(state: runtime.githubState))
            } else {
                Output.text("Signed in as @\(username) (\(host)).")
            }
        case .failed(let message):
            throw CLIFailure(.failed, message)
        }
    }

    @MainActor private func loginFailedMessage(_ runtime: HeadlessRuntime) -> String? {
        if case .failed(let message, _) = runtime.githubState.connection {
            return message
        }
        return nil
    }
}

public struct AuthLogout: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "logout",
        abstract: "Sign out on this Mac: deletes local tokens, keeps CI services running (same as the GUI)."
    )
    @OptionGroup public var globals: GlobalOptions
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        await action { GitHubAuth.Effect.logout }
        if globals.json {
            Output.json(EmptyPayload())
        } else {
            Output.text("Signed out. Local tokens deleted; running services are untouched.")
            Output.text("To revoke the grant on GitHub too: https://github.com/settings/connections/applications")
        }
    }
}

public struct AuthInstallations: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "installations",
        abstract: "List GitHub App installations available to the signed-in user."
    )
    @OptionGroup public var globals: GlobalOptions
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.requireLogin()
        await action { GitHubAuth.Effect.refreshInstallations }
        if let error = runtime.githubState.syncError {
            throw CLIFailure(.failed, error)
        }
        let list = runtime.githubState.installations.map(InstallationDTO.init)
        if globals.json {
            Output.json(list)
        } else if list.isEmpty {
            Output.text("No installations. Grant access at https://github.com/settings/installations")
        } else {
            for item in list {
                Output.text("\(item.id)\t\(item.account) (\(item.accountType))")
            }
        }
    }
}

public struct AuthInstallation: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "installation",
        abstract: "Select an installation and list its repositories."
    )
    @OptionGroup public var globals: GlobalOptions
    @Argument(help: "Installation ID from `auth installations`.")
    public var id: Int64
    public init() {}

    @MainActor public func run() async throws {
        let runtime = await HeadlessRuntime.boot()
        await runtime.restore()
        try runtime.requireLogin()
        await action { GitHubAuth.Effect.refreshInstallations }
        let installationID = id
        guard runtime.githubState.installations.contains(where: { $0.id == installationID }) else {
            throw CLIFailure(.failed, "Unknown installation \(installationID). See `auth installations`.")
        }
        await action { GitHubAuth.Effect.selectInstallation(installationID) }
        if let error = runtime.githubState.syncError {
            throw CLIFailure(.failed, error)
        }
        let repos = runtime.githubState.repositories.map(RepositoryDTO.init)
        if globals.json {
            Output.json(repos)
        } else if repos.isEmpty {
            Output.text("No repositories visible for installation \(id).")
        } else {
            for repo in repos {
                Output.text("\(repo.id)\t\(repo.fullName)\t\(repo.isPrivate ? "private" : "public")")
            }
        }
    }
}
