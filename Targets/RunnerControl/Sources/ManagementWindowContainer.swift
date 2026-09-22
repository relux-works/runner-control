import AppKit
import SwiftUI
import RunnerControlCore

/// Management window composition root. Reads Relux state, dispatches production effects.
struct ManagementWindowContainer: View {
    @ObservedObject var runners: Runners.State
    @ObservedObject var github: GitHubAuth.State
    @ObservedObject var registration: RunnerRegistration.State
    @ObservedObject private var updater = AppRegistry.updater
    @StateObject private var launchAtLogin = LaunchAtLoginModel()
    @StateObject private var cliInstall = CLIInstallModel()
    @State private var serverHostText: String = "github.com"
    @State private var showRegistration = false

    var body: some View {
        ManagementWindowPage(
            props: .init(
                runners: .init(
                    snapshots: runners.runners,
                    changing: runners.changing,
                    runnerError: runners.lastError,
                    candidates: runners.candidates,
                    catalogError: runners.catalogError,
                    selectedID: runners.selectedID,
                    unregistering: runners.unregistering,
                    remoteSyncError: runners.remoteSyncError,
                    lastRemoteSync: runners.lastRemoteSync,
                    logPreviewTitle: runners.logPreviewTitle,
                    logPreview: runners.logPreview,
                    groupAccess: runners.groupAccess,
                    candidateRepositories: github.repositories,
                    installations: github.installations,
                    selectedInstallationID: github.selectedInstallationID
                ),
                github: .init(
                    connection: github.connection,
                    username: github.username,
                    serverHost: github.serverHost,
                    serverHostText: serverHostText,
                    installations: github.installations,
                    selectedInstallationID: github.selectedInstallationID,
                    repositories: github.repositories,
                    selectedRepositoryIDs: github.selectedRepositoryIDs,
                    syncError: github.syncError,
                    lastSyncAt: github.lastSyncAt
                ),
                general: .init(
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
                    canCheckForUpdates: updater.canCheckForUpdates,
                    automaticChecks: updater.automaticallyChecks,
                    automaticDownloads: updater.automaticallyDownloads,
                    launchAtLoginEnabled: launchAtLogin.enabled,
                    cliAvailable: cliInstall.available,
                    cliInstalled: cliInstall.installed,
                    cliStatus: cliInstall.statusText,
                    cliBusy: cliInstall.busy
                )
            ),
            reactions: .init(
                setEnabled: change,
                enableAll: enableAll,
                disableAll: { confirmStop(ids: runners.runners.filter { $0.definition.controllerKind.canControl }.map(\.id)) },
                openGitHub: { NSWorkspace.shared.open($0.githubURL) },
                openLogs: openLogs,
                showDirectory: { NSWorkspace.shared.open($0.directory) },
                clearRunnerError: { Task { await action { Runners.Action.clearError } } },
                openRegistration: { showRegistration = true },
                discover: { Task { await action { Runners.Effect.discover } } },
                importCandidate: { candidate in Task { await action { Runners.Effect.importCandidate(candidate) } } },
                importFolder: chooseFolder,
                removeFromApp: confirmRemove,
                unregister: confirmUnregister,
                setRunAtLoad: { id, value in Task { await action { Runners.Effect.setRunAtLoad(id, value) } } },
                renameRunner: renameRunner,
                relink: chooseRelink,
                selectRunner: { id in Task { await action { Runners.Effect.selectRunner(id) } } },
                loadLog: { id in Task { await action { Runners.Effect.loadLog(id) } } },
                clearLog: { Task { await action { Runners.Effect.clearLog } } },
                clearCatalogError: { Task { await action { Runners.Action.catalogCleared } } },
                refreshRemote: { Task { await action { Runners.Effect.refreshRemote } } },
                loadGroupAccess: { id in Task { await action { Runners.Effect.loadGroupAccess(id) } } },
                applyGroupAccess: applyGroupAccess,
                serverHostChanged: { serverHostText = $0 },
                beginLogin: beginLogin,
                cancelLogin: { Task { await action { GitHubAuth.Effect.cancelLogin } } },
                logout: { Task { await action { GitHubAuth.Effect.logout } } },
                openVerification: { NSWorkspace.shared.open($0) },
                copyCode: copyCode,
                refreshInstallations: { Task { await action { GitHubAuth.Effect.refreshInstallations } } },
                selectInstallation: { id in Task { await action { GitHubAuth.Effect.selectInstallation(id) } } },
                selectRepositories: { ids in Task { await action { GitHubAuth.Effect.selectRepositories(ids) } } },
                grantAccess: { NSWorkspace.shared.open(URL(string: "https://github.com/settings/installations")!) },
                revokeInGitHub: { NSWorkspace.shared.open(URL(string: "https://github.com/settings/connections/applications")!) },
                checkForUpdates: updater.check,
                setAutomaticChecks: updater.setAutomaticChecks,
                setAutomaticDownloads: updater.setAutomaticDownloads,
                setLaunchAtLogin: { launchAtLogin.setEnabled($0) },
                installCLI: { cliInstall.install() },
                installCLIForUser: { cliInstall.installForUser() },
                uninstallCLI: { cliInstall.uninstall() },
                quit: quit
            )
        )
        .sheet(isPresented: $showRegistration) {
            RunnerRegistrationContainer(
                registration: registration,
                github: github,
                close: {
                    showRegistration = false
                    Task {
                        await action { Runners.Effect.loadCatalog }
                        await action { Runners.Effect.discover }
                    }
                }
            )
        }
    }

    private func beginLogin() {
        let host = serverHostText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = host.isEmpty ? nil : host
        Task { await action { GitHubAuth.Effect.beginLogin(serverHost: value) } }
    }

    private func copyCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private func enableAll() {
        let ids = runners.runners.filter {
            $0.definition.controllerKind.canControl && [.stopped, .failed].contains($0.status)
        }.map(\.id)
        guard !ids.isEmpty else { return }
        Task { await action { Runners.Effect.setEnabledMany(ids, true) } }
    }

    private func change(_ id: String, _ enabled: Bool) {
        if enabled { Task { await action { Runners.Effect.setEnabled(id, true) } } }
        else { confirmStop(ids: [id]) }
    }

    private func openLogs(_ definition: Runners.Definition) {
        let files = RunnerDiagnostics.logFiles(definition: definition)
        if let first = files.first {
            NSWorkspace.shared.open(first)
        } else {
            NSWorkspace.shared.open(definition.logs)
        }
    }

    private func confirmStop(ids: [String]) {
        let targets = runners.runners.filter { ids.contains($0.id) && $0.status == .running }
        guard !targets.isEmpty else {
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

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Выберите папку существующего раннера"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await action { Runners.Effect.importFolder(url) } }
    }

    private func confirmRemove(id: String) {
        guard let snapshot = runners.runners.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Убрать «\(snapshot.definition.displayTitle)» из приложения?"
        var text = "Удаляется только запись каталога. Файлы, регистрация GitHub и сертификаты не затрагиваются."
        if snapshot.status == .running {
            text += " Служба продолжит работать."
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Убрать")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { await action { Runners.Effect.removeFromApp(id) } }
    }

    private func confirmUnregister(id: String) {
        guard let snapshot = runners.runners.first(where: { $0.id == id }) else { return }
        let definition = snapshot.definition
        if snapshot.status == .running {
            let alert = NSAlert()
            alert.messageText = "Сначала остановите раннер"
            alert.informativeText = "Удаление из GitHub отказывается прерывать работающую службу. Остановите «\(definition.displayTitle)», затем повторите."
            alert.addButton(withTitle: "Понятно")
            alert.runModal()
            return
        }
        // Stopped-only: an unconfirmed state (unknown, failed, transitional)
        // never reaches the typed confirmation. The flow re-checks anyway.
        guard snapshot.status == .stopped else {
            let alert = NSAlert()
            alert.messageText = "Состояние службы не подтверждено"
            alert.informativeText = "«\(definition.displayTitle)»: \(snapshot.status.title). Удаление из GitHub требует подтверждённой остановки — сначала остановите службу и дождитесь статуса «Выключен»."
            alert.addButton(withTitle: "Понятно")
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Удалить раннер из GitHub?"
        let scope = definition.detail.isEmpty ? "—" : definition.detail
        let agent = definition.remoteAgentID.map(String.init) ?? "—"
        alert.informativeText = "Scope: \(scope). Agent ID: \(agent). Введите имя раннера «\(definition.title)» для подтверждения. Файлы и служба останутся для перерегистрации."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = definition.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Удалить из GitHub")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let confirmation = field.stringValue
        Task { await action { Runners.Effect.unregister(id, confirmation: confirmation) } }
    }

    private func renameRunner(id: String) {
        guard let snapshot = runners.runners.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Псевдоним раннера"
        alert.informativeText = "Регистрационное имя «\(snapshot.definition.title)» не меняется. Пустое поле убирает псевдоним."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = snapshot.definition.displayName ?? ""
        field.placeholderString = snapshot.definition.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Сохранить")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await action { Runners.Effect.setAlias(id, value.isEmpty ? nil : value) } }
    }

    private func applyGroupAccess(id: String, repos: Set<Int64>) {
        guard let access = runners.groupAccess[id], let group = access.group else { return }
        if !access.owned {
            let alert = NSAlert()
            alert.messageText = "Принять группу «\(group.name)»?"
            alert.informativeText = "Группа общая или импортированная: правки затрагивают все раннеры в ней. Принятие записывает её как выделенную группу этого Mac на этом сервере, затем применяет \(repos.count) репозиториев."
            alert.addButton(withTitle: "Отмена")
            alert.addButton(withTitle: "Принять и применить")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            Task { await action { Runners.Effect.applyGroupAccess(id, groupID: group.id, repositories: repos, allowTakeover: true) } }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Применить доступ к группе «\(group.name)»?"
        alert.informativeText = "Будет установлено \(repos.count) репозиториев для группы id \(group.id). Затрагивает все раннеры в группе."
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Применить")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { await action { Runners.Effect.applyGroupAccess(id, groupID: group.id, repositories: repos, allowTakeover: false) } }
    }

    private func chooseRelink(id: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Выберите перемещённую папку раннера"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await action { Runners.Effect.relinkDirectory(id, url) } }
    }

    private func quit() {
        guard runners.changing.isEmpty else { return }
        if runners.runners.contains(where: { $0.status == .running || $0.status == .failed || $0.status == .unknown }) {
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
