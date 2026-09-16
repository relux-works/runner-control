import Foundation
public protocol RunnerServicing: Sendable {
    func snapshots() async -> [Runners.Snapshot]
    func setEnabled(_ enabled: Bool, id: String) async throws
}
public actor LaunchAgentService: RunnerServicing {
    private let fixedDefinitions: [Runners.Definition]?
    private let catalog: RunnerCatalogStore?
    private let executor: any CommandExecuting
    private let domain: String
    private let home: URL
    public init(definitions: [Runners.Definition] = Runners.Definition.installed(), executor: any CommandExecuting = CommandExecutor(), userID: UInt32 = getuid(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fixedDefinitions = definitions; self.catalog = nil; self.executor = executor; domain = "gui/\(userID)"; self.home = home
    }
    /// Catalog-backed service. Snapshots always reflect the current catalog;
    /// fixed definitions are used only when no catalog is supplied (tests).
    public init(catalog: RunnerCatalogStore, executor: any CommandExecuting = CommandExecutor(), userID: UInt32 = getuid(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fixedDefinitions = nil; self.catalog = catalog; self.executor = executor; domain = "gui/\(userID)"; self.home = home
    }
    public static func status(from result: CommandResult) -> Runners.Status {
        if result.code == 0 { return result.output.contains("state = running") ? .running : .failed }
        if result.code == 113 && result.output.contains("Could not find service") { return .stopped }
        return .unknown
    }
    private func currentDefinitions() async -> [Runners.Definition] {
        if let catalog {
            let entries = await catalog.load()
            return entries.map { Self.definition(from: $0) }
        }
        return fixedDefinitions ?? []
    }
    /// Builds a definition from a catalog entry, resolving the stored
    /// bookmark when present and refreshing the RunAtLoad policy from disk
    /// so the UI always shows the preserved policy, never a stale copy.
    static func definition(from entry: RunnerCatalogStore.Entry) -> Runners.Definition {
        let directory = RunnerCatalogStore.resolve(entry: entry)
        let plist = URL(fileURLWithPath: entry.servicePlistPath)
        let runAtLoad: Bool? = {
            guard let data = try? Data(contentsOf: plist),
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return entry.runAtLoad
            }
            return (object["RunAtLoad"] as? Bool) ?? entry.runAtLoad
        }()
        let githubURL: URL = {
            if let host = entry.serverHost, let scope = entry.scope, let kind = entry.scopeKind {
                let base = host == "github.com" ? "https://github.com" : "https://\(host)"
                let path = kind == "org" ? "/organizations/\(scope)/settings/actions/runners" : "/\(scope)/settings/actions/runners"
                if let url = URL(string: base + path) { return url }
            }
            return URL(string: "https://github.com")!
        }()
        return Runners.Definition(
            id: entry.serviceLabel, title: entry.agentName ?? directory.lastPathComponent,
            detail: entry.scope ?? "", directory: directory, githubURL: githubURL,
            servicePlist: plist, localID: entry.localID,
            controllerKind: entry.controllerKind, runAtLoad: runAtLoad,
            displayName: entry.displayName, serverHost: entry.serverHost,
            remoteAgentID: entry.remoteAgentID, workFolder: entry.workFolder
        )
    }
    private func validate(_ definition: Runners.Definition) throws {
        try RunnerControllers.validateForStart(definition)
    }
    public func snapshots() async -> [Runners.Snapshot] {
        let definitions = await currentDefinitions()
        let now = Date()
        let home = self.home
        var values: [Runners.Snapshot] = []
        for raw in definitions {
            // Effective login is computed per snapshot so the toggle always
            // reflects real login behavior, never a stale copy.
            let d = raw.withLoginEnabled(RunnerControllers.effectiveLogin(raw, home: home))
            // Unsupported entries are still inspected via launchctl so a
            // running foreign service is visible; control stays refused.
            if d.controllerKind == .unsupported {
                do {
                    let result = try await executor.run("/bin/launchctl", ["print", domain + "/" + d.id])
                    let status = Self.status(from: result)
                    let reason = "Unsupported management: control it with its own supervisor."
                    let message = status == .unknown ? String(result.output.prefix(300)) : reason
                    values.append(.init(definition: d, status: status, message: message, observedAt: now))
                } catch {
                    values.append(.init(definition: d, status: .unknown, message: error.localizedDescription, observedAt: now))
                }
                continue
            }
            // Print first so a missing registration or damaged manifest never
            // hides a running service and its Stop.
            let printed: CommandResult?
            do {
                printed = try await executor.run("/bin/launchctl", ["print", domain + "/" + d.id])
            } catch {
                values.append(.init(definition: d, status: .unknown, message: error.localizedDescription, observedAt: now))
                continue
            }
            let launchStatus = Self.status(from: printed!)
            do {
                try validate(d)
                let message = launchStatus == .unknown ? String(printed!.output.prefix(300)) : nil
                values.append(.init(definition: d, status: launchStatus, message: message, observedAt: now))
            } catch {
                // A running service stays visible (and stoppable) even when
                // registration or manifest is damaged.
                if launchStatus == .running {
                    values.append(.init(definition: d, status: .running, message: error.localizedDescription, observedAt: now))
                } else if let runnerError = error as? RunnerError, case .noSpacePath = runnerError {
                    values.append(.init(definition: d, status: .needsSetup, message: error.localizedDescription, observedAt: now))
                } else {
                    values.append(.init(definition: d, status: .missing, message: error.localizedDescription, observedAt: now))
                }
            }
        }
        return values
    }
    public func setEnabled(_ enabled: Bool, id: String) async throws {
        let definitions = await currentDefinitions()
        guard let d = definitions.first(where: { $0.id == id }) else { throw RunnerError.message("Неизвестный раннер.") }
        if d.controllerKind == .unsupported {
            throw RunnerError.unsupported("Runner «\(d.displayTitle)» uses unsupported management. Control it with its own supervisor instead of Runner Control.")
        }
        // Stop must remain possible even if someone damages registration/plist.
        if enabled { try validate(d) }
        let key = domain + "/" + d.id
        let current = try await executor.run("/bin/launchctl", ["print", key])
        let state = Self.status(from: current)
        if !enabled && state == .stopped || enabled && state == .running { return }
        guard state != .unknown else { throw RunnerError.message(String(current.output.prefix(500))) }
        if enabled && state == .failed {
            let removed = try await executor.run("/bin/launchctl", ["bootout", key])
            guard removed.code == 0 else { throw RunnerError.message(removed.output) }
        }
        let result = try await executor.run("/bin/launchctl", enabled ? ["bootstrap", domain, d.plist.path] : ["bootout", key])
        guard result.code == 0 else { throw RunnerError.message(String(result.output.prefix(700))) }
        // RunAtLoad=false jobs load without starting, so bootstrap alone
        // never yields running. Kickstart the loaded-but-idle job once,
        // without -k, so a running service is never restarted. Disable
        // never kickstarts. Plist and login policy are untouched.
        var didKickstart = false
        for _ in 0..<30 {
            let result = try await executor.run("/bin/launchctl", ["print", key])
            let polled = Self.status(from: result)
            if polled == (enabled ? .running : .stopped) { return }
            if enabled, !didKickstart, polled == .failed {
                didKickstart = true
                let started = try await executor.run("/bin/launchctl", ["kickstart", key])
                guard started.code == 0 else { throw RunnerError.message(String(started.output.prefix(700))) }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if enabled {
            throw RunnerError.message("Не удалось подтвердить запуск. Проверьте журнал раннера и повторите проверку.")
        }
        throw RunnerError.message("Не удалось подтвердить остановку. Проверьте журнал раннера и повторите проверку.")
    }
}
