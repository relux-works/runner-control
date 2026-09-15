import Combine
import Relux
extension Runners {
    @MainActor public final class State: ObservableObject, Relux.HybridState {
        @Published public internal(set) var runners: [Snapshot]
        @Published public internal(set) var changing: Set<String> = []
        @Published public internal(set) var lastError: String?
        public init(definitions: [Definition] = Definition.installed()) { runners = definitions.map { Snapshot(definition: $0) } }
        public var activeCount: Int { runners.filter { $0.status == .running }.count }
        public func cleanup() async {
            runners = runners.map { Snapshot(definition: $0.definition) }; changing = []; lastError = nil
        }
    }
    public enum Action: Relux.Action {
        case refreshed([Snapshot])
        case changing(String, Bool)
        case failed(String)
        case clearError
    }
    public enum Effect: Relux.Effect {
        case refresh
        case setEnabled(String, Bool)
    }
}
