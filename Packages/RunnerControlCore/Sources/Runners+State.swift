import Combine
import Foundation
import Relux
extension Runners {
    @MainActor public final class State: ObservableObject, Relux.HybridState {
        @Published public internal(set) var runners: [Snapshot]
        @Published public internal(set) var changing: Set<String> = []
        @Published public internal(set) var lastError: String?
        @Published public internal(set) var candidates: [RunnerDiscovery.Candidate] = []
        @Published public internal(set) var catalogError: String?
        @Published public internal(set) var selectedID: String?
        @Published public internal(set) var unregistering: Set<String> = []
        @Published public internal(set) var remoteSyncError: String?
        @Published public internal(set) var lastRemoteSync: Date?
        @Published public internal(set) var logPreviewTitle: String?
        @Published public internal(set) var logPreview: String?
        @Published public internal(set) var groupAccess: [String: GroupAccess] = [:]
        public init(definitions: [Definition] = Definition.installed()) { runners = definitions.map { Snapshot(definition: $0) } }
        public var activeCount: Int { runners.filter { $0.status == .running }.count }
        public func cleanup() async {
            runners = runners.map { Snapshot(definition: $0.definition) }; changing = []; lastError = nil
            candidates = []; catalogError = nil; selectedID = nil; unregistering = []
            remoteSyncError = nil; lastRemoteSync = nil
            logPreviewTitle = nil; logPreview = nil; groupAccess = [:]
        }
    }
    public enum Action: Relux.Action {
        case refreshed([Snapshot])
        case changing(String, Bool)
        case failed(String)
        case clearError
        case candidatesLoaded([RunnerDiscovery.Candidate])
        case catalogFailed(String)
        case catalogCleared
        case selected(String?)
        case unregistering(String, Bool)
        case remoteUpdated(String, RemoteObservation)
        case remoteSyncFinished(Date)
        case remoteSyncFailed(String)
        case logLoaded(title: String, excerpt: String)
        case logCleared
        case groupAccessLoading(String)
        case groupAccessLoaded(String, GroupAccess)
        case groupAccessFailed(String, String)
        case groupAccessInvalidated(String, String)
    }
    public enum Effect: Relux.Effect {
        case refresh
        case setEnabled(String, Bool)
        case setEnabledMany([String], Bool)
        case loadCatalog
        case discover
        case importCandidate(RunnerDiscovery.Candidate)
        case importFolder(URL)
        case removeFromApp(String)
        case unregister(String, confirmation: String)
        case refreshRemote
        case setRunAtLoad(String, Bool)
        case setAlias(String, String?)
        case relinkDirectory(String, URL)
        case selectRunner(String?)
        case loadLog(String)
        case clearLog
        case loadGroupAccess(String)
        case applyGroupAccess(String, groupID: Int64, repositories: Set<Int64>, allowTakeover: Bool)
    }
}
