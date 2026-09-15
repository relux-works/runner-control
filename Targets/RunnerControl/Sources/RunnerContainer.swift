import SwiftUI
import AppKit
import RunnerControlCore

struct RunnerContainer: View {
    @ObservedObject var state: Runners.State
    var body: some View {
        RunnerPage(
            props: .init(runners: state.runners, changing: state.changing, error: state.lastError),
            reactions: .init(
                setEnabled: change,
                enableAll: { for runner in state.runners where [.stopped, .failed].contains(runner.status) { change(runner.id, true) } },
                disableAll: { confirmStop(ids: state.runners.map(\.id)) },
                openGitHub: { NSWorkspace.shared.open($0.githubURL) },
                openLogs: { NSWorkspace.shared.open($0.logs) },
                clearError: { Task { await action { Runners.Action.clearError } } },
                quit: quit
            )
        )
    }
    private func change(_ id: String, _ enabled: Bool) {
        if enabled { Task { await action { Runners.Effect.setEnabled(id, true) } } }
        else { confirmStop(ids: [id]) }
    }
    private func confirmStop(ids: [String]) {
        let alert = NSAlert()
        alert.messageText = "Выключить CI?"
        alert.informativeText = "Если раннер сейчас выполняет сборку, она будет прервана. Новые задания он принимать не будет."
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Выключить")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { for id in ids { await action { Runners.Effect.setEnabled(id, false) } } }
    }
    private func quit() {
        guard state.changing.isEmpty else { return }
        if state.runners.contains(where: { $0.status == .running || $0.status == .failed || $0.status == .unknown }) {
            let alert = NSAlert()
            alert.messageText = "Закрыть Runner Control?"
            alert.informativeText = "Включённые раннеры продолжат работать в фоне. Для остановки CI сначала нажмите «Выключить все»."
            alert.addButton(withTitle: "Остаться")
            alert.addButton(withTitle: "Закрыть приложение")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        NSApp.terminate(nil)
    }
}
