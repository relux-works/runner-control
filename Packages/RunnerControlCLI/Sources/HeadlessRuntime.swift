import Foundation
import RunnerControlCore

/// Boots the exact Relux runtime the GUI uses (`RunnerRuntime.make`) and
/// drives it without UI. Every CLI command dispatches the same effects the
/// GUI dispatches and reads the same states — parity by construction, not
/// by reimplementation. One boot per process: `Relux.shared` forbids a
/// second runtime instance.
@MainActor
public final class HeadlessRuntime {
    public let state: Runners.State
    public let githubState: GitHubAuth.State
    public let registrationState: RunnerRegistration.State

    private init(state: Runners.State, githubState: GitHubAuth.State, registrationState: RunnerRegistration.State) {
        self.state = state
        self.githubState = githubState
        self.registrationState = registrationState
    }

    /// Production boot: real launchd service, real Keychain (shared with
    /// the GUI as long as this binary is Apple-signed — see
    /// SecurityKeychainBackend), shared session identity domain,
    /// CLI-resolved GitHub App config.
    public static func boot(executablePath: String = CLIInstallerService.currentExecutableURL().path) async -> HeadlessRuntime {
        await boot(
            service: nil,
            transport: URLSessionGitHubTransport(),
            store: GitHubKeychainStore(),
            identities: CLIConfig.sessionIdentityStore(),
            configProvider: CLIConfig.configProvider(executablePath: executablePath)
        )
    }

    /// Testable boot with explicit dependencies. Production passes nil
    /// service for the catalog-backed launchd service.
    public static func boot(
        service: (any RunnerServicing)?,
        transport: any GitHubHTTPTransport,
        store: any GitHubCredentialStoring,
        identities: any GitHubSessionIdentityStoring,
        configProvider: (@Sendable (String?) throws -> GitHubAuth.AppConfig)?
    ) async -> HeadlessRuntime {
        let state = Runners.State(definitions: [])
        let githubState = GitHubAuth.State()
        let registrationState = RunnerRegistration.State()
        _ = await RunnerRuntime.make(
            state: state, githubState: githubState, registrationState: registrationState,
            service: service, transport: transport, store: store,
            identities: identities, configProvider: configProvider
        )
        return HeadlessRuntime(state: state, githubState: githubState, registrationState: registrationState)
    }

    /// Mirrors app launch: restore the shared session, then migrate and
    /// read the shared catalog. Read-only w.r.t. services: never starts
    /// or stops CI, exactly like the GUI.
    public func restore() async {
        await action { GitHubAuth.Effect.restoreSession }
        await action { Runners.Effect.loadCatalog }
    }

    /// Terminal conditions for the Device Flow login started with
    /// `.beginLogin`. The flow polls GitHub in the background; the CLI
    /// watches the connection phase instead of reimplementing polling.
    public enum LoginOutcome: Sendable {
        case connected(username: String, serverHost: String)
        case failed(message: String)
    }

    /// Waits for the in-flight login to settle. Calls `onCode` exactly once
    /// with the user code and verification URL the user must open (the same
    /// values the GUI renders). Timeout defaults to the code's own expiry.
    public func waitForLogin(
        timeout: TimeInterval? = nil,
        onCode: @Sendable (String, URL) -> Void
    ) async -> LoginOutcome {
        let deadline = Date().addingTimeInterval(timeout ?? 900)
        var announced = false
        var announcedCode = ""
        while Date() < deadline {
            switch githubState.connection {
            case .connected(let username, let host):
                return .connected(username: username, serverHost: host)
            case .failed(let message, _):
                return .failed(message: message)
            case .awaitingUser(let userCode, let uri, _, _):
                if !announced || announcedCode != userCode {
                    announced = true
                    announcedCode = userCode
                    onCode(userCode, uri)
                }
                // The flow itself fails the connection when the code expires.
            case .disconnected:
                return .failed(message: "Login ended before completion.")
            case .requestingCode, .verifyingAccount, .verifyingInstallations:
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await action { GitHubAuth.Effect.cancelLogin }
        return .failed(message: "Timed out waiting for GitHub approval.")
    }

    /// Throws `needsLogin` when no shared session is active. Commands that
    /// require GitHub call this before dispatching, so harnesses get a
    /// stable exit code instead of parsing error text.
    public func requireLogin() throws {
        if case .connected = githubState.connection { return }
        throw CLIFailure(.needsLogin, "Not signed in. Run `runner-control auth login` (or sign in the GUI app — the session is shared).")
    }

    /// Throws the pending catalog error, if any.
    public func throwCatalogError() throws {
        if let error = state.catalogError {
            throw CLIFailure(.failed, error)
        }
    }

    /// Throws the pending power-operation error, if any.
    public func throwLastError() throws {
        if let error = state.lastError {
            throw CLIFailure(.failed, error)
        }
    }
}
