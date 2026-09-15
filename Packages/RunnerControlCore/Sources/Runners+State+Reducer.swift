import Relux
extension Runners.State {
    public func reduce(with action: any Relux.Action) async {
        guard let action = action as? Runners.Action else { return }
        switch action {
        case .refreshed(let snapshots): runners = snapshots
        case .changing(let id, let value):
            if value { changing.insert(id) } else { changing.remove(id) }
        case .failed(let message): lastError = message
        case .clearError: lastError = nil
        }
    }
}
