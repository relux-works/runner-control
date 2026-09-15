import Foundation
public protocol RunnerServicing: Sendable {
    func snapshots() async -> [Runners.Snapshot]
    func setEnabled(_ enabled: Bool, id: String) async throws
}
public actor LaunchAgentService: RunnerServicing {
    private let definitions: [Runners.Definition]
    private let executor: any CommandExecuting
    private let domain: String
    public init(definitions: [Runners.Definition] = Runners.Definition.installed(), executor: any CommandExecuting = CommandExecutor(), userID: UInt32 = getuid()) {
        self.definitions = definitions; self.executor = executor; domain = "gui/\(userID)"
    }
    public static func status(from result: CommandResult) -> Runners.Status {
        if result.code == 0 { return result.output.contains("state = running") ? .running : .failed }
        if result.code == 113 && result.output.contains("Could not find service") { return .stopped }
        return .unknown
    }
    private func validate(_ definition: Runners.Definition) throws {
        let data = try Data(contentsOf: definition.plist)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == definition.id,
              let args = plist["ProgramArguments"] as? [String],
              args == [definition.directory.appendingPathComponent("runsvc.sh").path],
              plist["WorkingDirectory"] as? String == definition.directory.path else {
            throw RunnerError.message("Настройки службы не соответствуют раннеру \(definition.title).")
        }
        guard !definition.directory.path.contains(" ") else { throw RunnerError.message("Путь раннера содержит пробел. Исправьте путь перед запуском.") }
        let registration = try Data(contentsOf: definition.directory.appendingPathComponent(".runner"))
        // GitHub writes a UTF-8 BOM; JSONSerialization accepts it.
        guard let object = try JSONSerialization.jsonObject(with: registration) as? [String: Any],
              let work = object["workFolder"] as? String, !work.contains(" ") else {
            throw RunnerError.message("Рабочий каталог раннера отсутствует или содержит пробел.")
        }
    }
    public func snapshots() async -> [Runners.Snapshot] {
        var values: [Runners.Snapshot] = []
        for d in definitions {
            do {
                try validate(d)
                let result = try await executor.run("/bin/launchctl", ["print", domain + "/" + d.id])
                let status = Self.status(from: result)
                values.append(.init(definition: d, status: status, message: status == .unknown ? String(result.output.prefix(300)) : nil))
            } catch { values.append(.init(definition: d, status: .missing, message: error.localizedDescription)) }
        }
        return values
    }
    public func setEnabled(_ enabled: Bool, id: String) async throws {
        guard let d = definitions.first(where: { $0.id == id }) else { throw RunnerError.message("Неизвестный раннер.") }
        // Stop must remain possible even if someone damages registration/plist.
        if enabled { try validate(d) }
        let key = domain + "/" + d.id
        let current = try await executor.run("/bin/launchctl", ["print", key])
        let state = Self.status(from: current)
        if !enabled && state == .stopped || enabled && state == .running { return }
        guard state != .unknown else { throw RunnerError.message(String(current.output.prefix(500))) }
        if enabled && state == .failed {
            let removed = try await executor.run("/bin/launchctl", ["bootout", key])
            guard removed.code == 0 else { throw RunnerError.message(removed.output) }
        }
        let result = try await executor.run("/bin/launchctl", enabled ? ["bootstrap", domain, d.plist.path] : ["bootout", key])
        guard result.code == 0 else { throw RunnerError.message(String(result.output.prefix(700))) }
        for _ in 0..<30 {
            let result = try await executor.run("/bin/launchctl", ["print", key])
            if Self.status(from: result) == (enabled ? .running : .stopped) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RunnerError.message("Служба не подтвердила изменение состояния. Проверьте журнал раннера.")
    }
}
