import Foundation
extension Runners {
    public struct Definition: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let detail: String
        public let directory: URL
        public let githubURL: URL
        private let servicePlist: URL?
        /// Catalog identity. Nil for legacy discovery-only rows.
        public let localID: String?
        public let controllerKind: ControllerKind
        /// Preserved launch-at-login policy of the imported service.
        /// Nil means unknown (e.g. unsupported control).
        public let runAtLoad: Bool?
        /// User display override. Renaming on GitHub never changes identity.
        public let displayName: String?
        public let serverHost: String?
        public let remoteAgentID: Int64?
        public let workFolder: String?
        public init(
            id: String, title: String, detail: String, directory: URL, githubURL: URL,
            servicePlist: URL? = nil, localID: String? = nil,
            controllerKind: ControllerKind? = nil, runAtLoad: Bool? = nil,
            displayName: String? = nil, serverHost: String? = nil,
            remoteAgentID: Int64? = nil, workFolder: String? = nil,
            loginEnabled: Bool? = nil
        ) {
            self.id = id; self.title = title; self.detail = detail
            self.directory = directory; self.githubURL = githubURL; self.servicePlist = servicePlist
            self.localID = localID
            if let controllerKind {
                self.controllerKind = controllerKind
            } else {
                let path = (servicePlist ?? directory.appendingPathComponent("manual-service.plist")).path
                self.controllerKind = path.contains("/Library/LaunchAgents/") ? .standardLaunchAgent : .manualManaged
            }
            self.runAtLoad = runAtLoad
            self.displayName = displayName
            self.serverHost = serverHost
            self.remoteAgentID = remoteAgentID
            self.workFolder = workFolder
            self.loginEnabled = loginEnabled
        }
        public var plist: URL { servicePlist ?? directory.appendingPathComponent("manual-service.plist") }
        /// Effective login-start behavior. Standard manifests use their own
        /// RunAtLoad; external manual plists are ON only when a matching
        /// registration exists in `~/Library/LaunchAgents` with RunAtLoad
        /// true — RunAtLoad outside LaunchAgents never persists login start.
        /// Nil means unknown (e.g. unsupported control).
        public let loginEnabled: Bool?
        public func withLoginEnabled(_ value: Bool?) -> Definition {
            Definition(
                id: id, title: title, detail: detail, directory: directory,
                githubURL: githubURL, servicePlist: servicePlist, localID: localID,
                controllerKind: controllerKind, runAtLoad: runAtLoad,
                displayName: displayName, serverHost: serverHost,
                remoteAgentID: remoteAgentID, workFolder: workFolder,
                loginEnabled: value
            )
        }
        /// Display title: user alias wins, otherwise the registration name.
        public var displayTitle: String {
            if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return displayName
            }
            return title
        }
        /// Legacy log directory fallback. Production log access resolves the
        /// actual StandardOutPath/StandardErrorPath from the manifest plus
        /// `_diag` via `RunnerDiagnostics`; this path is only a fallback.
        public var logs: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/" + id) }
        public static func installed(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Self] {
            RunnerDiscovery.installed(home: home)
        }
    }
    public enum Status: String, Sendable, Equatable {
        case checking, stopped, starting, running, stopping, failed, missing, needsSetup, unknown
        public var title: String {
            switch self {
            case .checking: "Проверяем…"
            case .stopped: "Выключен"
            case .starting: "Запускается"
            case .running: "Служба включена"
            case .stopping: "Выключается"
            case .failed: "Ошибка службы"
            case .missing: "Раннер не найден"
            case .needsSetup: "Требуется настройка"
            case .unknown: "Статус недоступен"
            }
        }
    }
    /// Operation phase for one row. Only the affected row is locked.
    public enum OperationPhase: String, Sendable, Equatable {
        case idle, starting, stopping
    }
    /// GitHub observation kept separate from the local service state.
    /// Loss of network never turns a running service into a stopped one.
    public struct RemoteObservation: Sendable, Equatable {
        public var online: Bool?
        public var busy: Bool?
        /// False when GitHub is disconnected, stale, or the runner is absent.
        public var busyKnown: Bool
        public var labels: [String]
        public var group: String?
        public var updatedAt: Date?
        public var stale: Bool
        public var syncError: String?
        public init(
            online: Bool? = nil, busy: Bool? = nil, busyKnown: Bool = false,
            labels: [String] = [], group: String? = nil,
            updatedAt: Date? = nil, stale: Bool = true, syncError: String? = nil
        ) {
            self.online = online; self.busy = busy; self.busyKnown = busyKnown
            self.labels = labels; self.group = group
            self.updatedAt = updatedAt; self.stale = stale; self.syncError = syncError
        }
        /// Truthful GitHub signature. Stale `busy=false` is never presented
        /// as proof of an idle runner.
        public var signature: String {
            if stale { return "GitHub: данные устарели" }
            if let error = syncError, !error.isEmpty { return "GitHub: \(error)" }
            guard let online else { return "GitHub: не подключён" }
            if !online { return "GitHub: не в сети" }
            if !busyKnown { return "GitHub: занятость неизвестна" }
            return (busy == true) ? "GitHub: занят" : "GitHub: готов"
        }
    }
    public struct Snapshot: Identifiable, Sendable, Equatable {
        public let definition: Definition
        public var status: Status
        public var message: String?
        public var remote: RemoteObservation?
        public var operation: OperationPhase
        public var observedAt: Date?
        public var id: String { definition.id }
        public init(
            definition: Definition, status: Status = .checking, message: String? = nil,
            remote: RemoteObservation? = nil, operation: OperationPhase = .idle,
            observedAt: Date? = nil
        ) {
            self.definition = definition; self.status = status; self.message = message
            self.remote = remote; self.operation = operation; self.observedAt = observedAt
        }
    }

    /// Immutable verified registration tuple captured when group access is
    /// loaded. Apply consumes this tuple and refuses when the current
    /// disk/catalog identity no longer matches it, instead of reconstructing
    /// authority from mutable current inputs. A relocation or scope/server
    /// change invalidates the editor and requires an explicit Load.
    public struct EditorAuthority: Sendable, Equatable {
        public let serverHost: String
        public let org: String
        public let agentID: Int64
        public let agentName: String
        public let canonicalPath: String
        public let localID: String
        public init(serverHost: String, org: String, agentID: Int64, agentName: String, canonicalPath: String, localID: String) {
            self.serverHost = serverHost; self.org = org
            self.agentID = agentID; self.agentName = agentName
            self.canonicalPath = canonicalPath; self.localID = localID
        }
    }

    /// Fresh API group membership for one org runner. Local `.runner`
    /// pool fields can lag server-side moves, so display and access editing
    /// always use this API answer, matched by agent ID, never by name.
    public struct GroupAccess: Sendable, Equatable {
        public var group: RunnerRegistration.RunnerGroup?
        public var repoIDs: [Int64]
        public var updatedAt: Date?
        /// True when this Mac created or explicitly took over the group on
        /// this server (locally recorded ownership). Shared/imported groups
        /// require explicit takeover before any edit.
        public var owned: Bool
        public var loading: Bool
        public var error: String?
        /// Immutable authority this editor was verified against. Nil for
        /// legacy/loading states without a verified load.
        public var authority: EditorAuthority?
        public init(
            group: RunnerRegistration.RunnerGroup? = nil,
            repoIDs: [Int64] = [],
            updatedAt: Date? = nil,
            owned: Bool = false,
            loading: Bool = false,
            error: String? = nil,
            authority: EditorAuthority? = nil
        ) {
            self.group = group; self.repoIDs = repoIDs; self.updatedAt = updatedAt
            self.owned = owned; self.loading = loading; self.error = error
            self.authority = authority
        }
    }
    /// Stop-confirmation copy. Busy, unknown and stale states are never
    /// silently treated as idle; the first universal version always confirms
    /// stopping a running service.
    public enum StopConfirmation {
        /// True when stopping may interrupt a job: busy, unknown, stale,
        /// disconnected, or error. Only a fresh idle observation returns false,
        /// and even that still confirms (race with new job assignment).
        public static func mayInterrupt(remote: RemoteObservation?) -> Bool {
            guard let remote, !remote.stale, remote.syncError == nil else { return true }
            guard remote.busyKnown, let busy = remote.busy else { return true }
            return busy
        }

        public static func message(remote: RemoteObservation?, runnerTitle: String) -> String {
            if let remote, !remote.stale, remote.syncError == nil, remote.busyKnown, remote.busy == true {
                return "На раннере «\(runnerTitle)» выполняется задача. Выключение прервёт её."
            }
            if let remote, !remote.stale, remote.syncError == nil, remote.busyKnown, remote.busy == false {
                return "Раннер «\(runnerTitle)» сейчас свободен, но новая задача может быть назначена в любой момент. Остановить службу?"
            }
            return "Занятость раннера «\(runnerTitle)» неизвестна (GitHub не подключён, данные устарели или runner не найден). Выключение может прервать задачу."
        }
    }
}
