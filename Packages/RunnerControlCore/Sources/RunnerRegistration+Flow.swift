import Foundation
import Relux

extension RunnerRegistration {
    public protocol IFlow: Relux.Flow {}

    public actor Flow {
        public let dispatcher: Relux.Dispatcher
        private let api: GitHubRunnerAPIClient
        private let installer: RunnerInstallerService
        private let registrationTokens: any RunnerRegistrationTokenStoring
        private let userStore: any GitHubCredentialStoring
        private let identities: any GitHubSessionIdentityStoring
        private let refresher: GitHubTokenRefresh
        private let configProvider: @Sendable (String?) throws -> GitHubAuth.AppConfig
        private let now: @Sendable () -> Date

        private var generation = 0
        /// Operation owner: the generation that holds the busy lock, or nil
        /// when idle. Every step sets it to its starting generation before
        /// its first await; every success/failure/cancel exit clears it only
        /// when the exiting generation still owns it. A stale generation
        /// never mutates a newer owner's lock, step, or failure state.
        /// Abandoning a generation releases this UI lock so the new draft can
        /// proceed, but never releases the installer-wide lease: a live side
        /// effect keeps owning the installer until it settles, and any second
        /// mutation meanwhile is refused as installer-busy.
        private var workingOwner: Int?
        private var workingStep: String?
        private var draft: Draft?
        private var group: RunnerGroup?
        private var asset: DownloadAsset?
        private var installPath: String?
        private var runnerID: Int64?
        private var failedStep: String?
        private var pendingRepositoryIDs: Set<Int64>?
        private var pendingTargetGroupID: Int64?
        private var pendingLabels: [String]?
        /// Authenticated server the cached progress is bound to. A session
        /// change invalidates server-bound caches before any reuse, so a
        /// group/runner ID from one server never authorizes writes on another.
        private var boundServerHost: String?

        public init(
            api: GitHubRunnerAPIClient,
            installer: RunnerInstallerService,
            registrationTokens: any RunnerRegistrationTokenStoring,
            userStore: any GitHubCredentialStoring,
            identityStore: any GitHubSessionIdentityStoring,
            refresher: GitHubTokenRefresh,
            configProvider: (@Sendable (String?) throws -> GitHubAuth.AppConfig)? = nil,
            now: (@Sendable () -> Date)? = nil,
            dispatcher: Relux.Dispatcher? = nil
        ) async {
            self.api = api
            self.installer = installer
            self.registrationTokens = registrationTokens
            self.userStore = userStore
            self.identities = identityStore
            self.refresher = refresher
            self.configProvider = configProvider ?? { host in
                try GitHubAuth.AppConfig.current(serverHost: host ?? "github.com")
            }
            self.now = now ?? Date.init
            self.dispatcher = if let dispatcher { dispatcher } else { await Self.defaultDispatcher }
        }

        /// Deterministic LaunchAgent label for a draft. Always carries the
        /// `actions.runner.` prefix discovery requires.
        public nonisolated static func serviceLabel(draft: Draft) -> String {
            let scope = draft.scope.detail.replacingOccurrences(of: "/", with: "-")
            let raw = "actions.runner.\(scope).\(draft.installDirName)"
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
            return raw.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        }

        public nonisolated static func tokenScopeKey(draft: Draft) -> String {
            "\(draft.scope.scopeKey):\(draft.installDirName)"
        }
    }
}

/// Authenticated user token for wizard API calls. Never logged.
private struct FlowUserToken: Sendable {
    let config: GitHubAuth.AppConfig
    let token: String
    let identity: GitHubSessionIdentity
}

extension RunnerRegistration.Flow: RunnerRegistration.IFlow {
    public func apply(_ effect: any Relux.Effect) async -> Relux.ActionResult {
        guard let effect = effect as? RunnerRegistration.Effect else { return .success }
        switch effect {
        case .beginDraft(let draft): await beginDraft(draft)
        case .updateDraft(let draft): await updateDraft(draft)
        case .resolveGroup: await resolveGroup()
        case .prepareDownload: await prepareDownload()
        case .downloadAndInstall: await downloadAndInstall()
        case .registerRunner: await registerRunner()
        case .setupService: await setupService()
        case .applyRepositoryAccess(let groupID, let ids): await applyRepositoryAccess(groupID: groupID, ids: ids)
        case .applyLabels(let labels): await applyLabels(labels)
        case .retry: await retry()
        case .cancel: await cancel()
        case .reset: await reset()
        case .dismissPermission: await action { RunnerRegistration.Action.permissionDismissed }
        }
        return .success
    }

    private func isStale(_ gen: Int) -> Bool { generation != gen }

    // MARK: - Draft

    private func beginDraft(_ draft: RunnerRegistration.Draft) async {
        do {
            try RunnerRegistration.Gates.validateDraft(draft)
        } catch {
            await action { RunnerRegistration.Action.failed(message: error.localizedDescription, step: "beginDraft") }
            return
        }
        // A new draft abandons any in-flight completion: the old operation's
        // success must never be attributed to the new draft. Already-started
        // filesystem side effects keep the installer-wide lease until they
        // settle; only their completion ownership is revoked via the
        // generation bump, and the UI lock is released for the new draft.
        let abandoned = workingOwner != nil
        if abandoned {
            generation += 1
            workingOwner = nil
            workingStep = nil
        }
        self.draft = draft
        group = nil
        asset = nil
        installPath = nil
        runnerID = nil
        failedStep = nil
        pendingRepositoryIDs = nil
        pendingTargetGroupID = nil
        pendingLabels = nil
        boundServerHost = nil
        await action { RunnerRegistration.Action.draftBegan(draft) }
        if abandoned {
            await action { RunnerRegistration.Action.cancelled }
        }
    }

    private func updateDraft(_ draft: RunnerRegistration.Draft) async {
        do {
            try RunnerRegistration.Gates.validateDraft(draft)
        } catch {
            await action { RunnerRegistration.Action.failed(message: error.localizedDescription, step: "updateDraft") }
            return
        }
        // Identity edits while working abandon the in-flight operation via
        // the generation bump. Selections stay editable without cancelling
        // unrelated steps — except the mutation they feed: a labels edit
        // abandons in-flight applyLabels and a repository edit abandons
        // in-flight applyRepositoryAccess, so an older completion can never
        // overwrite the newer visible selection or report it as applied.
        // Stale completions observe the bump at their next await boundary
        // and emit nothing.
        var abandoned = false
        if let old = self.draft {
            if workingOwner != nil, shouldAbandonInFlight(old: old, new: draft) {
                generation += 1
                workingOwner = nil
                workingStep = nil
                abandoned = true
            }
            invalidateProgress(old: old, new: draft)
        }
        self.draft = draft
        await action { RunnerRegistration.Action.draftUpdated(draft) }
        if abandoned {
            await action { RunnerRegistration.Action.cancelled }
        }
    }

    /// Invalidates cached success-progress bound to the changed identity
    /// fields. Scope/install/name/group/work-folder edits never reuse
    /// another registration's evidence; editable selections re-target pending
    /// retries to the visible values instead. Mirrors the reducer's
    /// invalidation. Group is part of the config identity (`--runnergroup`):
    /// a group edit drops registration evidence as well, so the old group's
    /// configuration is never claimed as the new draft's success.
    private func invalidateProgress(old: RunnerRegistration.Draft, new: RunnerRegistration.Draft) {
        if old.scope != new.scope {
            group = nil
            asset = nil
            installPath = nil
            runnerID = nil
            pendingRepositoryIDs = nil
            pendingTargetGroupID = nil
            pendingLabels = nil
            failedStep = nil
            return
        }
        if old.installDirName != new.installDirName {
            installPath = nil
            runnerID = nil
            pendingLabels = nil
            if ["downloadAndInstall", "registerRunner", "setupService", "applyLabels"].contains(failedStep ?? "") {
                failedStep = nil
            }
        }
        let oldName = old.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = new.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldName != newName {
            runnerID = nil
            pendingLabels = nil
            if ["registerRunner", "setupService", "applyLabels"].contains(failedStep ?? "") {
                failedStep = nil
            }
        }
        let oldIsOrg: Bool = if case .organization = old.scope { true } else { false }
        let newIsOrg: Bool = if case .organization = new.scope { true } else { false }
        if oldIsOrg || newIsOrg {
            let oldGroup = old.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            let newGroup = new.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            if oldGroup != newGroup {
                group = nil
                runnerID = nil
                pendingRepositoryIDs = nil
                pendingTargetGroupID = nil
                pendingLabels = nil
                if ["resolveGroup", "applyRepositoryAccess", "registerRunner", "setupService", "applyLabels"]
                    .contains(failedStep ?? "") {
                    failedStep = nil
                }
            }
        }
        if old.workFolder != new.workFolder {
            runnerID = nil
            pendingLabels = nil
            if ["registerRunner", "setupService", "applyLabels"].contains(failedStep ?? "") {
                failedStep = nil
            }
        }
        // Editable selections stay live: a retry after an edit applies the
        // visible values, never the stale attempt's.
        if old.labels != new.labels, !new.labels.isEmpty {
            pendingLabels = new.labels
        }
        if old.selectedRepositoryIDs != new.selectedRepositoryIDs {
            pendingRepositoryIDs = new.selectedRepositoryIDs
        }
    }

    /// True when an edit must abandon the in-flight step: any identity
    /// change, plus a selection change for the mutation it feeds.
    private func shouldAbandonInFlight(old: RunnerRegistration.Draft, new: RunnerRegistration.Draft) -> Bool {
        if RunnerRegistration.Gates.identityFieldsChanged(old: old, new: new) { return true }
        if workingStep == "applyLabels", old.labels != new.labels { return true }
        if workingStep == "applyRepositoryAccess", old.selectedRepositoryIDs != new.selectedRepositoryIDs {
            return true
        }
        return false
    }

    // MARK: - Auth

    private func currentUserToken(generation gen: Int) async throws -> FlowUserToken {
        guard let identity = await identities.load() else {
            throw RunnerRegistration.RegistrationError.notAuthenticated
        }
        let config = try configProvider(identity.serverHost)
        guard var record = await userStore.load(
            serverHost: identity.serverHost, userID: identity.userID, clientID: identity.clientID
        ) else {
            throw RunnerRegistration.RegistrationError.notAuthenticated
        }
        guard !isStale(gen) else { throw CancellationError() }
        if GitHubTokenRefresh.isExpiringSoon(record, now: now()) {
            do {
                record = try await refresher.refresh(config: config, userID: identity.userID, current: record)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GitHubAuth.AuthError {
                switch error {
                case .revoked, .unauthorized, .tokenRefreshFailed:
                    throw RunnerRegistration.RegistrationError.unauthorized
                default:
                    break
                }
            }
            guard !isStale(gen) else { throw CancellationError() }
        }
        return FlowUserToken(config: config, token: record.accessToken, identity: identity)
    }

    /// Binds cached progress to the authenticated server. When the session
    /// server changes between steps, server-bound caches (group, asset,
    /// runner ID, pendings) are dropped before any reuse, so an ID from one
    /// server never authorizes writes on another. Returns false when the
    /// binding changed and the caller must re-resolve instead of reusing.
    @discardableResult
    private func syncServerBinding(_ host: String) -> Bool {
        let normalized = RunnerRegistration.OperationIdentity.normalizeServerHost(host)
        if let bound = boundServerHost,
           RunnerRegistration.OperationIdentity.normalizeServerHost(bound) == normalized {
            return true
        }
        if boundServerHost != nil {
            group = nil
            asset = nil
            runnerID = nil
            pendingRepositoryIDs = nil
            pendingTargetGroupID = nil
            pendingLabels = nil
            failedStep = nil
            boundServerHost = normalized
            return false
        }
        boundServerHost = normalized
        return true
    }

    /// Generation-owned failure exit. Only the generation that still holds
    /// the lock may record its failure and release it; a stale failure
    /// (abandoned, cancelled, or reset while suspended) mutates nothing, so
    /// it can never unlock a newer operation or plant its failedStep.
    private func fail(_ error: Error, step: String, generation gen: Int) async {
        guard workingOwner == gen else { return }
        failedStep = step
        workingOwner = nil
        workingStep = nil
        if error is CancellationError { return }
        if let reg = error as? RunnerRegistration.RegistrationError {
            switch reg {
            case .missingPermission, .forbidden:
                await action {
                    RunnerRegistration.Action.permissionDenied(message: reg.localizedDescription, step: step)
                }
                return
            default:
                break
            }
        }
        let message = (error as? LocalizedError)?.localizedDescription ?? error.localizedDescription
        await action { RunnerRegistration.Action.failed(message: message, step: step) }
    }

    /// Generation-owned success exit. Only the generation that still holds
    /// the lock may attest its step and release it; a stale success emits
    /// nothing and mutates nothing.
    private func finishStep(_ step: String, generation gen: Int) async {
        guard workingOwner == gen else { return }
        failedStep = nil
        workingOwner = nil
        workingStep = nil
        await action { RunnerRegistration.Action.stepFinished(step) }
    }

    // MARK: - Group

    private func resolveGroup() async {
        let gen = generation
        guard workingOwner == nil else { return }
        guard let draft else {
            await action { RunnerRegistration.Action.failed(message: "Start a draft first.", step: "resolveGroup") }
            return
        }
        do {
            try RunnerRegistration.Gates.requireOrganizationScope(draft.scope)
        } catch {
            failedStep = "resolveGroup"
            await action { RunnerRegistration.Action.failed(message: error.localizedDescription, step: "resolveGroup") }
            return
        }
        guard case .organization(let org) = draft.scope else { return }
        workingOwner = gen
        workingStep = "resolveGroup"
        await action { RunnerRegistration.Action.stepStarted("resolveGroup") }
        do {
            let auth = try await currentUserToken(generation: gen)
            guard !isStale(gen) else { return }
            _ = syncServerBinding(auth.identity.serverHost)
            guard !isStale(gen) else { return }
            let groups = try await api.fetchGroups(config: auth.config, token: auth.token, org: org)
            guard !isStale(gen) else { return }
            let name = draft.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved: RunnerRegistration.RunnerGroup
            if let existing = groups.first(where: { $0.name == name }) {
                // Name alone never authorizes adoption: require a locally
                // recorded ownership entry on this server or explicit
                // takeover confirmation.
                let owned = await installer.loadOwnedGroupID(
                    serverHost: auth.identity.serverHost, org: org, name: name
                )
                try RunnerRegistration.Gates.authorizeGroupTakeover(
                    groupName: name, existingID: existing.id,
                    ownedID: owned, allowTakeover: draft.allowGroupTakeover
                )
                if owned != existing.id {
                    try await installer.saveOwnedGroupID(
                        serverHost: auth.identity.serverHost, org: org, name: name, groupID: existing.id
                    )
                }
                guard !isStale(gen) else { return }
                // A pre-existing group may deny public repos (GitHub default
                // false), which would silently drop selected public repos.
                if existing.allowsPublicRepositories {
                    resolved = existing
                } else {
                    resolved = try await api.updateGroupAllowsPublic(
                        config: auth.config, token: auth.token, org: org,
                        groupID: existing.id, allowsPublic: true
                    )
                }
            } else {
                resolved = try await api.createGroup(
                    config: auth.config, token: auth.token, org: org,
                    name: name, selectedRepositoryIDs: draft.selectedRepositoryIDs,
                    allowsPublicRepositories: true
                )
                guard !isStale(gen) else { return }
                try await installer.saveOwnedGroupID(
                    serverHost: auth.identity.serverHost, org: org, name: name, groupID: resolved.id
                )
            }
            guard !isStale(gen) else { return }
            let repoIDs = try await api.fetchGroupRepositories(
                config: auth.config, token: auth.token, org: org, groupID: resolved.id
            )
            guard !isStale(gen) else { return }
            group = resolved
            await action { RunnerRegistration.Action.groupResolved(resolved, repositoryIDs: repoIDs) }
            guard !isStale(gen) else { return }
            await action { RunnerRegistration.Action.permissionDismissed }
            await finishStep("resolveGroup", generation: gen)
        } catch {
            await fail(error, step: "resolveGroup", generation: gen)
        }
    }

    // MARK: - Download

    private func prepareDownload() async {
        let gen = generation
        guard workingOwner == nil else { return }
        guard let draft else {
            await action { RunnerRegistration.Action.failed(message: "Start a draft first.", step: "prepareDownload") }
            return
        }
        workingOwner = gen
        workingStep = "prepareDownload"
        await action { RunnerRegistration.Action.stepStarted("prepareDownload") }
        do {
            let auth = try await currentUserToken(generation: gen)
            guard !isStale(gen) else { return }
            _ = syncServerBinding(auth.identity.serverHost)
            guard !isStale(gen) else { return }
            let found = try await prepareDownloadInner(draft: draft, auth: auth, generation: gen)
            guard !isStale(gen) else { return }
            asset = found
            await action { RunnerRegistration.Action.downloadReady(found) }
            await finishStep("prepareDownload", generation: gen)
        } catch {
            await fail(error, step: "prepareDownload", generation: gen)
        }
    }

    private func prepareDownloadInner(
        draft: RunnerRegistration.Draft, auth: FlowUserToken, generation gen: Int
    ) async throws -> RunnerRegistration.DownloadAsset {
        guard !isStale(gen) else { throw CancellationError() }
        let assets = try await api.fetchDownloads(config: auth.config, token: auth.token, scope: draft.scope)
        guard !isStale(gen) else { throw CancellationError() }
        return try RunnerRegistration.Gates.selectDownload(
            osName: RunnerInstallerService.installOS,
            arch: installer.architecture,
            from: assets
        )
    }

    // MARK: - Install

    private func downloadAndInstall() async {
        let gen = generation
        guard workingOwner == nil else { return }
        guard let draft else {
            await action {
                RunnerRegistration.Action.failed(message: "Start a draft first.", step: "downloadAndInstall")
            }
            return
        }
        workingOwner = gen
        workingStep = "downloadAndInstall"
        await action { RunnerRegistration.Action.stepStarted("downloadAndInstall") }
        do {
            // Bind to the authenticated server before touching the cache: a
            // session change drops the old server's asset instead of reusing
            // it. The same auth serves the whole step; no mid-step reload
            // may mix servers.
            let auth = try await currentUserToken(generation: gen)
            guard !isStale(gen) else { return }
            _ = syncServerBinding(auth.identity.serverHost)
            guard !isStale(gen) else { return }
            let serverHost = auth.identity.serverHost
            let resolved: RunnerRegistration.DownloadAsset
            if let asset {
                resolved = asset
            } else {
                resolved = try await prepareDownloadInner(draft: draft, auth: auth, generation: gen)
                guard !isStale(gen) else { return }
                asset = resolved
                await action { RunnerRegistration.Action.downloadReady(resolved) }
            }
            guard !isStale(gen) else { return }
            let directory = try await installer.downloadAndInstall(
                asset: resolved, draft: draft, serverHost: serverHost
            )
            guard !isStale(gen) else { return }
            installPath = directory.path
            await action { RunnerRegistration.Action.installed(path: directory.path) }
            await finishStep("downloadAndInstall", generation: gen)
        } catch {
            await fail(error, step: "downloadAndInstall", generation: gen)
        }
    }

    // MARK: - Register

    private func registerRunner() async {
        let gen = generation
        guard workingOwner == nil else { return }
        guard let draft else {
            await action { RunnerRegistration.Action.failed(message: "Start a draft first.", step: "registerRunner") }
            return
        }
        guard let installPath else {
            failedStep = "registerRunner"
            await action {
                RunnerRegistration.Action.failed(message: "Install the runner package first.", step: "registerRunner")
            }
            return
        }
        workingOwner = gen
        workingStep = "registerRunner"
        await action { RunnerRegistration.Action.stepStarted("registerRunner") }
        let directory = URL(fileURLWithPath: installPath)
        let scopeKey = Self.tokenScopeKey(draft: draft)
        do {
            // The whole step — including idempotent resume — is bound to one
            // authenticated server. Resume verifies the full local identity
            // (server/scope/agent/name/work-folder/group) before any success:
            // a drifted or re-targeted draft never adopts the old marker.
            let auth = try await currentUserToken(generation: gen)
            guard !isStale(gen) else { return }
            _ = syncServerBinding(auth.identity.serverHost)
            guard !isStale(gen) else { return }
            let serverHost = auth.identity.serverHost
            if await installer.hasCompleted(RunnerInstallerService.stepConfigured, directory: directory) {
                let local = await installer.readLocalRegistration(directory: directory)
                let localID = try RunnerRegistration.Gates.verifiedLocalAgentID(
                    local: local, configured: true, draft: draft, serverHost: serverHost
                )
                let marker = await installer.loadMarker(directory: directory)
                let groupName: String?
                switch draft.scope {
                case .organization:
                    groupName = draft.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                case .repository:
                    groupName = nil
                }
                try RunnerInstallerService.verifyConfiguredGroup(
                    marker: marker, runnerGroup: groupName, draft: draft
                )
                let remoteID = try await resolveBoundRemoteRunnerID(
                    draft: draft, localAgentID: localID, auth: auth, generation: gen
                )
                guard !isStale(gen) else { return }
                runnerID = remoteID
                await action { RunnerRegistration.Action.registered(runnerID: remoteID, localAgentID: localID) }
                await finishStep("registerRunner", generation: gen)
                return
            }
            guard !isStale(gen) else { return }
            // Duplicate guard before any token is minted: without explicit
            // replace consent a remote name match refuses the run so config
            // can never silently replace another machine's registration.
            // The list is complete (every page followed); a duplicate that
            // appears after this check still fails at config.sh, which omits
            // `--replace` unless the user explicitly allowed it.
            let wanted = draft.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = try await api.fetchRunners(config: auth.config, token: auth.token, scope: draft.scope)
            guard !isStale(gen) else { return }
            try RunnerRegistration.Gates.rejectRemoteDuplicate(
                name: wanted, isTaken: existing.contains(where: { $0.name == wanted }),
                allowReplace: draft.allowReplace
            )
            guard !isStale(gen) else { return }
            let created = try await api.createRegistrationToken(
                config: auth.config, token: auth.token, scope: draft.scope
            )
            guard !isStale(gen) else { return }
            let scoped = RunnerRegistration.ScopedToken(
                token: created.token, expiresAt: created.expiresAt, obtainedAt: now()
            )
            try await registrationTokens.save(scoped, scopeKey: scopeKey)
            guard !isStale(gen) else { return }
            let groupName: String?
            switch draft.scope {
            case .organization: groupName = draft.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            case .repository: groupName = nil
            }
            let localID: Int64?
            do {
                localID = try await installer.runConfig(
                    directory: directory,
                    scopeURL: draft.scope.configURL(serverHost: auth.identity.serverHost),
                    token: created.token,
                    draft: draft,
                    runnerGroup: groupName
                )
            } catch {
                await registrationTokens.delete(scopeKey: scopeKey)
                throw error
            }
            // The single-use token is consumed by config.sh: delete it before
            // any follow-up API call so a post-config failure (review F6)
            // reports the error without retaining the token.
            await registrationTokens.delete(scopeKey: scopeKey)
            guard !isStale(gen) else { return }
            // Bind the remote ID to the verified local agent, never to a
            // bare name match: a same-name foreign runner must fail here
            // instead of becoming this installation's identity.
            let verifiedLocal: RunnerRegistration.LocalRegistration? = await installer.readLocalRegistration(
                directory: directory
            )
            let verifiedConfigured = await installer.hasCompleted(
                RunnerInstallerService.stepConfigured, directory: directory
            )
            let verifiedID = try RunnerRegistration.Gates.verifiedLocalAgentID(
                local: verifiedLocal,
                configured: verifiedConfigured && localID != nil,
                draft: draft,
                serverHost: serverHost
            )
            let remoteID = try await resolveBoundRemoteRunnerID(
                draft: draft, localAgentID: verifiedID, auth: auth, generation: gen
            )
            guard !isStale(gen) else { return }
            runnerID = remoteID
            await action { RunnerRegistration.Action.registered(runnerID: remoteID, localAgentID: verifiedID) }
            guard !isStale(gen) else { return }
            await action { RunnerRegistration.Action.permissionDismissed }
            await finishStep("registerRunner", generation: gen)
        } catch {
            await fail(error, step: "registerRunner", generation: gen)
        }
    }

    /// Binds the complete remote runner list to the verified local agent ID.
    /// Returns nil when this agent is not listed yet (convergence, retryable);
    /// throws when the list contradicts the local identity. The step's own
    /// auth is reused: no mid-step session reload may mix servers.
    private func resolveBoundRemoteRunnerID(
        draft: RunnerRegistration.Draft, localAgentID: Int64,
        auth: FlowUserToken, generation gen: Int
    ) async throws -> Int64? {
        guard !isStale(gen) else { throw CancellationError() }
        let runners = try await api.fetchRunners(config: auth.config, token: auth.token, scope: draft.scope)
        let wanted = draft.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return try RunnerRegistration.Gates.boundRemoteRunnerID(
            localAgentID: localAgentID, name: wanted, runners: runners
        )
    }

    // MARK: - Service

    private func setupService() async {
        let gen = generation
        guard workingOwner == nil else { return }
        guard let draft, let installPath else {
            failedStep = "setupService"
            await action {
                RunnerRegistration.Action.failed(message: "Register the runner first.", step: "setupService")
            }
            return
        }
        workingOwner = gen
        workingStep = "setupService"
        await action { RunnerRegistration.Action.stepStarted("setupService") }
        let directory = URL(fileURLWithPath: installPath)
        do {
            // Service setup never declares registration complete on its own:
            // it requires this operation's verified configured local identity
            // on the authenticated server.
            let auth = try await currentUserToken(generation: gen)
            guard !isStale(gen) else { return }
            _ = syncServerBinding(auth.identity.serverHost)
            guard !isStale(gen) else { return }
            let local = await installer.readLocalRegistration(directory: directory)
            let configured = await installer.hasCompleted(
                RunnerInstallerService.stepConfigured, directory: directory
            )
            _ = try RunnerRegistration.Gates.verifiedLocalAgentID(
                local: local, configured: configured, draft: draft,
                serverHost: auth.identity.serverHost
            )
            let marker = await installer.loadMarker(directory: directory)
            let groupName: String?
            switch draft.scope {
            case .organization:
                groupName = draft.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            case .repository:
                groupName = nil
            }
            try RunnerInstallerService.verifyConfiguredGroup(
                marker: marker, runnerGroup: groupName, draft: draft
            )
            guard !isStale(gen) else { return }
            let label = Self.serviceLabel(draft: draft)
            let plist = try await installer.setupService(directory: directory, label: label)
            guard !isStale(gen) else { return }
            await action { RunnerRegistration.Action.serviceReady(plistPath: plist.path) }
            await finishStep("setupService", generation: gen)
        } catch {
            await fail(error, step: "setupService", generation: gen)
        }
    }

    // MARK: - Editable access and labels

    private func applyRepositoryAccess(groupID: Int64, ids: Set<Int64>) async {
        let gen = generation
        guard workingOwner == nil else { return }
        guard let draft else {
            await action {
                RunnerRegistration.Action.failed(message: "Start a draft first.", step: "applyRepositoryAccess")
            }
            return
        }
        do {
            try RunnerRegistration.Gates.requireOrganizationScope(draft.scope)
            guard case .organization(let org) = draft.scope else { return }
            workingOwner = gen
            workingStep = "applyRepositoryAccess"
            pendingRepositoryIDs = ids
            pendingTargetGroupID = groupID
            await action { RunnerRegistration.Action.stepStarted("applyRepositoryAccess") }
            let auth = try await currentUserToken(generation: gen)
            guard !isStale(gen) else { return }
            _ = syncServerBinding(auth.identity.serverHost)
            guard !isStale(gen) else { return }
            guard let group else {
                throw RunnerRegistration.RegistrationError.invalidDraft(
                    "Resolve the dedicated group first."
                )
            }
            try RunnerRegistration.Gates.authorizeGroupMutation(
                targetGroupID: groupID, resolvedGroupID: group.id,
                allowFlag: draft.allowGroupMutation
            )
            guard !isStale(gen) else { return }
            try await api.setGroupRepositories(
                config: auth.config, token: auth.token, org: org, groupID: group.id, selectedRepositoryIDs: ids
            )
            guard !isStale(gen) else { return }
            let confirmed = try await api.fetchGroupRepositories(
                config: auth.config, token: auth.token, org: org, groupID: group.id
            )
            guard !isStale(gen) else { return }
            // The confirmed list is complete (every page followed). It must
            // equal the request exactly; otherwise the draft keeps the
            // requested selection and the step fails instead of claiming a
            // partial write as success.
            try RunnerRegistration.Gates.confirmRepositoryIDs(requested: ids, confirmed: confirmed)
            guard !isStale(gen) else { return }
            if var current = self.draft {
                current.selectedRepositoryIDs = Set(confirmed)
                self.draft = current
            }
            await action { RunnerRegistration.Action.repositoryAccessApplied(confirmed) }
            guard !isStale(gen) else { return }
            await action { RunnerRegistration.Action.permissionDismissed }
            pendingRepositoryIDs = nil
            pendingTargetGroupID = nil
            await finishStep("applyRepositoryAccess", generation: gen)
        } catch {
            await fail(error, step: "applyRepositoryAccess", generation: gen)
        }
    }

    private func applyLabels(_ labels: [String]) async {
        let gen = generation
        guard workingOwner == nil else { return }
        guard let draft else {
            await action { RunnerRegistration.Action.failed(message: "Start a draft first.", step: "applyLabels") }
            return
        }
        let trimmed = labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else {
            failedStep = "applyLabels"
            await action {
                RunnerRegistration.Action.failed(message: "At least one label is required.", step: "applyLabels")
            }
            return
        }
        guard let installPath else {
            failedStep = "applyLabels"
            await action {
                RunnerRegistration.Action.failed(
                    message: "Register the runner first so labels target this installation.",
                    step: "applyLabels"
                )
            }
            return
        }
        workingOwner = gen
        workingStep = "applyLabels"
        pendingLabels = trimmed
        await action { RunnerRegistration.Action.stepStarted("applyLabels") }
        let directory = URL(fileURLWithPath: installPath)
        do {
            // Label writes require this operation's verified local identity
            // on the authenticated server — checked before any runner-list or
            // label network. A remote name match alone never authorizes
            // mutating another runner, and a foreign-server ID never
            // authorizes writes on this session's server.
            let auth = try await currentUserToken(generation: gen)
            guard !isStale(gen) else { return }
            _ = syncServerBinding(auth.identity.serverHost)
            guard !isStale(gen) else { return }
            let local = await installer.readLocalRegistration(directory: directory)
            let configured = await installer.hasCompleted(
                RunnerInstallerService.stepConfigured, directory: directory
            )
            let localAgentID = try RunnerRegistration.Gates.verifiedLocalAgentID(
                local: local, configured: configured, draft: draft,
                serverHost: auth.identity.serverHost
            )
            guard !isStale(gen) else { return }
            // Re-bind on every write: the stored ID is never trusted across
            // edits, retries, or remote drift. A missing agent fails with
            // not-found; a contradictory list fails with mismatch. Neither
            // guesses by name.
            let runners = try await api.fetchRunners(config: auth.config, token: auth.token, scope: draft.scope)
            guard !isStale(gen) else { return }
            let wanted = draft.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let bound = try RunnerRegistration.Gates.boundRemoteRunnerID(
                localAgentID: localAgentID, name: wanted, runners: runners
            )
            guard let runnerID = bound else {
                throw RunnerRegistration.RegistrationError.remoteRunnerNotFound(
                    "GitHub does not list agent \(localAgentID) for this scope yet; refusing to guess '\(wanted)' by name. Retry after registration converges."
                )
            }
            try await api.setRunnerLabels(
                config: auth.config, token: auth.token, scope: draft.scope, runnerID: runnerID, labels: trimmed
            )
            guard !isStale(gen) else { return }
            self.runnerID = runnerID
            if var current = self.draft {
                current.labels = trimmed
                self.draft = current
            }
            await action { RunnerRegistration.Action.labelsApplied(trimmed) }
            pendingLabels = nil
            await finishStep("applyLabels", generation: gen)
        } catch {
            await fail(error, step: "applyLabels", generation: gen)
        }
    }

    // MARK: - Retry / cancel / reset

    private func retry() async {
        guard workingOwner == nil else { return }
        guard let step = failedStep else { return }
        switch step {
        case "resolveGroup": await resolveGroup()
        case "prepareDownload": await prepareDownload()
        case "downloadAndInstall": await downloadAndInstall()
        case "registerRunner": await registerRunner()
        case "setupService": await setupService()
        case "applyRepositoryAccess":
            if let ids = pendingRepositoryIDs, let target = pendingTargetGroupID {
                await applyRepositoryAccess(groupID: target, ids: ids)
            }
        case "applyLabels":
            if let labels = pendingLabels { await applyLabels(labels) }
        default:
            return
        }
    }

    private func cancel() async {
        // New generation takes over the UI lock immediately; the abandoned
        // operation's installer lease (if any) stays held until that side
        // effect settles, and its stale exit mutates nothing.
        generation += 1
        workingOwner = nil
        workingStep = nil
        if let draft {
            await registrationTokens.delete(scopeKey: Self.tokenScopeKey(draft: draft))
        }
        failedStep = nil
        pendingRepositoryIDs = nil
        pendingTargetGroupID = nil
        pendingLabels = nil
        await action { RunnerRegistration.Action.cancelled }
    }

    private func reset() async {
        // Same ownership handoff as cancel: the UI lock moves to the fresh
        // generation at once; live side effects keep the installer lease
        // and their stale exits mutate nothing.
        generation += 1
        workingOwner = nil
        workingStep = nil
        if let draft {
            await registrationTokens.delete(scopeKey: Self.tokenScopeKey(draft: draft))
        }
        draft = nil
        group = nil
        asset = nil
        installPath = nil
        runnerID = nil
        failedStep = nil
        pendingRepositoryIDs = nil
        pendingTargetGroupID = nil
        pendingLabels = nil
        boundServerHost = nil
        await action { RunnerRegistration.Action.didReset }
    }
}
