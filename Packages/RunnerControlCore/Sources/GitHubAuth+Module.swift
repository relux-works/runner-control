import Relux

extension GitHubAuth {
    @MainActor public struct Module: Relux.Module {
        nonisolated public var states: [any Relux.AnyState] { [state] }
        nonisolated public var sagas: [any Relux.Saga] { [flow] }
        public let state: State
        public let flow: Flow
        public init(state: State, flow: Flow) { self.state = state; self.flow = flow }
    }
}
