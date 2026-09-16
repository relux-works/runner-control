import Foundation
import Relux
extension Runners {
    public protocol IFlow: Relux.Flow {}
    public actor Flow {
        public let dispatcher: Relux.Dispatcher
        private let service: any RunnerServicing
        private let catalog: RunnerCatalogStore
        private let installer: RunnerInstallerService
        private let api: GitHubRunnerAPIClient
        private let userStore: any GitHubCredentialStoring
        private let identities: any GitHubSessionIdentityStoring
        private let refresher: GitHubTokenRefresh
        private let configProvider: @Sendable (String?) throws -> GitHubAuth.AppConfig
        private let now: @Sendable () -> Date
        private let home: URL
        private var working: Set<String> = []
        private var refreshing = false
        private var revision = 0
        private var pendingOp: [String: OperationPhase] = [:]
        private var unregisterWorking: Set<String> = []
        private var catalogGeneration = 0
        private var editorAuthorities: [String: Runners.EditorAuthority] = [:]
        private var editorInvalidated: Set<String> = []
        /// Per-editor group-access operation owner. Every Load/Apply mints a
        /// fresh unique identity; only the current owner may publish into
        /// the shared editor state or release its busy flag. The identity is
        /// never reused: dropping ownership on remove/relink deletes the
        /// entry without resetting any counter, so a re-imported editor's
        /// next operation cannot collide with an in-flight predecessor.
        /// Keyed by the same id spelling the actions use, so the owner check
        /// lines up with the reducer key.
        private var groupAccessOwner: [String: UUID] = [:]
        public init(service: any RunnerServicing, dispatcher: Relux.Dispatcher? = nil) async {
            self.service = service
            self.catalog = RunnerCatalogStore()
            self.installer = RunnerInstallerService()
            let transport = URLSessionGitHubTransport()
            let store: any GitHubCredentialStoring = GitHubKeychainStore()
            self.api = GitHubRunnerAPIClient(transport: transport)
            self.userStore = store
            self.identities = UserDefaultsGitHubSessionIdentityStore()
            self.refresher = GitHubTokenRefresh(transport: transport, store: store)
            self.configProvider = { host in try GitHubAuth.AppConfig.current(serverHost: host ?? "github.com") }
            self.now = Date.init
            self.home = FileManager.default.homeDirectoryForCurrentUser
            self.dispatcher = if let dispatcher { dispatcher } else { await Self.defaultDispatcher }
        }
        /// Testable init with explicit catalog, installer and auth dependencies.
        /// Production passes the shared installer so unregister/recovery and
        /// registration cannot overlap.
        public init(
            service: any RunnerServicing,
            catalog: RunnerCatalogStore,
            installer: RunnerInstallerService,
            api: GitHubRunnerAPIClient,
            userStore: any GitHubCredentialStoring,
            identities: any GitHubSessionIdentityStoring,
            refresher: GitHubTokenRefresh,
            configProvider: (@Sendable (String?) throws -> GitHubAuth.AppConfig)? = nil,
            now: (@Sendable () -> Date)? = nil,
            home: URL? = nil,
            dispatcher: Relux.Dispatcher? = nil
        ) async {
            self.service = service
            self.catalog = catalog
            self.installer = installer
            self.api = api
            self.userStore = userStore
            self.identities = identities
            self.refresher = refresher
            self.configProvider = configProvider ?? { host in try GitHubAuth.AppConfig.current(serverHost: host ?? "github.com") }
            self.now = now ?? Date.init
            self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
            self.dispatcher = if let dispatcher { dispatcher } else { await Self.defaultDispatcher }
        }
    }
}
extension Runners.Flow: Runners.IFlow {
    public func apply(_ effect: any Relux.Effect) async -> Relux.ActionResult {
        guard let effect = effect as? Runners.Effect else { return .success }
        switch effect {
        case .refresh: await refresh()
        case .setEnabled(let id, let enabled): await setEnabled(id: id, enabled: enabled)
        case .setEnabledMany(let ids, let enabled): await setEnabledMany(ids: ids, enabled: enabled)
        case .loadCatalog: await loadCatalog()
        case .discover: await discover()
        case .importCandidate(let candidate): await importCandidate(candidate)
        case .importFolder(let url): await importFolder(url)
        case .removeFromApp(let id): await removeFromApp(id: id)
        case .unregister(let id, let confirmation): await unregister(id: id, confirmation: confirmation)
        case .refreshRemote: await refreshRemote()
        case .setRunAtLoad(let id, let value): await setRunAtLoad(id: id, value: value)
        case .setAlias(let id, let alias): await setAlias(id: id, alias: alias)
        case .relinkDirectory(let id, let url): await relink(id: id, url: url)
        case .selectRunner(let id): await action { Runners.Action.selected(id) }
        case .loadLog(let id): await loadLog(id: id)
        case .clearLog: await action { Runners.Action.logCleared }
        case .loadGroupAccess(let id): await loadGroupAccess(id: id)
        case .applyGroupAccess(let id, let groupID, let repos, let allowTakeover):
            await applyGroupAccess(id: id, groupID: groupID, repos: repos, allowTakeover: allowTakeover)
        }
        return .success
    }

    private func isCatalogStale(_ gen: Int) -> Bool { catalogGeneration != gen }

    // MARK: - Local refresh and power

    private func refresh() async {
        guard !refreshing, working.isEmpty else { return }
        refreshing = true
        let startedAt = revision
        let snapshots = await service.snapshots()
        // Do not publish a stale read if a command started during this await.
        if working.isEmpty && revision == startedAt {
            let mapped_snapshots = Self.applyPending(snapshots, pending: pendingOp)
            await action { Runners.Action.refreshed(mapped_snapshots) }
        }
        refreshing = false
    }

    private func withPendingOp(_ snapshots: [Runners.Snapshot]) -> [Runners.Snapshot] {
        Self.applyPending(snapshots, pending: pendingOp)
    }

    private nonisolated static func applyPending(_ snapshots: [Runners.Snapshot], pending: [String: Runners.OperationPhase]) -> [Runners.Snapshot] {
        snapshots.map { snapshot in
            var next = snapshot
            next.operation = pending[snapshot.id] ?? .idle
            // Reflect the operation in the local status so the row shows
            // starting/stopping instead of jumping ahead to running/stopped.
            if next.operation == .starting, next.status == .stopped || next.status == .failed {
                next.status = .starting
            } else if next.operation == .stopping, next.status == .running {
                next.status = .stopping
            }
            return next
        }
    }

    private func setEnabled(id: String, enabled: Bool) async {
        guard !working.contains(id), !unregisterWorking.contains(id) else { return }
        working.insert(id)
        revision += 1
        pendingOp[id] = enabled ? .starting : .stopping
        await action { Runners.Action.changing(id, true) }
        do { try await service.setEnabled(enabled, id: id) }
        catch { await action { Runners.Action.failed(error.localizedDescription) } }
        pendingOp.removeValue(forKey: id)
        let snapshots = await service.snapshots()
        let mapped_snapshots = Self.applyPending(snapshots, pending: pendingOp)
        await action { Runners.Action.refreshed(mapped_snapshots) }
        working.remove(id)
        await action { Runners.Action.changing(id, false) }
    }

    /// Bulk power with per-row errors. Every row is attempted; failures are
    /// reported per row in the refreshed snapshots plus one summary failure.
    /// A single-row error never blocks the rest of the list.
    private func setEnabledMany(ids: [String], enabled: Bool) async {
        let targets = ids.filter { !working.contains($0) && !unregisterWorking.contains($0) }
        guard !targets.isEmpty else { return }
        for id in targets {
            working.insert(id)
            pendingOp[id] = enabled ? .starting : .stopping
            await action { Runners.Action.changing(id, true) }
        }
        revision += 1
        var failures: [(String, String)] = []
        for id in targets {
            do { try await service.setEnabled(enabled, id: id) }
            catch { failures.append((id, error.localizedDescription)) }
        }
        for id in targets { pendingOp.removeValue(forKey: id) }
        var snapshots = await service.snapshots()
        if !failures.isEmpty {
            let table = Dictionary(uniqueKeysWithValues: failures)
            snapshots = snapshots.map { snapshot in
                var next = snapshot
                if let message = table[snapshot.id] {
                    next.message = message
                }
                return next
            }
            let summary = failures.map { id, message in "\(id): \(message)" }.joined(separator: "; ")
            let failureCount = failures.count
            let targetCount = targets.count
            let bulkMessage = "Partial failure (\(failureCount) of \(targetCount)): \(summary)"
            await action { Runners.Action.failed(bulkMessage) }
        }
        let mapped_snapshots = Self.applyPending(snapshots, pending: pendingOp)
        await action { Runners.Action.refreshed(mapped_snapshots) }
        for id in targets {
            working.remove(id)
            await action { Runners.Action.changing(id, false) }
        }
    }

    // MARK: - Catalog

    /// One-time migration plus refresh. Never starts or stops CI and never
    /// modifies services; discovery only reads.
    private func loadCatalog() async {
        do {
            _ = try await catalog.migrateIfNeeded()
            await action { Runners.Action.catalogCleared }
        } catch {
            await action { Runners.Action.catalogFailed(error.localizedDescription) }
        }
        let snapshots = await service.snapshots()
        let mapped_snapshots = Self.applyPending(snapshots, pending: pendingOp)
        await action { Runners.Action.refreshed(mapped_snapshots) }
    }

    private func discover() async {
        let entries = await catalog.load()
        let known = Set(entries.map(\.canonicalPath))
        let extra = entries.map { RunnerCatalogStore.resolve(entry: $0) }
        let candidates = RunnerDiscovery.discoverCandidates(knownCanonicals: known, extraDirectories: extra)
            .filter { candidate in
                let canonical = RunnerCatalogStore.canonical(candidate.directory)
                return !known.contains(canonical)
            }
        await action { Runners.Action.candidatesLoaded(candidates) }
    }

    private func importCandidate(_ candidate: RunnerDiscovery.Candidate) async {
        let gen = catalogGeneration
        // Refuse mutations for an entry already under unregister.
        if let label = candidate.label, unregisterWorking.contains(label) {
            await action { Runners.Action.catalogFailed(RunnerRegistration.RegistrationError.installerBusy(path: candidate.directory.path).localizedDescription) }
            return
        }
        do {
            try RunnersCatalogGates.validateImportable(candidate)
            let canonical = RunnerCatalogStore.canonical(candidate.directory)
            let entries = await catalog.load()
            if entries.contains(where: { $0.canonicalPath == canonical }) {
                throw RunnerCatalogStore.CatalogError.duplicateDirectory(path: candidate.directory.path)
            }
            guard !isCatalogStale(gen) else { return }
            let label: String
            let plist: URL
            let kind = candidate.controllerKind
            if let manifest = candidate.manifest, let existing = candidate.label {
                // Import without changing the existing service: never
                // re-registers and never flips the preserved RunAtLoad policy.
                // A manifest label already owned by another entry refuses:
                // two entries must never share one control identity.
                if entries.contains(where: { $0.serviceLabel == existing }) {
                    throw RunnerCatalogStore.CatalogError.duplicateLabel(label: existing)
                }
                label = existing
                plist = manifest
            } else {
                // No manifest: create a manual service (RunAtLoad off for new
                // runners). Never bootstraps; enabling is a separate action.
                // The label binds agent name plus canonical path, so two
                // same-name folders never share one control identity.
                label = RunnerCatalogStore.importedServiceLabel(
                    agentName: candidate.agentName, directory: candidate.directory
                )
                if entries.contains(where: { $0.serviceLabel == label }) {
                    throw RunnerCatalogStore.CatalogError.duplicateLabel(label: label)
                }
                plist = try await installer.setupService(directory: candidate.directory, label: label)
            }
            guard !isCatalogStale(gen) else { return }
            let info = RunnerRegistrationReader.read(directory: candidate.directory)
            let entry = RunnerCatalogStore.Entry(
                directoryPath: candidate.directory.path,
                canonicalPath: canonical,
                bookmarkBase64: RunnerCatalogStore.bookmark(for: candidate.directory),
                serviceLabel: label,
                servicePlistPath: plist.path,
                controllerKind: kind,
                runAtLoad: candidate.runAtLoad,
                serverHost: info?.serverHost ?? candidate.serverHost,
                scopeKind: info?.scopeKind,
                scope: info?.scopeDetail ?? candidate.scope,
                remoteAgentID: info?.agentID ?? candidate.agentID,
                agentName: info?.agentName ?? candidate.agentName,
                workFolder: info?.workFolder ?? candidate.workFolder
            )
            try await catalog.add(entry)
            await action { Runners.Action.catalogCleared }
            let snapshots = await service.snapshots()
            let mapped_snapshots = Self.applyPending(snapshots, pending: pendingOp)
            await action { Runners.Action.refreshed(mapped_snapshots) }
            await discover()
        } catch {
            await action { Runners.Action.catalogFailed(error.localizedDescription) }
        }
    }

    private func importFolder(_ url: URL) async {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            await action { Runners.Action.catalogFailed("Selected folder does not exist.") }
            return
        }
        let candidate = RunnerDiscovery.validateFolder(url)
        if candidate.needsRelocation {
            await action { Runners.Action.catalogFailed("Path contains a space; choose a location without spaces. Running runners are never moved automatically.") }
            return
        }
        await importCandidate(candidate)
    }

    /// Removes only the catalog record. Deletes no files, no GitHub
    /// registration and no certificates, and never stops a running service.
    /// Warns when the service keeps running.
    private func removeFromApp(id: String) async {
        if unregisterWorking.contains(id) {
            await action { Runners.Action.catalogFailed("Runner is unregistering; retry after it settles.") }
            return
        }
        let entries = await catalog.load()
        guard let entry = entries.first(where: { $0.serviceLabel == id || $0.localID == id }) else {
            await action { Runners.Action.catalogFailed(RunnerCatalogStore.CatalogError.unknownEntry(id: id).localizedDescription) }
            return
        }
        catalogGeneration += 1
        editorAuthorities.removeValue(forKey: entry.serviceLabel)
        editorInvalidated.remove(entry.serviceLabel)
        dropGroupAccessOwnership(serviceLabel: entry.serviceLabel, localID: entry.localID)
        let snapshots = await service.snapshots()
        let wasRunning = snapshots.first(where: { $0.id == entry.serviceLabel })?.status == .running
        do {
            _ = try await catalog.remove(localID: entry.localID)
        } catch {
            await action { Runners.Action.catalogFailed(error.localizedDescription) }
            return
        }
        let refreshed = await service.snapshots()
        let mapped_refreshed = Self.applyPending(refreshed, pending: pendingOp)
        await action { Runners.Action.refreshed(mapped_refreshed) }
        if wasRunning {
            await action { Runners.Action.catalogFailed("Removed «\(entry.agentName ?? entry.serviceLabel)» from the app. Its service keeps running.") }
        } else {
            await action { Runners.Action.catalogCleared }
        }
        await discover()
    }

    // MARK: - Unregister (explicit remote removal)

    /// Explicit remote unregister, distinct from catalog removal and file
    /// deletion. Binds the local verified `.runner` server/scope/agentId and
    /// the service path, never a remote name alone. Stopped-only: requires a
    /// positive confirmed `.stopped` observation (unknown or missing state
    /// refuses) both before minting the remove token and at the `config.sh
    /// remove` boundary, plus a typed confirmation matching the agent name.
    /// Bound to the session it started with: a logout, account or server
    /// switch invalidates unstarted side effects instead of unregistering
    /// under stale authority. Holds the shared installer lease across
    /// `config.sh remove` so no registration, install, recovery or second
    /// unregister can overlap. Files and the service manifest stay for
    /// re-registration.
    private func unregister(id: String, confirmation: String) async {
        guard !unregisterWorking.contains(id), !working.contains(id) else { return }
        unregisterWorking.insert(id)
        await action { Runners.Action.unregistering(id, true) }
        await runUnregister(id: id, confirmation: confirmation)
        unregisterWorking.remove(id)
        await action { Runners.Action.unregistering(id, false) }
    }

    /// Unregister body with guaranteed operation-state release: every early
    /// return below still runs the caller's epilogue, so a refused or
    /// session-invalidated attempt never wedges the UI "unregistering"
    /// state and a retry stays possible.
    private func runUnregister(id: String, confirmation: String) async {
        let gen = catalogGeneration
        // Session ownership: the initiating session is captured once and
        // re-checked at every asynchronous boundary below.
        let startedIdentity = await identities.load()
        do {
            let entries = await catalog.load()
            guard let entry = entries.first(where: { $0.serviceLabel == id || $0.localID == id }) else {
                throw RunnerCatalogStore.CatalogError.unknownEntry(id: id)
            }
            let directory = RunnerCatalogStore.resolve(entry: entry)
            // Mutation authority: local verified identity plus the service
            // path. A remote name match alone never authorizes removal.
            guard let local = await installer.readLocalRegistration(directory: directory),
                  let agentID = local.agentID,
                  let agentName = local.agentName, !agentName.isEmpty,
                  let address = local.gitHubURL,
                  let scope = unregisterScope(address: address) else {
                throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                    "No verified local registration for '\(entry.serviceLabel)'. Refusing to unregister another runner by name."
                )
            }
            // Service-path binding: the catalog entry must still point at the
            // verified directory; a relink mid-flight invalidates the evidence.
            let canonical = RunnerCatalogStore.canonical(directory)
            guard canonical == entry.canonicalPath else {
                throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                    "Service path changed during unregister. Re-verify instead of removing another directory's registration."
                )
            }
            // Agent-ID binding: a stored ID that disagrees with disk fails
            // closed instead of removing a foreign registration.
            if let stored = entry.remoteAgentID, stored != agentID {
                throw RunnerRegistration.RegistrationError.remoteIdentityMismatch(
                    "Catalog expects agent \(stored) but disk shows agent \(agentID) for '\(agentName)'. Refusing to unregister a mismatched registration."
                )
            }
            guard confirmation == agentName else {
                throw RunnerRegistration.RegistrationError.confirmationMismatch(
                    "Type '\(agentName)' to confirm unregister of agent \(agentID) in \(scope.detail)."
                )
            }
            guard !isCatalogStale(gen) else { return }
            // Stopped-only gate: a positive confirmed `.stopped` observation
            // is required before minting the remove token, so unregister
            // cannot interrupt a job — or a service whose state is unknown.
            try await requireConfirmedStopped(entry: entry)
            guard !isCatalogStale(gen) else { return }
            let auth = try await currentUserToken()
            guard !isCatalogStale(gen) else { return }
            // Server binding: the verified host must equal the authenticated
            // server; a same-path foreign host never authorizes removal here.
            let verifiedHost = URL(string: address)?.host ?? ""
            guard RunnerRegistration.OperationIdentity.normalizeServerHost(verifiedHost)
                == RunnerRegistration.OperationIdentity.normalizeServerHost(auth.identity.serverHost) else {
                throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                    "Local registration points at '\(verifiedHost)', not the signed-in server \(auth.identity.serverHost). Refusing cross-server unregister."
                )
            }
            let created = try await api.createRemoveToken(config: auth.config, token: auth.token, scope: scope)
            guard !isCatalogStale(gen) else { return }
            // A logout, account or server switch during token acquisition
            // invalidates the unstarted side effect; the minted token
            // simply expires unused.
            guard await sessionStill(startedIdentity) else { return }
            // Re-verify after the network: scope/path edits invalidate stale
            // evidence instead of removing a re-targeted registration.
            guard let reread = await installer.readLocalRegistration(directory: directory),
                  reread.agentID == agentID, reread.agentName == agentName,
                  reread.gitHubURL == address else {
                throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                    "Local registration changed during unregister. Re-verify instead of removing a re-targeted registration."
                )
            }
            let currentEntries = await catalog.load()
            guard currentEntries.contains(where: { $0.localID == entry.localID && $0.canonicalPath == canonical }) else {
                throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                    "Catalog entry changed during unregister. Re-verify instead of removing another entry."
                )
            }
            // Revalidate the stopped evidence at the side-effect boundary: a
            // service started (or lost to inspection) after the token mint
            // must not be unregistered.
            guard !isCatalogStale(gen) else { return }
            guard await sessionStill(startedIdentity) else { return }
            try await requireConfirmedStopped(entry: entry)
            // Final boundary: the inspection above awaits production
            // launchctl, so a logout, account/server switch, or same-account
            // re-login can finish during it. Re-check the initiating-session
            // authority after the inspection, and enforce the same authority
            // again inside the installer before `config.sh remove` begins, so
            // no invalidation between the two checks can start the removal.
            guard !isCatalogStale(gen) else { return }
            guard await sessionStill(startedIdentity) else { return }
            let authority: @Sendable () async -> Bool = { [identities, startedIdentity] in
                Self.sessionMatches(startedIdentity, await identities.load())
            }
            try await installer.unregister(directory: directory, removeToken: created.token, sessionAuthority: authority)
            guard !isCatalogStale(gen) else { return }
            // Remote registration is gone; the catalog entry stays so the
            // user can re-register or remove it from the app. Files stay.
            // This local bookkeeping follows a completed side effect: the
            // remote removal is real even if the session changed while the
            // installer lease was held, and no cancellation can undo it.
            var updated = entry
            updated.remoteAgentID = nil
            updated.lastSeenAt = now()
            try await catalog.update(updated)
            await action { Runners.Action.catalogCleared }
            let refreshed = await service.snapshots()
            let mapped_refreshed = Self.applyPending(refreshed, pending: pendingOp)
            await action { Runners.Action.refreshed(mapped_refreshed) }
        } catch {
            if !isCatalogStale(gen), await sessionStill(startedIdentity) {
                await action { Runners.Action.catalogFailed(error.localizedDescription) }
            }
        }
    }

    /// Stopped-only gate for unregister. Only a positive confirmed `.stopped`
    /// observation authorizes removal. `.running` refuses with a stop-first
    /// message; a missing observation and every other state (unknown, failed,
    /// missing, transitional, ...) refuse as unconfirmed instead of being
    /// treated as stopped. A launchctl permission error (`.unknown`) therefore
    /// never authorizes `config.sh remove` on a possibly live runner.
    private func requireConfirmedStopped(entry: RunnerCatalogStore.Entry) async throws {
        let snapshots = await service.snapshots()
        guard let observation = snapshots.first(where: { $0.id == entry.serviceLabel }) else {
            throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                "Cannot confirm the service '\(entry.serviceLabel)' is stopped (no observation). Refusing to unregister while the service state is unconfirmed."
            )
        }
        switch observation.status {
        case .stopped:
            return
        case .running:
            throw RunnerRegistration.RegistrationError.invalidDraft(
                "Stop the runner first; unregister refuses to interrupt a running service."
            )
        default:
            throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                "Cannot confirm the service '\(entry.serviceLabel)' is stopped (observed: \(observation.status.rawValue)). Refusing to unregister while the service state is unconfirmed."
            )
        }
    }

    private func unregisterScope(address: String) -> RunnerRegistration.Scope? {
        guard let url = URL(string: address), url.scheme == "https" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        if components.count == 1 { return .organization(org: components[0]) }
        if components.count == 2 { return .repository(owner: components[0], name: components[1]) }
        return nil
    }

    private struct CatalogUserToken: Sendable {
        let config: GitHubAuth.AppConfig
        let token: String
        let identity: GitHubSessionIdentity
    }

    private func currentUserToken() async throws -> CatalogUserToken {
        guard let identity = await identities.load() else {
            throw RunnerRegistration.RegistrationError.notAuthenticated
        }
        let config = try configProvider(identity.serverHost)
        guard var record = await userStore.load(serverHost: identity.serverHost, userID: identity.userID, clientID: identity.clientID) else {
            throw RunnerRegistration.RegistrationError.notAuthenticated
        }
        if GitHubTokenRefresh.isExpiringSoon(record, now: now()) {
            do {
                record = try await refresher.refresh(config: config, userID: identity.userID, current: record)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GitHubAuth.AuthError {
                switch error {
                case .revoked, .unauthorized, .tokenRefreshFailed:
                    throw RunnerRegistration.RegistrationError.unauthorized
                default: break
                }
            }
        }
        return CatalogUserToken(config: config, token: record.accessToken, identity: identity)
    }

    // MARK: - Remote observation

    /// Best-effort GitHub sync. Offline, 401/403 and rate limits mark data
    /// stale and never change local power state. Follows full pagination
    /// before matching; matches by server + scope + ID, never by name.
    private func refreshRemote() async {
        let startedIdentity = await identities.load()
        let entries = await catalog.load()
        if entries.isEmpty {
            await action { Runners.Action.remoteSyncFinished(self.now()) }
            return
        }
        let auth: CatalogUserToken
        do {
            auth = try await currentUserToken()
        } catch {
            // Disconnected: local control stays fully available.
            await action { Runners.Action.remoteSyncFailed(error.localizedDescription) }
            return
        }
        // Group definitions by scope so one paginated list serves every
        // runner in that scope.
        var scopes: [String: (scope: RunnerRegistration.Scope, ids: [String])] = [:]
        var definitions: [String: Runners.Definition] = [:]
        for entry in entries {
            let directory = RunnerCatalogStore.resolve(entry: entry)
            let info = RunnerRegistrationReader.read(directory: directory)
            guard let address = info?.gitHubURL ?? entry.serverHost.map({ "https://\($0)/\(entry.scope ?? "")" }),
                  let scope = unregisterScope(address: address) else { continue }
            // Observe only registrations on the authenticated server.
            let host = URL(string: address)?.host ?? entry.serverHost ?? ""
            guard RunnerRegistration.OperationIdentity.normalizeServerHost(host)
                == RunnerRegistration.OperationIdentity.normalizeServerHost(auth.identity.serverHost) else { continue }
            let key = scope.scopeKey
            scopes[key, default: (scope, [])].ids.append(entry.serviceLabel)
            definitions[entry.serviceLabel] = LaunchAgentService.definition(from: entry)
        }
        var failures: [String] = []
        for (_, group) in scopes {
            // A logout or login replacement mid-sync stops silently: no writes
            // into a changed session incarnation.
            guard await sessionStill(startedIdentity) else { return }
            do {
                let runners = try await api.fetchRunners(config: auth.config, token: auth.token, scope: group.scope)
                for id in group.ids {
                    guard let definition = definitions[id] else { continue }
                    if let observation = GitHubRunnerObserver.match(definition: definition, runners: runners, now: now()) {
                        await action { Runners.Action.remoteUpdated(id, GitHubRunnerObserver.withFreshness(observation, now: self.now())) }
                    } else {
                        await action { Runners.Action.remoteUpdated(id, Runners.RemoteObservation(
                            busyKnown: false, updatedAt: self.now(), stale: false,
                            syncError: "Identity mismatch"
                        )) }
                    }
                }
            } catch let error as RunnerRegistration.RegistrationError {
                switch error {
                case .unauthorized:
                    await action { Runners.Action.remoteSyncFailed(RunnerRegistration.RegistrationError.unauthorized.localizedDescription) }
                    return
                case .rateLimited:
                    failures.append("Rate limited; will retry.")
                case .missingPermission(let text):
                    failures.append(text)
                default:
                    failures.append(error.localizedDescription)
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if failures.isEmpty {
            await action { Runners.Action.remoteSyncFinished(self.now()) }
        } else {
            let joinedFailures = failures.joined(separator: "; ")
            await action { Runners.Action.remoteSyncFailed(joinedFailures) }
        }
    }

    // MARK: - Preferences and relink

    /// Changes only the login-startup policy. Never bootstraps or bootouts;
    /// the policy applies at next login. Refuses while an installer mutation
    /// is live.
    /// Changes only the login-start behavior. Standard manifests edit
    /// their own RunAtLoad. External manual plists gain or lose a matching
    /// registration in `~/Library/LaunchAgents` (RunAtLoad outside
    /// LaunchAgents never persists login start). Never bootstraps or
    /// bootouts: live runner state is preserved. Refuses while an installer
    /// mutation is live, and never touches a foreign same-label plist.
    private func setRunAtLoad(id: String, value: Bool) async {
        if unregisterWorking.contains(id) || working.contains(id) {
            await action { Runners.Action.catalogFailed("Runner is busy; retry after it settles.") }
            return
        }
        let entries = await catalog.load()
        guard var entry = entries.first(where: { $0.serviceLabel == id || $0.localID == id }) else {
            await action { Runners.Action.catalogFailed(RunnerCatalogStore.CatalogError.unknownEntry(id: id).localizedDescription) }
            return
        }
        if entry.controllerKind == .unsupported {
            await action { Runners.Action.catalogFailed("Unsupported runners have no Runner Control login policy.") }
            return
        }
        do {
            let directory = RunnerCatalogStore.resolve(entry: entry)
            try await installer.requireIdle(for: directory)
            if entry.controllerKind == .standardLaunchAgent {
                let plist = URL(fileURLWithPath: entry.servicePlistPath)
                guard let data = try? Data(contentsOf: plist),
                      var object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw RunnerError.message("Service manifest is unreadable.")
                }
                object["RunAtLoad"] = value
                let out = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
                try out.write(to: plist, options: .atomic)
                entry.runAtLoad = value
                try await catalog.update(entry)
            } else {
                try setManualLogin(entry: entry, directory: directory, enabled: value)
            }
            await action { Runners.Action.catalogCleared }
            let snapshots = await service.snapshots()
            let mapped_snapshots = Self.applyPending(snapshots, pending: pendingOp)
            await action { Runners.Action.refreshed(mapped_snapshots) }
        } catch {
            await action { Runners.Action.catalogFailed(error.localizedDescription) }
        }
    }

    /// Enables or disables login start for an external manual service by
    /// managing its `~/Library/LaunchAgents` registration. The external
    /// service file itself is never modified, so the imported policy stays
    /// byte-identical; live launchd state is untouched.
    private func setManualLogin(entry: RunnerCatalogStore.Entry, directory: URL, enabled: Bool) throws {
        let external = URL(fileURLWithPath: entry.servicePlistPath)
        guard let data = try? Data(contentsOf: external),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw RunnerError.message("Service manifest is unreadable.")
        }
        let definition = LaunchAgentService.definition(from: entry)
        let copy = RunnerControllers.loginRegistrationURL(label: entry.serviceLabel, home: home)
        if enabled {
            if let existing = try? Data(contentsOf: copy),
               let current = try? PropertyListSerialization.propertyList(from: existing, format: nil) as? [String: Any] {
                guard RunnerControllers.references(current, definition: definition) else {
                    throw RunnerError.message("Login slot '\(copy.lastPathComponent)' belongs to another service. Remove it by hand instead of overwriting.")
                }
                var updated = current
                updated["RunAtLoad"] = true
                let out = try PropertyListSerialization.data(fromPropertyList: updated, format: .xml, options: 0)
                try out.write(to: copy, options: .atomic)
                return
            }
            var registration = object
            registration["Label"] = entry.serviceLabel
            registration["WorkingDirectory"] = directory.path
            registration["ProgramArguments"] = [directory.appendingPathComponent("runsvc.sh").path]
            registration["RunAtLoad"] = true
            let out = try PropertyListSerialization.data(fromPropertyList: registration, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: copy, options: .atomic)
            return
        }
        guard FileManager.default.fileExists(atPath: copy.path) else { return }
        guard let existing = try? Data(contentsOf: copy),
              let current = try? PropertyListSerialization.propertyList(from: existing, format: nil) as? [String: Any],
              RunnerControllers.references(current, definition: definition) else {
            throw RunnerError.message("Login slot '\(copy.lastPathComponent)' belongs to another service. Remove it by hand instead of deleting.")
        }
        try FileManager.default.removeItem(at: copy)
    }

    private func setAlias(id: String, alias: String?) async {
        let entries = await catalog.load()
        guard var entry = entries.first(where: { $0.serviceLabel == id || $0.localID == id }) else {
            await action { Runners.Action.catalogFailed(RunnerCatalogStore.CatalogError.unknownEntry(id: id).localizedDescription) }
            return
        }
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.displayName = (trimmed?.isEmpty == true) ? nil : trimmed
        do {
            try await catalog.update(entry)
            await action { Runners.Action.catalogCleared }
            let snapshots = await service.snapshots()
            let mapped_snapshots = Self.applyPending(snapshots, pending: pendingOp)
            await action { Runners.Action.refreshed(mapped_snapshots) }
        } catch {
            await action { Runners.Action.catalogFailed(error.localizedDescription) }
        }
    }

    /// Relinks a moved folder. Requires the new folder to hold the same full
    /// registration identity (server host, scope, agent ID) so a foreign
    /// installation can never steal this entry. Any successful relocation
    /// changes the canonical path and therefore invalidates the loaded group
    /// editor, which must be reloaded explicitly. Updates the service
    /// manifest paths, preserving RunAtLoad.
    private func relink(id: String, url: URL) async {
        if unregisterWorking.contains(id) || working.contains(id) {
            await action { Runners.Action.catalogFailed("Runner is busy; retry after it settles.") }
            return
        }
        let entries = await catalog.load()
        guard var entry = entries.first(where: { $0.serviceLabel == id || $0.localID == id }) else {
            await action { Runners.Action.catalogFailed(RunnerCatalogStore.CatalogError.unknownEntry(id: id).localizedDescription) }
            return
        }
        guard url.path != entry.directoryPath else {
            await action { Runners.Action.catalogCleared }
            return
        }
        if url.path.contains(" ") {
            await action { Runners.Action.catalogFailed("Path contains a space; choose a location without spaces.") }
            return
        }
        let canonical = RunnerCatalogStore.canonical(url)
        if entries.contains(where: { $0.localID != entry.localID && $0.canonicalPath == canonical }) {
            await action { Runners.Action.catalogFailed(RunnerCatalogStore.CatalogError.duplicateDirectory(path: url.path).localizedDescription) }
            return
        }
        guard let info = RunnerRegistrationReader.read(directory: url) else {
            await action { Runners.Action.catalogFailed("Cannot read .runner in the selected folder.") }
            return
        }
        if let stored = entry.remoteAgentID, info.agentID != stored {
            await action { Runners.Action.catalogFailed("Selected folder is agent \(info.agentID.map(String.init) ?? "unknown"), not \(stored). Refusing to relink a foreign installation.") }
            return
        }
        if let recordedHost = entry.serverHost, let folderHost = info.serverHost,
           RunnerRegistration.OperationIdentity.normalizeServerHost(recordedHost)
            != RunnerRegistration.OperationIdentity.normalizeServerHost(folderHost) {
            await invalidateEditor(id: id, serviceLabel: entry.serviceLabel, message: "Selected folder points at '\(folderHost)', not '\(recordedHost)'. Reload group access before applying.")
            await action { Runners.Action.catalogFailed("Selected folder points at '\(folderHost)', not '\(recordedHost)'. Refusing to relink a foreign installation.") }
            return
        }
        if let recordedScope = entry.scope, let folderScope = info.scopeDetail, recordedScope != folderScope {
            await invalidateEditor(id: id, serviceLabel: entry.serviceLabel, message: "Selected folder scope is '\(folderScope)', not '\(recordedScope)'. Reload group access before applying.")
            await action { Runners.Action.catalogFailed("Selected folder scope is '\(folderScope)', not '\(recordedScope)'. Refusing to relink a foreign installation.") }
            return
        }
        catalogGeneration += 1
        dropGroupAccessOwnership(serviceLabel: entry.serviceLabel, localID: entry.localID)
        do {
            let plist = URL(fileURLWithPath: entry.servicePlistPath)
            // Manual manifests move with the directory; standard manifests
            // stay in LaunchAgents. Update whichever manifest this entry owns.
            if plist.path.hasPrefix(entry.directoryPath) {
                let moved = url.appendingPathComponent("manual-service.plist")
                if FileManager.default.fileExists(atPath: moved.path) {
                    try await installer.updateServicePaths(plist: moved, directory: url)
                    entry.servicePlistPath = moved.path
                }
            } else {
                try await installer.updateServicePaths(plist: plist, directory: url)
            }
            let oldPath = entry.directoryPath
            entry.directoryPath = url.path
            entry.canonicalPath = canonical
            entry.bookmarkBase64 = RunnerCatalogStore.bookmark(for: url)
            entry.agentName = info.agentName ?? entry.agentName
            entry.serverHost = info.serverHost ?? entry.serverHost
            entry.scope = info.scopeDetail ?? entry.scope
            entry.scopeKind = info.scopeKind ?? entry.scopeKind
            entry.remoteAgentID = info.agentID ?? entry.remoteAgentID
            entry.workFolder = info.workFolder ?? entry.workFolder
            // Keep a managed login registration pointing at the new
            // directory so relink preserves effective login. Foreign
            // same-label plists are never touched.
            if entry.controllerKind == .manualManaged {
                let copy = RunnerControllers.loginRegistrationURL(label: entry.serviceLabel, home: home)
                if let data = try? Data(contentsOf: copy),
                   var current = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   current["Label"] as? String == entry.serviceLabel,
                   current["WorkingDirectory"] as? String == oldPath {
                    try await installer.requireIdle(for: url)
                    current["WorkingDirectory"] = url.path
                    current["ProgramArguments"] = [url.appendingPathComponent("runsvc.sh").path]
                    let out = try PropertyListSerialization.data(fromPropertyList: current, format: .xml, options: 0)
                    try out.write(to: copy, options: .atomic)
                }
            }
            try await catalog.update(entry)
            await action { Runners.Action.catalogCleared }
            await invalidateEditor(id: id, serviceLabel: entry.serviceLabel, message: "Runner folder moved. Reload group access before applying.")
            let snapshots = await service.snapshots()
            let mapped_snapshots = Self.applyPending(snapshots, pending: pendingOp)
            await action { Runners.Action.refreshed(mapped_snapshots) }
        } catch {
            await action { Runners.Action.catalogFailed(error.localizedDescription) }
        }
    }

    /// Clears the immutable Load-time editor authority for this runner,
    /// marks it as requiring an explicit Load, and publishes an explicit
    /// invalidation so the UI returns to a Load instead of submitting a
    /// stale group ID. A later Apply without a fresh Load refuses even
    /// when the current disk/catalog happens to match the old values.
    private func invalidateEditor(id: String, serviceLabel: String, message: String) async {
        editorAuthorities.removeValue(forKey: serviceLabel)
        editorInvalidated.insert(serviceLabel)
        await action { Runners.Action.groupAccessInvalidated(id, message) }
    }

    // MARK: - Diagnostics

    private func loadLog(id: String) async {
        let snapshots = await service.snapshots()
        guard let snapshot = snapshots.first(where: { $0.id == id }) else {
            await action { Runners.Action.catalogFailed(RunnerCatalogStore.CatalogError.unknownEntry(id: id).localizedDescription) }
            return
        }
        let excerpt = RunnerDiagnostics.tail(definition: snapshot.definition)
        await action { Runners.Action.logLoaded(title: snapshot.definition.displayTitle, excerpt: excerpt) }
    }

    // MARK: - Group access (fresh API membership)

    private struct VerifiedOrgRunner: Sendable {
        let entry: RunnerCatalogStore.Entry
        let directory: URL
        let org: String
        let agentID: Int64
        let agentName: String
    }

    /// Verifies the local `.runner` identity for group reads/writes: agent
    /// ID, name, server and org scope must all be present and bound to the
    /// catalog entry's recorded original. Local pool fields are ignored
    /// (they can lag); the group answer always comes from fresh API
    /// membership below.
    private func verifiedOrgRunner(id: String) async throws -> VerifiedOrgRunner {
        let entries = await catalog.load()
        guard let entry = entries.first(where: { $0.serviceLabel == id || $0.localID == id }) else {
            throw RunnerCatalogStore.CatalogError.unknownEntry(id: id)
        }
        let directory = RunnerCatalogStore.resolve(entry: entry)
        guard let local = await installer.readLocalRegistration(directory: directory),
              let agentID = local.agentID,
              let agentName = local.agentName, !agentName.isEmpty,
              let address = local.gitHubURL,
              let url = URL(string: address), url.scheme == "https" else {
            throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                "No verified local registration for '\(entry.serviceLabel)'. Refusing group access for another runner."
            )
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1 else {
            throw RunnerRegistration.RegistrationError.groupNotApplicable
        }
        if let stored = entry.remoteAgentID, stored != agentID {
            throw RunnerRegistration.RegistrationError.remoteIdentityMismatch(
                "Catalog expects agent \(stored) but disk shows agent \(agentID). Refusing group access for a mismatched registration."
            )
        }
        // Catalog-original binding: the mutable on-disk registration must
        // still agree with the server and scope recorded at import (or
        // explicit relink). A scope or server edit on disk — without
        // re-verification — refuses here instead of silently retargeting
        // another org's group. Load and Apply both verify here, so neither
        // path can drift off the catalog original between Load and Apply.
        // Entries without a recorded server/scope predate this binding and
        // fall through to the disk-vs-session checks below.
        let diskHost = url.host ?? ""
        if let storedHost = entry.serverHost,
           RunnerRegistration.OperationIdentity.normalizeServerHost(storedHost)
               != RunnerRegistration.OperationIdentity.normalizeServerHost(diskHost) {
            throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                "Local registration server changed from '\(storedHost)' to '\(diskHost)' since import. Re-add the runner (or relink its moved folder) to re-verify instead of editing with stale identity."
            )
        }
        if let storedScope = entry.scope, storedScope != components[0] {
            throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                "Local registration scope changed from '\(storedScope)' to '\(components[0])' since import. Re-add the runner (or relink its moved folder) to re-verify instead of editing with stale identity."
            )
        }
        return VerifiedOrgRunner(entry: entry, directory: directory, org: components[0], agentID: agentID, agentName: agentName)
    }

    /// Resolves the runner's current GitHub group by fresh API membership:
    /// lists every group, then each group's runners, matching by agent ID
    /// (and exact name on the matched ID). Never reads `.runner` pool
    /// fields and never adopts a same-name foreign runner or group.
    private func resolveFreshGroup(
        org: String, agentID: Int64, agentName: String,
        auth: CatalogUserToken, generation gen: Int
    ) async throws -> RunnerRegistration.RunnerGroup {
        let groups = try await api.fetchGroups(config: auth.config, token: auth.token, org: org)
        for group in groups {
            if isCatalogStale(gen) { throw CancellationError() }
            let members = try await api.fetchGroupRunners(config: auth.config, token: auth.token, org: org, groupID: group.id)
            if let exact = members.first(where: { $0.id == agentID }) {
                guard exact.name == agentName else {
                    throw RunnerRegistration.RegistrationError.remoteIdentityMismatch(
                        "Group '\(group.name)' lists agent \(agentID) as '\(exact.name)', not '\(agentName)'. Refusing a mismatched group."
                    )
                }
                return group
            }
            // A same-name foreign member in this group is ignored: only the
            // exact agent ID binds membership.
        }
        throw RunnerRegistration.RegistrationError.remoteRunnerNotFound(
            "Agent \(agentID) is not in any visible group for '\(org)'. It may have been moved or the App lacks group access."
        )
    }

    /// Loads fresh group + repository access for one org runner. Display and
    /// later edits use this API answer, never stale `.runner` pool fields.
    private func loadGroupAccess(id: String) async {
        let gen = catalogGeneration
        let startedIdentity = await identities.load()
        let operation = beginGroupAccessOperation(id: id)
        await action { Runners.Action.groupAccessLoading(id) }
        do {
            let verified = try await verifiedOrgRunner(id: id)
            let auth = try await currentUserToken()
            if isCatalogStale(gen) {
                await abandonGroupAccessAfterCatalogChange(id: id, operation: operation)
                return
            }
            guard await sessionStill(startedIdentity) else {
                await releaseGroupAccessAfterSessionChange(id: id, operation: operation)
                return
            }
            let verifiedHost = URL(string: (await installer.readLocalRegistration(directory: verified.directory))?.gitHubURL ?? "")?.host ?? ""
            guard RunnerRegistration.OperationIdentity.normalizeServerHost(verifiedHost)
                == RunnerRegistration.OperationIdentity.normalizeServerHost(auth.identity.serverHost) else {
                throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                    "Local registration points at '\(verifiedHost)', not the signed-in server \(auth.identity.serverHost)."
                )
            }
            let group = try await resolveFreshGroup(
                org: verified.org, agentID: verified.agentID, agentName: verified.agentName,
                auth: auth, generation: gen
            )
            if isCatalogStale(gen) {
                await abandonGroupAccessAfterCatalogChange(id: id, operation: operation)
                return
            }
            // Completion ownership: a logout, account/server switch, or
            // same-account re-login during the membership reads refuses
            // further authenticated work and any state publication into the
            // changed session incarnation — but still releases this
            // operation's busy state so the editor can be retried.
            guard await sessionStill(startedIdentity) else {
                await releaseGroupAccessAfterSessionChange(id: id, operation: operation)
                return
            }
            let repoIDs = try await api.fetchGroupRepositories(
                config: auth.config, token: auth.token, org: verified.org, groupID: group.id
            )
            if isCatalogStale(gen) {
                await abandonGroupAccessAfterCatalogChange(id: id, operation: operation)
                return
            }
            guard await sessionStill(startedIdentity) else {
                await releaseGroupAccessAfterSessionChange(id: id, operation: operation)
                return
            }
            let owned = await installer.loadOwnedGroupID(
                serverHost: auth.identity.serverHost, org: verified.org, name: group.name
            ) == group.id
            // A newer Load/Apply on this runner owns the editor now; this
            // completion stores and publishes nothing, not even cleanup.
            guard ownsGroupAccess(id: id, operation: operation) else { return }
            let authority = Runners.EditorAuthority(
                serverHost: verifiedHost, org: verified.org,
                agentID: verified.agentID, agentName: verified.agentName,
                canonicalPath: RunnerCatalogStore.canonical(verified.directory),
                localID: verified.entry.localID
            )
            editorAuthorities[verified.entry.serviceLabel] = authority
            editorInvalidated.remove(verified.entry.serviceLabel)
            let access = Runners.GroupAccess(
                group: group, repoIDs: repoIDs.sorted(), updatedAt: now(),
                owned: owned, loading: false, authority: authority
            )
            await publishGroupAccessIfCurrent(id: id, operation: operation) {
                Runners.Action.groupAccessLoaded(id, access)
            }
        } catch is CancellationError {
            await abandonGroupAccessAfterCatalogChange(id: id, operation: operation)
        } catch {
            if !isCatalogStale(gen), await sessionStill(startedIdentity) {
                let message = (error as? LocalizedError)?.localizedDescription ?? error.localizedDescription
                await publishGroupAccessIfCurrent(id: id, operation: operation) {
                    Runners.Action.groupAccessFailed(id, message)
                }
            } else if !isCatalogStale(gen) {
                await releaseGroupAccessAfterSessionChange(id: id, operation: operation)
            } else {
                await abandonGroupAccessAfterCatalogChange(id: id, operation: operation)
            }
        }
    }

    /// True when the GitHub session still matches the login incarnation this
    /// operation started with. A logout, account/server switch, or logout +
    /// same-account re-login mid-operation stops silently: no writes into a
    /// changed session. Ordinary token refresh keeps the same incarnation and
    /// stays valid. Legacy identities without an incarnation compare as nil.
    private func sessionStill(_ started: GitHubSessionIdentity?) async -> Bool {
        Self.sessionMatches(started, await identities.load())
    }

    /// Pure incarnation comparison shared by `sessionStill` and by the
    /// installer-boundary authority closure, so both enforce the same
    /// initiating-session authority without capturing the Flow actor.
    private nonisolated static func sessionMatches(
        _ started: GitHubSessionIdentity?, _ current: GitHubSessionIdentity?
    ) -> Bool {
        guard let started else { return current == nil }
        guard let current else { return false }
        guard current.userID == started.userID,
              RunnerRegistration.OperationIdentity.normalizeServerHost(current.serverHost)
                == RunnerRegistration.OperationIdentity.normalizeServerHost(started.serverHost) else { return false }
        return current.sessionIncarnation == started.sessionIncarnation
    }

    /// Write-path identity binding for group edits. Re-reads the mutable
    /// local registration and requires it to still match the verified
    /// server host, org scope, agent ID and name, and requires the catalog
    /// entry to still point at the verified canonical directory. A
    /// same-path foreign host, a scope edit, or a relink mid-flight fails
    /// instead of writing another server's group. Called after
    /// authentication and re-called at the PUT boundary.
    private func bindApplyIdentity(verified: VerifiedOrgRunner, auth: CatalogUserToken) async throws {
        guard let reread = await installer.readLocalRegistration(directory: verified.directory),
              reread.agentID == verified.agentID,
              reread.agentName == verified.agentName,
              let address = reread.gitHubURL,
              let url = URL(string: address), url.scheme == "https" else {
            throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                "Local registration changed during group apply. Reload instead of editing with stale identity."
            )
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1, components[0] == verified.org else {
            throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                "Local registration scope changed during group apply. Reload instead of editing with stale identity."
            )
        }
        let verifiedHost = url.host ?? ""
        guard RunnerRegistration.OperationIdentity.normalizeServerHost(verifiedHost)
            == RunnerRegistration.OperationIdentity.normalizeServerHost(auth.identity.serverHost) else {
            throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                "Local registration points at '\(verifiedHost)', not the signed-in server \(auth.identity.serverHost). Refusing cross-server group apply."
            )
        }
        let canonical = RunnerCatalogStore.canonical(verified.directory)
        let current = await catalog.load()
        guard current.contains(where: { $0.localID == verified.entry.localID && $0.canonicalPath == canonical }) else {
            throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                "Catalog entry changed during group apply. Reload instead of editing another entry's group."
            )
        }
    }

    /// Consumes the immutable Load-time editor authority for this runner.
    /// Returns the verified tuple when the current disk/catalog identity
    /// still matches the stored server/scope/agent/canonical/localID; when it
    /// no longer matches and this operation still owns the editor, clears the
    /// stored editor, publishes an explicit invalidation requiring a new Load,
    /// and returns nil without throwing. A stale operation refuses silently:
    /// the newer owner keeps the narrative. A missing entry throws
    /// unknownEntry like the verified path.
    private func consumeStoredEditorAuthority(_ stored: Runners.EditorAuthority, id: String, operation: UUID) async throws -> VerifiedOrgRunner? {
        let entries = await catalog.load()
        guard let entry = entries.first(where: { $0.serviceLabel == id || $0.localID == id }) else {
            throw RunnerCatalogStore.CatalogError.unknownEntry(id: id)
        }
        let directory = RunnerCatalogStore.resolve(entry: entry)
        let canonical = RunnerCatalogStore.canonical(directory)
        guard let local = await installer.readLocalRegistration(directory: directory),
              let agentID = local.agentID,
              let agentName = local.agentName, !agentName.isEmpty,
              let address = local.gitHubURL,
              let url = URL(string: address), url.scheme == "https" else {
            if ownsGroupAccess(id: id, operation: operation) {
                editorAuthorities.removeValue(forKey: entry.serviceLabel)
                editorInvalidated.insert(entry.serviceLabel)
                let message = "Runner identity changed since loading (registration unreadable for '\(entry.serviceLabel)'). Reload group access before applying."
                await action { Runners.Action.groupAccessInvalidated(id, message) }
            }
            return nil
        }
        let components = url.pathComponents.filter { $0 != "/" }
        let diskHost = url.host ?? ""
        let matches = components.count == 1
            && components[0] == stored.org
            && RunnerRegistration.OperationIdentity.normalizeServerHost(diskHost)
                == RunnerRegistration.OperationIdentity.normalizeServerHost(stored.serverHost)
            && agentID == stored.agentID
            && agentName == stored.agentName
            && canonical == stored.canonicalPath
            && entry.localID == stored.localID
        guard matches else {
            if ownsGroupAccess(id: id, operation: operation) {
                editorAuthorities.removeValue(forKey: entry.serviceLabel)
                editorInvalidated.insert(entry.serviceLabel)
                let foundScope = components.count == 1 ? components[0] : (components.joined(separator: "/").isEmpty ? "?" : components.joined(separator: "/"))
                let message = "Runner identity changed since loading (expected \(stored.serverHost)/\(stored.org)/agent\(stored.agentID), found \(diskHost)/\(foundScope)/agent\(agentID)). Reload group access before applying."
                await action { Runners.Action.groupAccessInvalidated(id, message) }
            }
            return nil
        }
        return VerifiedOrgRunner(entry: entry, directory: directory, org: stored.org, agentID: stored.agentID, agentName: stored.agentName)
    }

    /// Applies edited repository access to the runner's fresh group. Rejects
    /// stale UI (group moved since load), shared groups without explicit
    /// takeover, and partial confirmations. When a Load established an
    /// immutable editor authority, Apply consumes that tuple and refuses when
    /// the current identity no longer matches it — never reconstructing
    /// authority from the mutable current catalog. A direct Apply without a
    /// prior Load establishes its own start authority for that single write.
    /// Preserves the binding plus the starting login incarnation over every
    /// asynchronous boundary through confirmation and publication. Reuses the
    /// registration ownership and confirmation gates; API-only, no
    /// installer lease.
    private func applyGroupAccess(id: String, groupID: Int64, repos: Set<Int64>, allowTakeover: Bool) async {
        let gen = catalogGeneration
        let startedIdentity = await identities.load()
        let operation = beginGroupAccessOperation(id: id)
        await action { Runners.Action.groupAccessLoading(id) }
        do {
            if await editorRequiresReload(id: id) {
                await publishGroupAccessIfCurrent(id: id, operation: operation) {
                    Runners.Action.groupAccessInvalidated(id, "Runner editor was invalidated (folder moved or identity changed). Reload group access before applying.")
                }
                return
            }
            let verified: VerifiedOrgRunner
            if let stored = await storedEditorAuthority(id: id) {
                guard let consumed = try await consumeStoredEditorAuthority(stored, id: id, operation: operation) else { return }
                verified = consumed
            } else {
                verified = try await verifiedOrgRunner(id: id)
            }
            let auth = try await currentUserToken()
            if isCatalogStale(gen) {
                await abandonGroupAccessAfterCatalogChange(id: id, operation: operation)
                return
            }
            guard await sessionStill(startedIdentity) else {
                await releaseGroupAccessAfterSessionChange(id: id, operation: operation)
                return
            }
            try await bindApplyIdentity(verified: verified, auth: auth)
            // Fresh membership re-verified at write time: a move since the
            // UI loaded fails instead of editing the wrong group.
            let fresh = try await resolveFreshGroup(
                org: verified.org, agentID: verified.agentID, agentName: verified.agentName,
                auth: auth, generation: gen
            )
            guard fresh.id == groupID else {
                throw RunnerRegistration.RegistrationError.unverifiedRegistration(
                    "Runner moved from group \(groupID) to '\(fresh.name)' (\(fresh.id)) since loading. Reload instead of editing a stale group."
                )
            }
            if isCatalogStale(gen) {
                await abandonGroupAccessAfterCatalogChange(id: id, operation: operation)
                return
            }
            let owned = await installer.loadOwnedGroupID(
                serverHost: auth.identity.serverHost, org: verified.org, name: fresh.name
            )
            try RunnerRegistration.Gates.authorizeGroupTakeover(
                groupName: fresh.name, existingID: fresh.id,
                ownedID: owned, allowTakeover: allowTakeover
            )
            if owned != fresh.id {
                try await installer.saveOwnedGroupID(
                    serverHost: auth.identity.serverHost, org: verified.org, name: fresh.name, groupID: fresh.id
                )
            }
            if isCatalogStale(gen) {
                await abandonGroupAccessAfterCatalogChange(id: id, operation: operation)
                return
            }
            // Re-bind at the PUT boundary: the membership and ownership
            // awaits above must not carry stale identity into the write.
            guard await sessionStill(startedIdentity) else {
                await releaseGroupAccessAfterSessionChange(id: id, operation: operation)
                return
            }
            try await bindApplyIdentity(verified: verified, auth: auth)
            try await api.setGroupRepositories(
                config: auth.config, token: auth.token, org: verified.org,
                groupID: fresh.id, selectedRepositoryIDs: repos
            )
            if isCatalogStale(gen) {
                await abandonGroupAccessAfterCatalogChange(id: id, operation: operation)
                return
            }
            // Completion ownership: the issued PUT cannot be undone, but a
            // logout, account/server switch, or same-account re-login after
            // it refuses the confirmation read and any state publication
            // into the changed session incarnation — while still releasing
            // this operation's busy state so the editor can be retried.
            guard await sessionStill(startedIdentity) else {
                await releaseGroupAccessAfterSessionChange(id: id, operation: operation)
                return
            }
            let confirmed = try await api.fetchGroupRepositories(
                config: auth.config, token: auth.token, org: verified.org, groupID: fresh.id
            )
            try RunnerRegistration.Gates.confirmRepositoryIDs(requested: repos, confirmed: confirmed)
            if isCatalogStale(gen) {
                await abandonGroupAccessAfterCatalogChange(id: id, operation: operation)
                return
            }
            guard await sessionStill(startedIdentity) else {
                await releaseGroupAccessAfterSessionChange(id: id, operation: operation)
                return
            }
            let authorityHost = URL(string: (await installer.readLocalRegistration(directory: verified.directory))?.gitHubURL ?? "")?.host ?? verified.entry.serverHost ?? auth.identity.serverHost
            // A newer Load/Apply on this runner owns the editor now; this
            // completion stores and publishes nothing, not even cleanup.
            guard ownsGroupAccess(id: id, operation: operation) else { return }
            let authority = Runners.EditorAuthority(
                serverHost: authorityHost,
                org: verified.org, agentID: verified.agentID, agentName: verified.agentName,
                canonicalPath: RunnerCatalogStore.canonical(verified.directory),
                localID: verified.entry.localID
            )
            editorAuthorities[verified.entry.serviceLabel] = authority
            editorInvalidated.remove(verified.entry.serviceLabel)
            let access = Runners.GroupAccess(
                group: fresh, repoIDs: confirmed.sorted(), updatedAt: now(),
                owned: true, loading: false, authority: authority
            )
            await publishGroupAccessIfCurrent(id: id, operation: operation) {
                Runners.Action.groupAccessLoaded(id, access)
            }
            await publishGroupAccessIfCurrent(id: id, operation: operation) {
                Runners.Action.catalogCleared
            }
        } catch is CancellationError {
            await abandonGroupAccessAfterCatalogChange(id: id, operation: operation)
        } catch {
            if !isCatalogStale(gen), await sessionStill(startedIdentity) {
                let message = (error as? LocalizedError)?.localizedDescription ?? error.localizedDescription
                await publishGroupAccessIfCurrent(id: id, operation: operation) {
                    Runners.Action.groupAccessFailed(id, message)
                }
            } else if !isCatalogStale(gen) {
                await releaseGroupAccessAfterSessionChange(id: id, operation: operation)
            } else {
                await abandonGroupAccessAfterCatalogChange(id: id, operation: operation)
            }
        }
    }

    // MARK: - Group-access operation ownership

    /// Mints a fresh unique owner for this editor. Every Load/Apply calls
    /// this before publishing its loading state. The identity is never
    /// reused across remove/relink/re-import: a later operation mints a new
    /// UUID that an in-flight predecessor cannot equal.
    private func beginGroupAccessOperation(id: String) -> UUID {
        let owner = UUID()
        groupAccessOwner[id] = owner
        return owner
    }

    /// True when this operation is still the current owner of the editor.
    private func ownsGroupAccess(id: String, operation: UUID) -> Bool {
        groupAccessOwner[id] == operation
    }

    /// Drops the operation ownership for both id spellings of an entry, so
    /// an in-flight Load/Apply can neither publish into nor release the
    /// editor after the entry is removed or relinked. The dropped identity
    /// is never reused: the next operation mints a fresh UUID.
    private func dropGroupAccessOwnership(serviceLabel: String, localID: String) {
        groupAccessOwner.removeValue(forKey: serviceLabel)
        groupAccessOwner.removeValue(forKey: localID)
    }

    /// Publishes only when this operation still owns the editor. A stale
    /// completion — superseded by a newer Load/Apply on the same runner —
    /// publishes nothing: no cleared busy state, no stale data.
    private func publishGroupAccessIfCurrent(
        id: String, operation: UUID, makeAction: @Sendable () -> Runners.Action
    ) async {
        guard ownsGroupAccess(id: id, operation: operation) else { return }
        await action { makeAction() }
    }

    /// Releases the busy state after a session invalidation, but only when
    /// this operation still owns the editor. Publishes an explicit retry
    /// message instead of stale data, so the UI returns to Load/refresh
    /// instead of wedging on a spinner.
    private func releaseGroupAccessAfterSessionChange(id: String, operation: UUID) async {
        guard ownsGroupAccess(id: id, operation: operation) else { return }
        await action {
            Runners.Action.groupAccessFailed(
                id,
                "GitHub session changed during group access. Reload group access to retry in the current session."
            )
        }
    }

    /// Releases the busy state after the catalog changed under this
    /// operation, but only when this operation still owns the editor and the
    /// entry still exists. A removed entry needs no publication: its removal
    /// already pruned the editor state. A relinked entry was already
    /// released by its explicit invalidation.
    private func abandonGroupAccessAfterCatalogChange(id: String, operation: UUID) async {
        guard ownsGroupAccess(id: id, operation: operation) else { return }
        let entries = await catalog.load()
        // A newer Load/Apply may have taken ownership while this catalog
        // read was in flight; re-check before publishing anything.
        guard ownsGroupAccess(id: id, operation: operation) else { return }
        guard let entry = entries.first(where: { $0.serviceLabel == id || $0.localID == id }) else { return }
        guard !editorInvalidated.contains(entry.serviceLabel) else { return }
        await action {
            Runners.Action.groupAccessFailed(
                id,
                "Runner catalog changed during group access. Reload group access to retry."
            )
        }
    }

    /// Looks up the immutable Load-time editor authority for this runner, if
    /// a Load established one. Keyed by the stable service label.
    private func storedEditorAuthority(id: String) async -> Runners.EditorAuthority? {
        let entries = await catalog.load()
        guard let entry = entries.first(where: { $0.serviceLabel == id || $0.localID == id }) else { return nil }
        return editorAuthorities[entry.serviceLabel]
    }

    /// True when a relocation or identity change invalidated the editor and
    /// an explicit Load is required before the next Apply.
    private func editorRequiresReload(id: String) async -> Bool {
        let entries = await catalog.load()
        guard let entry = entries.first(where: { $0.serviceLabel == id || $0.localID == id }) else { return false }
        return editorInvalidated.contains(entry.serviceLabel)
    }
}

/// Import gates. Each gate refuses a concrete invalid class; negative tests
/// narrow every one of them.
public enum RunnersCatalogGates {
    public static func validateImportable(_ candidate: RunnerDiscovery.Candidate) throws {
        if candidate.controllerKind == .unsupported || candidate.unsupportedReason != nil {
            throw RunnerError.unsupported(candidate.unsupportedReason ?? "Unsupported management.")
        }
        if !candidate.registrationReadable {
            throw RunnerError.message("Cannot read .runner registration.")
        }
        if candidate.agentName == nil || candidate.agentName?.isEmpty == true {
            throw RunnerError.message("Registration name is missing.")
        }
        if candidate.serverHost == nil || candidate.scope == nil {
            throw RunnerError.message("Server or scope is undefined.")
        }
        if !candidate.noSpacePath || !candidate.noSpaceWork {
            throw RunnerError.noSpacePath("Path or work folder contains a space; relocation is required.")
        }
        if !candidate.runsvcExists || !candidate.binaryExists {
            throw RunnerError.message("Runner binaries are missing (run.sh / runsvc.sh).")
        }
        if candidate.manifest == nil {
            // Folder imports without a manifest create a service; every other
            // check above must already have passed.
            return
        }
        if !candidate.manifestMatches {
            throw RunnerError.manifestMismatch("Service manifest does not match the runner directory.")
        }
        if !candidate.issues.isEmpty {
            // Issues beyond the manifest notice (folder imports) refuse.
            let blocking = candidate.issues.filter { !$0.contains("No service manifest") }
            if !blocking.isEmpty {
                throw RunnerError.message(blocking.joined(separator: " "))
            }
        }
    }
}
