import Relux
extension Runners {
    public protocol IFlow: Relux.Flow {}
    public actor Flow {
        public let dispatcher: Relux.Dispatcher
        private let service: any RunnerServicing
        private var working: Set<String> = []
        private var refreshing = false
        private var revision = 0
        public init(service: any RunnerServicing, dispatcher: Relux.Dispatcher? = nil) async {
            self.service = service
            self.dispatcher = if let dispatcher { dispatcher } else { await Self.defaultDispatcher }
        }
    }
}
extension Runners.Flow: Runners.IFlow {
    public func apply(_ effect: any Relux.Effect) async -> Relux.ActionResult {
        guard let effect = effect as? Runners.Effect else { return .success }
        switch effect {
        case .refresh:
            guard !refreshing, working.isEmpty else { return .success }
            refreshing = true
            let startedAt = revision
            let snapshots = await service.snapshots()
            // Do not publish a stale read if a command started during this await.
            if working.isEmpty && revision == startedAt { await action { Runners.Action.refreshed(snapshots) } }
            refreshing = false
        case .setEnabled(let id, let enabled):
            guard !working.contains(id) else { return .success }
            working.insert(id)
            revision += 1
            await action { Runners.Action.changing(id, true) }
            do { try await service.setEnabled(enabled, id: id) }
            catch { await action { Runners.Action.failed(error.localizedDescription) } }
            let snapshots = await service.snapshots()
            await action { Runners.Action.refreshed(snapshots) }
            working.remove(id)
            await action { Runners.Action.changing(id, false) }
        }
        return .success
    }
}
