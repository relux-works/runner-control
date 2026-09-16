import Foundation
import Relux
extension Runners.State {
    public func reduce(with action: any Relux.Action) async {
        guard let action = action as? Runners.Action else { return }
        switch action {
        case .refreshed(let snapshots):
            // Preserve remote observations across local refreshes: a local
            // poll must never wipe GitHub state, and a missing registration
            // must never hide the running service.
            let previous = Dictionary(uniqueKeysWithValues: runners.compactMap { snapshot -> (String, Runners.RemoteObservation)? in
                guard let remote = snapshot.remote else { return nil }
                return (snapshot.id, remote)
            })
            runners = snapshots.map { snapshot in
                var next = snapshot
                if next.remote == nil, let kept = previous[snapshot.id] {
                    next.remote = kept
                }
                return next
            }
            // Prune group access for runners no longer in the catalog.
            let live = Set(snapshots.map(\.id))
            groupAccess = groupAccess.filter { live.contains($0.key) }
        case .changing(let id, let value):
            if value { changing.insert(id) } else { changing.remove(id) }
        case .failed(let message): lastError = message
        case .clearError: lastError = nil
        case .candidatesLoaded(let candidates): self.candidates = candidates
        case .catalogFailed(let message): catalogError = message
        case .catalogCleared: catalogError = nil
        case .selected(let id): selectedID = id
        case .unregistering(let id, let value):
            if value { unregistering.insert(id) } else { unregistering.remove(id) }
        case .remoteUpdated(let id, let observation):
            if let index = runners.firstIndex(where: { $0.id == id }) {
                var next = runners[index]
                next.remote = observation
                runners[index] = next
            }
        case .remoteSyncFinished(let date):
            lastRemoteSync = date
            remoteSyncError = nil
        case .remoteSyncFailed(let message):
            remoteSyncError = message
        case .logLoaded(let title, let excerpt):
            logPreviewTitle = title
            logPreview = excerpt
        case .logCleared:
            logPreviewTitle = nil
            logPreview = nil
        case .groupAccessLoading(let id):
            var current = groupAccess[id] ?? Runners.GroupAccess()
            current.loading = true
            current.error = nil
            groupAccess[id] = current
        case .groupAccessLoaded(let id, let access):
            groupAccess[id] = access
        case .groupAccessFailed(let id, let message):
            var current = groupAccess[id] ?? Runners.GroupAccess()
            current.loading = false
            current.error = message
            groupAccess[id] = current
        case .groupAccessInvalidated(let id, let message):
            groupAccess[id] = Runners.GroupAccess(loading: false, error: message)
        }
    }
}
