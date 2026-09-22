import Foundation
import Relux
import OSLog
@MainActor public enum RunnerRuntime {
    public static func make(state: Runners.State, service: any RunnerServicing = LaunchAgentService()) async -> Relux {
        let runtime = await Relux(logger: RuntimeLogger())
        let flow = await Runners.Flow(service: service, dispatcher: runtime.dispatcher)
        runtime.register(Runners.Module(state: state, flow: flow))
        return runtime
    }

    public static func make(
        state: Runners.State,
        githubState: GitHubAuth.State,
        service: (any RunnerServicing)? = nil,
        transport: any GitHubHTTPTransport = URLSessionGitHubTransport(),
        store: any GitHubCredentialStoring = GitHubKeychainStore(),
        identities: (any GitHubSessionIdentityStoring)? = nil,
        configProvider: (@Sendable (String?) throws -> GitHubAuth.AppConfig)? = nil
    ) async -> Relux {
        let registrationState = await MainActor.run { RunnerRegistration.State() }
        return await make(state: state, githubState: githubState, registrationState: registrationState, service: service, transport: transport, store: store, identities: identities, configProvider: configProvider)
    }

    public static func make(
        state: Runners.State,
        githubState: GitHubAuth.State,
        registrationState: RunnerRegistration.State,
        service: (any RunnerServicing)? = nil,
        transport: any GitHubHTTPTransport = URLSessionGitHubTransport(),
        store: any GitHubCredentialStoring = GitHubKeychainStore(),
        identities: (any GitHubSessionIdentityStoring)? = nil,
        configProvider: (@Sendable (String?) throws -> GitHubAuth.AppConfig)? = nil
    ) async -> Relux {
        let runtime = await Relux(logger: RuntimeLogger())
        // One shared installer for registration and catalog unregister/recovery:
        // installer mutations serialize app-wide until side effects settle.
        // Ordinary start/stop of installed runners never takes this lease.
        let installer = RunnerInstallerService()
        let catalog = RunnerCatalogStore()
        let resolvedService: any RunnerServicing = service ?? LaunchAgentService(catalog: catalog)
        // Overridable so the CLI shares the app's session identity file and
        // GitHub App client_id without a host bundle Info.plist. Defaults
        // preserve GUI behavior exactly.
        let resolvedIdentities = identities ?? UserDefaultsGitHubSessionIdentityStore()
        let runnerAPI = GitHubRunnerAPIClient(transport: transport)
        let refresher = GitHubTokenRefresh(transport: transport, store: store)
        let flow = await Runners.Flow(
            service: resolvedService, catalog: catalog, installer: installer,
            api: runnerAPI, userStore: store, identities: resolvedIdentities,
            refresher: refresher, configProvider: configProvider, dispatcher: runtime.dispatcher
        )
        runtime.register(Runners.Module(state: state, flow: flow))
        let deviceFlow = GitHubDeviceFlow(transport: transport)
        let api = GitHubAPIClient(transport: transport)
        let githubFlow = await GitHubAuth.Flow(deviceFlow: deviceFlow, api: api, refresher: refresher, store: store, identityStore: resolvedIdentities, configProvider: configProvider, dispatcher: runtime.dispatcher)
        runtime.register(GitHubAuth.Module(state: githubState, flow: githubFlow))
        let registrationTokens = RunnerRegistrationTokenStore()
        let registrationFlow = await RunnerRegistration.Flow(
            api: runnerAPI, installer: installer, registrationTokens: registrationTokens,
            userStore: store, identityStore: resolvedIdentities,
            refresher: refresher, configProvider: configProvider, dispatcher: runtime.dispatcher
        )
        runtime.register(RunnerRegistration.Module(state: registrationState, flow: registrationFlow))
        return runtime
    }
}
struct RuntimeLogger: Relux.Logger {
    func logAction(_ action: Relux.EnumReflectable, result: Relux.ActionResult?, startTimeInMillis: Int, privacy: Relux.OSLogPrivacy, fileID: String, functionName: String, lineNumber: Int) {
        Logger(subsystem: "works.relux.runnercontrol", category: "state").debug("State event: \(String(describing: type(of: action)), privacy: .public)")
    }
}
