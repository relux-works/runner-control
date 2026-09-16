import Foundation
import Relux

extension RunnerRegistration.State {
    public func reduce(with action: any Relux.Action) async {
        guard let action = action as? RunnerRegistration.Action else { return }
        if reduceDraftAction(action) { return }
        if reduceProgressAction(action) { return }
        await reduceResultAction(action)
    }

    /// Draft lifecycle actions. Returns true when the action was handled.
    private func reduceDraftAction(_ action: RunnerRegistration.Action) -> Bool {
        switch action {
        case .draftBegan(let draft):
            self.draft = draft
            phase = .drafting
            group = nil
            groupRepositoryIDs = []
            asset = nil
            installPath = nil
            runnerID = nil
            localAgentID = nil
            completedSteps = []
            error = nil
            failedStep = nil
        case .draftUpdated(let draft):
            if let old = self.draft {
                invalidateProgress(old: old, new: draft)
            }
            self.draft = draft
            // Draft edits retain the permission error by design.
            if error != nil, permissionError == nil {
                error = nil
                failedStep = nil
            }
        case .cancelled:
            working = false
            error = nil
            failedStep = nil
        default:
            return false
        }
        return true
    }

    /// Invalidates cached progress bound to the changed identity fields, so a
    /// scope/install/name/group/work-folder edit never displays another
    /// registration's evidence as this draft's. Mirrors the Flow's
    /// invalidation. Group is part of the config identity: a group edit drops
    /// registration evidence as well.
    private func invalidateProgress(old: RunnerRegistration.Draft, new: RunnerRegistration.Draft) {
        if old.scope != new.scope {
            group = nil
            groupRepositoryIDs = []
            asset = nil
            installPath = nil
            runnerID = nil
            localAgentID = nil
            completedSteps = []
            failedStep = nil
            if phase == .done { phase = .drafting }
            return
        }
        if old.installDirName != new.installDirName {
            installPath = nil
            runnerID = nil
            localAgentID = nil
            completedSteps.subtract(["downloadAndInstall", "registerRunner", "setupService", "applyLabels"])
            if ["downloadAndInstall", "registerRunner", "setupService", "applyLabels"].contains(failedStep ?? "") {
                failedStep = nil
            }
            if phase == .done { phase = .drafting }
        }
        let oldName = old.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = new.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldName != newName {
            runnerID = nil
            localAgentID = nil
            completedSteps.subtract(["registerRunner", "setupService", "applyLabels"])
            if ["registerRunner", "setupService", "applyLabels"].contains(failedStep ?? "") {
                failedStep = nil
            }
            if phase == .done { phase = .drafting }
        }
        let oldIsOrg: Bool = if case .organization = old.scope { true } else { false }
        let newIsOrg: Bool = if case .organization = new.scope { true } else { false }
        if oldIsOrg || newIsOrg {
            let oldGroup = old.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            let newGroup = new.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            if oldGroup != newGroup {
                group = nil
                groupRepositoryIDs = []
                runnerID = nil
                localAgentID = nil
                completedSteps.subtract([
                    "resolveGroup", "applyRepositoryAccess",
                    "registerRunner", "setupService", "applyLabels",
                ])
                if ["resolveGroup", "applyRepositoryAccess", "registerRunner", "setupService", "applyLabels"]
                    .contains(failedStep ?? "") {
                    failedStep = nil
                }
                if phase == .done { phase = .drafting }
            }
        }
        if old.workFolder != new.workFolder {
            runnerID = nil
            localAgentID = nil
            completedSteps.subtract(["registerRunner", "setupService", "applyLabels"])
            if ["registerRunner", "setupService", "applyLabels"].contains(failedStep ?? "") {
                failedStep = nil
            }
            if phase == .done { phase = .drafting }
        }
    }

    /// Step progress actions. Returns true when the action was handled.
    private func reduceProgressAction(_ action: RunnerRegistration.Action) -> Bool {
        switch action {
        case .stepStarted(let step):
            working = true
            error = nil
            failedStep = nil
            reducePhase(step)
        case .stepFinished(let step):
            working = false
            completedSteps.insert(step)
        case .permissionDismissed:
            permissionError = nil
        default:
            return false
        }
        return true
    }

    private func reducePhase(_ step: String) {
        switch step {
        case "resolveGroup": phase = .resolvingGroup
        case "prepareDownload": phase = .preparingDownload
        case "downloadAndInstall": phase = .installing
        case "registerRunner": phase = .registering
        case "setupService": phase = .settingUpService
        default: break
        }
    }

    /// Fetched results, failures, and reset.
    private func reduceResultAction(_ action: RunnerRegistration.Action) async {
        if reduceFetchResult(action) { return }
        switch action {
        case .failed(let message, let step):
            working = false
            error = message
            failedStep = step
        case .permissionDenied(let message, let step):
            working = false
            error = message
            failedStep = step
            permissionError = message
        case .didReset:
            await cleanup()
        default:
            break
        }
    }

    /// Fetched values applied to state. Returns true when handled.
    private func reduceFetchResult(_ action: RunnerRegistration.Action) -> Bool {
        switch action {
        case .groupResolved(let group, let repositoryIDs):
            self.group = group
            groupRepositoryIDs = repositoryIDs
        case .downloadReady(let asset):
            self.asset = asset
        case .installed(let path):
            installPath = path
        case .registered(let runnerID, let localAgentID):
            self.runnerID = runnerID
            self.localAgentID = localAgentID
        case .serviceReady:
            phase = .done
        case .repositoryAccessApplied(let ids):
            groupRepositoryIDs = ids
            syncDraftRepositories(ids)
        case .labelsApplied(let labels):
            syncDraftLabels(labels)
        default:
            return false
        }
        return true
    }

    private func syncDraftRepositories(_ ids: [Int64]) {
        if var current = draft {
            current.selectedRepositoryIDs = Set(ids)
            draft = current
        }
    }

    private func syncDraftLabels(_ labels: [String]) {
        if var current = draft {
            current.labels = labels
            draft = current
        }
    }
}
