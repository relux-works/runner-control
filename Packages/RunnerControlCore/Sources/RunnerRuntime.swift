import Foundation
import Relux
import OSLog
@MainActor public enum RunnerRuntime {
    public static func make(state: Runners.State, service: any RunnerServicing = LaunchAgentService()) async -> Relux {
        let runtime = await Relux(logger: RuntimeLogger())
        let flow = await Runners.Flow(service: service, dispatcher: runtime.dispatcher)
        runtime.register(Runners.Module(state: state, flow: flow))
        return runtime
    }
}
struct RuntimeLogger: Relux.Logger {
    func logAction(_ action: Relux.EnumReflectable, result: Relux.ActionResult?, startTimeInMillis: Int, privacy: Relux.OSLogPrivacy, fileID: String, functionName: String, lineNumber: Int) {
        Logger(subsystem: "works.relux.runnercontrol", category: "state").debug("State event: \(String(describing: type(of: action)), privacy: .public)")
    }
}
