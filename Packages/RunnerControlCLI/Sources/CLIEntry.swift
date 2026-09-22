import ArgumentParser
import Foundation

/// `runner-control`: headless companion to the Runner Control GUI app.
///
/// Every command boots the same Relux runtime the GUI uses and dispatches
/// the same effects, against the same Keychain service, catalog file, and
/// defaults domain. Either surface can sign in, register, power, and
/// configure; neither can see live in-memory state of the other (each
/// process re-reads persistence per invocation), so prefer one writer at
/// a time for catalog edits.
@main
public struct RunnerControl: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "runner-control",
        abstract: "Headless control for Runner Control runners (1:1 with the GUI).",
        discussion: """
            Shares the GUI app's GitHub session, catalog, and settings on this Mac.
            Global flags (--json, --yes) come after the subcommand:

              runner-control runners list --json
              runner-control runners off --all --yes
            """,
        subcommands: [AuthCommand.self, RunnersCommand.self, RegisterCommand.self, AppCommand.self]
    )

    public init() {}

    public static func main() async {
        let command: any ParsableCommand
        do {
            command = try parseAsRoot()
        } catch {
            handleParse(error)
        }
        do {
            var runnable = command
            if var asyncCommand = runnable as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try runnable.run()
            }
        } catch {
            handle(error)
        }
    }

    /// How the main boundary treats an error: ArgumentParser's native
    /// handling (help/version only) or a mapped CLI exit with a message.
    enum ExitMapping: Equatable {
        case nativePassthrough
        case exit(CLIExit, String)
    }

    /// Help/version requests keep ArgumentParser's native handling (help
    /// on stdout, exit 0). `--help` parses into an internal `HelpCommand`
    /// whose `run()` throws a `CommandError` carrying the rendered help —
    /// indistinguishable by type from real parse errors (both internal),
    /// so help is recognized by ArgumentParser's own rendering, which
    /// always opens with the OVERVIEW section header. No error case emits
    /// that prefix. Matched against the pinned swift-argument-parser
    /// version; the blackbox `--help`/`help` tests fail loudly if a
    /// dependency update changes the shape.
    static func isHelpRequest(_ error: Error) -> Bool {
        if error is CleanExit {
            return true
        }
        let name = String(describing: type(of: error))
        if name == "HelpRequested" {
            return true
        }
        return name == "CommandError" && RunnerControl.message(for: error).hasPrefix("OVERVIEW:")
    }

    /// Parse-phase mapping: anything but help/version is a usage error,
    /// never ArgumentParser's 64. The message is ArgumentParser's own brief
    /// rendering (internal error types are not public). Pure for unit
    /// tests; `handleParse` renders it.
    static func mapParseError(_ error: Error) -> ExitMapping {
        if isHelpRequest(error) {
            return .nativePassthrough
        }
        return .exit(.usage, RunnerControl.message(for: error))
    }

    /// Run-phase mapping: CLIFailure keeps its code; every other
    /// operational error (URLError, decoding, unexpected) is failed(2),
    /// never usage(1) and never silent. Pure for unit tests.
    static func mapRunError(_ error: Error) -> ExitMapping {
        if let failure = error as? CLIFailure {
            return .exit(failure.code, failure.message)
        }
        if isHelpRequest(error) {
            return .nativePassthrough
        }
        return .exit(.failed, errorMessage(error))
    }

    static func handleParse(_ error: Error) -> Never {
        switch mapParseError(error) {
        case .nativePassthrough:
            RunnerControl.exit(withError: error)
        case .exit(let code, let message):
            if CommandLine.arguments.contains("--json") {
                Output.jsonError(message)
                Output.warn("runner-control: \(message)")
            } else {
                // Full native rendering (error + usage) for humans.
                Output.warn(RunnerControl.fullMessage(for: error))
            }
            Foundation.exit(code.rawValue)
        }
    }

    static func handle(_ error: Error) -> Never {
        switch mapRunError(error) {
        case .nativePassthrough:
            RunnerControl.exit(withError: error)
        case .exit(let code, let message):
            emit(code: code, message: message, hint: nil)
        }
    }

    private static func emit(code: CLIExit, message: String, hint: String?) -> Never {
        if CommandLine.arguments.contains("--json") {
            Output.jsonError(message)
        }
        Output.warn("runner-control: \(message)")
        if let hint, !CommandLine.arguments.contains("--json") {
            Output.warn(hint)
        }
        Foundation.exit(code.rawValue)
    }

    private static func errorMessage(_ error: Error) -> String {
        if let local = error as? LocalizedError, let described = local.errorDescription {
            return described
        }
        return error.localizedDescription
    }
}
