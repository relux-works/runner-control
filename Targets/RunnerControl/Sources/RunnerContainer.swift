import SwiftUI
import AppKit
import RunnerControlCore

struct RunnerContainer: View {
    @ObservedObject var state: Runners.State
    var body: some View {
        RunnerPage(
            props: .init(
                runners: state.runners, changing: state.changing,
                error: state.lastError, catalogError: state.catalogError,
                remoteSyncError: state.remoteSyncError
            ),
            reactions: .init(
                setEnabled: change,
                enableAll: enableAll,
                disableAll: { confirmStop(ids: runnableIDs(forStop: true)) },
                openGitHub: { NSWorkspace.shared.open($0.githubURL) },
                openLogs: openLogs,
                openDetails: { definition in
                    Task { await action { Runners.Effect.selectRunner(definition.id) } }
                    AppRegistry.openManagementWindow()
                },
                clearError: { Task { await action { Runners.Action.clearError } } },
                clearCatalogError: { Task { await action { Runners.Action.catalogCleared } } },
                addRunner: { AppRegistry.openManagementWindow() },
                openSettings: { AppRegistry.openManagementWindow() }
            )
        )
    }
    private func runnableIDs(forStop: Bool) -> [String] {
        state.runners.filter { snapshot in
            guard snapshot.definition.controllerKind.canControl else { return false }
            if forStop { return snapshot.status == .running || snapshot.status == .failed }
            return snapshot.status == .stopped || snapshot.status == .failed
        }.map(\.id)
    }
    private func enableAll() {
        let ids = runnableIDs(forStop: false)
        guard !ids.isEmpty else { return }
        Task { await action { Runners.Effect.setEnabledMany(ids, true) } }
    }
    private func change(_ id: String, _ enabled: Bool) {
        if enabled { Task { await action { Runners.Effect.setEnabled(id, true) } } }
        else { confirmStop(ids: [id]) }
    }
    private func openLogs(_ definition: Runners.Definition) {
        // Prefer the manifest stdout/stderr paths; fall back to the log directory.
        let files = RunnerDiagnostics.logFiles(definition: definition)
        if let first = files.first {
            NSWorkspace.shared.open(first)
        } else {
            NSWorkspace.shared.open(definition.logs)
        }
    }
    private func confirmStop(ids: [String]) {
        let targets = state.runners.filter { ids.contains($0.id) && $0.status == .running }
        guard !targets.isEmpty else {
            // Nothing running: still route through the bulk effect so partial
            // errors surface per row.
            if !ids.isEmpty {
                let copy = ids
                Task { await action { Runners.Effect.setEnabledMany(copy, false) } }
            }
            return
        }
        let alert = NSAlert()
        if targets.count == 1, let only = targets.first {
            let busy = only.remote?.busy == true && (only.remote?.busyKnown == true) && !(only.remote?.stale ?? true)
            alert.messageText = busy ? "На раннере выполняется задача" : "Выключить CI?"
            alert.informativeText = Runners.StopConfirmation.message(remote: only.remote, runnerTitle: only.definition.displayTitle)
            alert.addButton(withTitle: "Оставить включённым")
            alert.addButton(withTitle: busy ? "Прервать и выключить" : "Выключить")
        } else {
            alert.messageText = "Выключить \(targets.count) раннеров?"
            let names = targets.map(\.definition.displayTitle).joined(separator: ", ")
            alert.informativeText = "Будут остановлены: \(names). Если какой-то раннер выполняет сборку, она будет прервана."
            alert.addButton(withTitle: "Отмена")
            alert.addButton(withTitle: "Выключить все")
        }
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let copy = ids
        Task { await action { Runners.Effect.setEnabledMany(copy, false) } }
    }
}
