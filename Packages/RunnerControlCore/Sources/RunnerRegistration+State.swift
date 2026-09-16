import Combine
import Foundation
import Relux

extension RunnerRegistration {
    /// Wizard phases. Holds IDs, paths, and errors — never tokens.
    public enum Phase: Sendable, Equatable {
        case idle
        case drafting
        case resolvingGroup
        case preparingDownload
        case installing
        case registering
        case settingUpService
        case done
    }

    @MainActor public final class State: ObservableObject, Relux.HybridState {
        @Published public internal(set) var phase: Phase = .idle
        @Published public internal(set) var draft: Draft?
        @Published public internal(set) var working: Bool = false
        @Published public internal(set) var group: RunnerGroup?
        @Published public internal(set) var groupRepositoryIDs: [Int64] = []
        @Published public internal(set) var asset: DownloadAsset?
        @Published public internal(set) var installPath: String?
        @Published public internal(set) var runnerID: Int64?
        @Published public internal(set) var localAgentID: Int64?
        @Published public internal(set) var completedSteps: Set<String> = []
        @Published public internal(set) var error: String?
        @Published public internal(set) var failedStep: String?
        /// Retained permission errors (403/missing rights). Draft edits never
        /// clear them; only an explicit retry, reset, or dismiss does.
        @Published public internal(set) var permissionError: String?

        public init() {}

        public func cleanup() async {
            phase = .idle
            draft = nil
            working = false
            group = nil
            groupRepositoryIDs = []
            asset = nil
            installPath = nil
            runnerID = nil
            localAgentID = nil
            completedSteps = []
            error = nil
            failedStep = nil
            permissionError = nil
        }
    }

    public enum Action: Relux.Action {
        case draftBegan(Draft)
        case draftUpdated(Draft)
        case stepStarted(String)
        case stepFinished(String)
        case groupResolved(RunnerGroup, repositoryIDs: [Int64])
        case downloadReady(DownloadAsset)
        case installed(path: String)
        case registered(runnerID: Int64?, localAgentID: Int64?)
        case serviceReady(plistPath: String)
        case repositoryAccessApplied([Int64])
        case labelsApplied([String])
        case failed(message: String, step: String)
        case permissionDenied(message: String, step: String)
        case permissionDismissed
        case cancelled
        case didReset
    }

    public enum Effect: Relux.Effect {
        case beginDraft(Draft)
        case updateDraft(Draft)
        case resolveGroup
        case prepareDownload
        case downloadAndInstall
        case registerRunner
        case setupService
        case applyRepositoryAccess(groupID: Int64, repositories: Set<Int64>)
        case applyLabels([String])
        case retry
        case cancel
        case reset
        case dismissPermission
    }
}
