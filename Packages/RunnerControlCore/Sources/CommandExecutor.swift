import Foundation
public struct CommandResult: Sendable, Equatable {
    public let code: Int32
    public let output: String
    public init(code: Int32, output: String) { self.code = code; self.output = output }
}
public protocol CommandExecuting: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult
}
public enum RunnerError: LocalizedError, Sendable, Equatable {
    case message(String)
    case noSpacePath(String)
    case manifestMismatch(String)
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .noSpacePath(let text): text
        case .manifestMismatch(let text): text
        case .unsupported(let text): text
        }
    }
}
public actor CommandExecutor: CommandExecuting {
    public init() {}
    public func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        // File-backed output avoids pipe-buffer deadlocks from launchctl print.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while process.isRunning {
            if Task.isCancelled || ContinuousClock.now >= deadline {
                process.terminate()
                for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw RunnerError.message("Команда не завершилась вовремя. Обновите статус и попробуйте снова.")
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        let read = try FileHandle(forReadingFrom: url)
        defer { try? read.close() }
        let data = try read.read(upToCount: 131072) ?? Data()
        return CommandResult(code: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
