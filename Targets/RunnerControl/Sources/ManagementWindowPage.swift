import SwiftUI
import RunnerControlCore

struct ManagementWindowPage: View {
    let props: Props
    let reactions: Reactions
    @State private var selection: Tab = .runners
    /// Local checkbox drafts for group repository editing, keyed by runner
    /// id. Seeded from fresh loaded access; cleared when fresh access reloads.
    @State private var accessDrafts: [String: Set<Int64>] = [:]

    enum Tab: Hashable {
        case runners, github, general
    }

    var body: some View {
        TabView(selection: $selection) {
            runnersTab
                .tabItem { Label("Раннеры", systemImage: "bolt.circle") }
                .tag(Tab.runners)
            githubTab
                .tabItem { Label("GitHub", systemImage: "person.circle") }
                .tag(Tab.github)
            generalTab
                .tabItem { Label("Основные", systemImage: "gearshape") }
                .tag(Tab.general)
        }
        .frame(width: 760, height: 540)
    }

    // MARK: - Runners

    private var active: Int { props.runners.snapshots.filter { $0.status == .running }.count }

    private var selectedSnapshot: Runners.Snapshot? {
        guard let id = props.runners.selectedID else { return nil }
        return props.runners.snapshots.first { $0.id == id }
    }

    private var runnersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Раннеры на этом Mac").font(.system(size: 15, weight: .semibold))
                    Text("\(Host.current().localizedName ?? "Этот Mac") · \(active) служб включено")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(active > 0 ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Button("Обновить GitHub", action: reactions.refreshRemote)
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Обновить online/busy/labels из GitHub. Локальное управление работает без входа.")
            }
            if let syncError = props.runners.remoteSyncError {
                Text("GitHub: \(syncError)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            } else if let synced = props.runners.lastRemoteSync {
                Text("GitHub обновлён: \(synced.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if props.runners.snapshots.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Добавьте раннер на этом Mac").font(.callout.weight(.medium))
                    Text("Учётная запись GitHub не обязательна. Локальное управление работает без входа.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Найти на Mac", action: reactions.discover)
                            .buttonStyle(.borderedProminent).tint(.teal)
                        Button("Выбрать папку…", action: reactions.importFolder)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 8)
            }
            HSplitView {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(props.runners.snapshots) { runner in
                            RunnerCard(
                                snapshot: runner,
                                changing: props.runners.changing.contains(runner.id),
                                setEnabled: { reactions.setEnabled(runner.id, $0) },
                                openGitHub: { reactions.openGitHub(runner.definition) },
                                openLogs: { reactions.openLogs(runner.definition) },
                                openDetails: { reactions.selectRunner(runner.id) }
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(props.runners.selectedID == runner.id ? Color.teal : Color.clear, lineWidth: 1.5)
                            )
                            .onTapGesture { reactions.selectRunner(runner.id) }
                        }
                    }
                    .padding(2)
                }
                .frame(minWidth: 300)
                if let selected = selectedSnapshot {
                    ScrollView {
                        detailView(selected)
                    }
                    .frame(minWidth: 300)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Выберите раннер").font(.callout.weight(.medium))
                        Text("Нажмите на название, чтобы увидеть каталог, рабочий каталог, политику входа и действия.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(minWidth: 300, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            if !props.runners.candidates.isEmpty {
                candidatesView
            }
            if let error = props.runners.runnerError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled).lineLimit(4)
                    Spacer(minLength: 0)
                    Button(action: reactions.clearRunnerError) { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if let catalogError = props.runners.catalogError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(catalogError).font(.caption).textSelection(.enabled).lineLimit(4)
                    Spacer(minLength: 0)
                    Button(action: reactions.clearCatalogError) { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if let title = props.runners.logPreviewTitle, let excerpt = props.runners.logPreview {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Журнал: \(title)").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button(action: reactions.clearLog) { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                    ScrollView {
                        Text(excerpt).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                Button("Включить все", action: reactions.enableAll)
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(!props.runners.changing.isEmpty || props.runners.snapshots.allSatisfy { $0.status == .running || $0.status == .checking || $0.status == .missing || $0.status == .needsSetup || $0.status == .unknown })
                Button("Выключить все…", action: reactions.disableAll)
                    .buttonStyle(.bordered)
                    .disabled(!props.runners.changing.isEmpty || props.runners.snapshots.allSatisfy { $0.status == .stopped || $0.status == .checking })
                Button("Найти на Mac", action: reactions.discover)
                    .buttonStyle(.bordered)
                Button("Выбрать папку…", action: reactions.importFolder)
                    .buttonStyle(.bordered)
                Button("Создать раннер…", action: reactions.openRegistration)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("Add runner button")
            }
            Text("Закрытие приложения не останавливает CI. Автозапуск определяется настройками каждой службы.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var candidatesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Найдено на Mac").font(.system(size: 12, weight: .medium))
            ForEach(props.runners.candidates) { candidate in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.agentName ?? candidate.directory.lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                        Text("\(candidate.scope ?? "—") · \(candidate.directory.path)")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        if candidate.needsRelocation {
                            Text("Нужно изменить расположение: путь содержит пробел.")
                                .font(.caption2).foregroundStyle(.orange)
                        } else if let reason = candidate.unsupportedReason {
                            Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                        } else if !candidate.issues.isEmpty {
                            Text(candidate.issues.joined(separator: " ")).font(.caption2).foregroundStyle(.orange).lineLimit(3)
                        }
                    }
                    Spacer()
                    Button("Добавить") { reactions.importCandidate(candidate) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(!candidate.isImportable && !candidate.issues.contains(where: { $0.contains("No service manifest") }))
                        .help(candidate.isImportable ? "Добавить без изменения существующей службы" : candidate.issues.joined(separator: " "))
                }
                .padding(8).background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func detailView(_ snapshot: Runners.Snapshot) -> some View {
        let definition = snapshot.definition
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(definition.displayTitle).font(.system(size: 14, weight: .semibold))
                    Text("\(definition.detail)\(definition.serverHost.map { " · \($0)" } ?? "")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Закрыть") { reactions.selectRunner(nil) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            detailRow("Локальный каталог", definition.directory.path)
            detailRow("Рабочий каталог", definition.workFolder ?? "—")
            detailRow("Управление", definition.controllerKind.title)
            detailRow("Служба", definition.id)
            if let agentID = definition.remoteAgentID {
                detailRow("Agent ID", String(agentID))
            }
            if !snapshot.remoteLabels.isEmpty {
                detailRow("Labels", snapshot.remoteLabels.joined(separator: ", "))
            }
            if definition.detail.contains("/") {
                detailRow("Доступ", "Репозиторий \(definition.detail). Отдельные установки на репозиторий; группы не применяются.")
            } else {
                groupAccessSection(snapshot)
            }
            if let synced = snapshot.remote?.updatedAt {
                detailRow("GitHub обновлён", synced.formatted(date: .omitted, time: .standard))
            }
            HStack {
                Text("Запуск раннера при входе").font(.callout)
                Spacer()
                if definition.controllerKind.canControl, let login = definition.loginEnabled {
                    Toggle("", isOn: Binding(
                        get: { login },
                        set: { reactions.setRunAtLoad(definition.id, $0) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help("Переключатель меняет реальную регистрацию входа и не трогает запущенную службу.")
                } else {
                    Text("—").font(.callout).foregroundStyle(.secondary)
                }
            }
            if definition.controllerKind == .manualManaged, let external = definition.runAtLoad {
                Text("Файл службы вне LaunchAgents: RunAtLoad \(external ? "включён" : "выключен") (действует только при загрузке). Вход: \(definition.loginEnabled == true ? "включён" : "выключен").")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("Импортированная политика сохраняется и явно показывается, а не меняется молча.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if snapshot.status == .running {
                        Button("Выключить…") { reactions.setEnabled(definition.id, false) }
                            .buttonStyle(.bordered)
                            .disabled(props.runners.changing.contains(definition.id))
                    } else {
                        Button("Включить") { reactions.setEnabled(definition.id, true) }
                            .buttonStyle(.borderedProminent).tint(.teal)
                            .disabled(props.runners.changing.contains(definition.id) || [.checking, .missing, .needsSetup, .unknown].contains(snapshot.status) || !definition.controllerKind.canControl)
                    }
                    Button("Журнал") { reactions.loadLog(definition.id) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                HStack(spacing: 8) {
                    Button("Показать каталог") { reactions.showDirectory(definition) }
                        .buttonStyle(.plain).font(.callout)
                    Button("Открыть GitHub") { reactions.openGitHub(definition) }
                        .buttonStyle(.plain).font(.callout)
                }
                HStack(spacing: 8) {
                    Button("Переименовать…") { reactions.renameRunner(definition.id) }
                        .buttonStyle(.plain).font(.callout)
                    Button("Выбрать перемещённую папку…") { reactions.relink(definition.id) }
                        .buttonStyle(.plain).font(.callout)
                }
                HStack(spacing: 8) {
                    Button("Убрать из приложения") { reactions.removeFromApp(definition.id) }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                        .help("Удаляет только запись каталога. Файлы, регистрация GitHub и служба не затрагиваются.")
                        .disabled(props.runners.unregistering.contains(definition.id))
                    Button("Удалить из GitHub…") { reactions.unregister(definition.id) }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.red)
                        .help("Явное удаление регистрации из GitHub. Требует остановки и подтверждения.")
                        .disabled(props.runners.unregistering.contains(definition.id) || snapshot.status == .running)
                }
                if props.runners.unregistering.contains(definition.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Удаляем из GitHub…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private func groupAccessSection(_ snapshot: Runners.Snapshot) -> some View {
        let definition = snapshot.definition
        let access = props.runners.groupAccess[definition.id]
        let selectedAccount = props.runners.installations.first {
            $0.id == props.runners.selectedInstallationID
        }?.account.lowercased()
        let orgMatches = selectedAccount == definition.detail.lowercased()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Доступ к репозиториям").font(.system(size: 12, weight: .semibold))
            if let access, let group = access.group {
                Text("Группа \(group.name) (id \(group.id)) · обновлено \((access.updatedAt ?? Date()).formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                Text(access.owned ? "Группа этого Mac: изменения применяются явно." : "Общая или импортированная группа: правки затрагивают все раннеры в ней и требуют явного принятия.")
                    .font(.system(size: 11)).foregroundStyle(access.owned ? Color.secondary : Color.orange)
                if props.runners.candidateRepositories.isEmpty {
                    Text("Выберите подходящую установку в разделе GitHub, чтобы увидеть репозитории.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if !orgMatches {
                    Text("Выбранная установка не совпадает с организацией раннера «\(definition.detail)». Выберите подходящую установку.")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    let loaded = Set(access.repoIDs)
                    let draft = accessDrafts[definition.id] ?? loaded
                    ForEach(props.runners.candidateRepositories) { repo in
                        Toggle(
                            repo.fullName,
                            isOn: Binding(
                                get: { draft.contains(repo.id) },
                                set: { enabled in
                                    var next = accessDrafts[definition.id] ?? loaded
                                    if enabled { next.insert(repo.id) } else { next.remove(repo.id) }
                                    accessDrafts[definition.id] = next
                                }
                            )
                        )
                        .font(.callout)
                        .disabled(access.loading)
                    }
                    HStack(spacing: 8) {
                        Button("Применить") { reactions.applyGroupAccess(definition.id, draft) }
                            .buttonStyle(.borderedProminent).tint(.teal).controlSize(.small)
                            .disabled(access.loading || draft == loaded)
                        Button("Обновить") { reactions.loadGroupAccess(definition.id) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(access.loading)
                        if access.loading { ProgressView().controlSize(.small) }
                    }
                    .onChange(of: access.repoIDs) { accessDrafts.removeValue(forKey: definition.id) }
                }
            } else if access?.loading == true {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Загружаем текущую группу из GitHub…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                if let error = access?.error {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).lineLimit(4)
                } else {
                    Text("Группа определяется свежим составом GitHub, а не локальным .runner.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button("Загрузить текущий доступ") { reactions.loadGroupAccess(definition.id) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11)).textSelection(.enabled).lineLimit(3)
        }
    }

    // MARK: - GitHub

    private var githubTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch props.github.connection {
                case .disconnected:
                    disconnectedView
                case .requestingCode:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Запрашиваем код входа…").font(.callout)
                    }
                    .padding(.vertical, 20)
                case .awaitingUser(let userCode, let uri, let expiresIn, let interval):
                    awaitingView(userCode: userCode, uri: uri, expiresIn: expiresIn, interval: interval)
                case .verifyingAccount:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Проверяем аккаунт…").font(.callout)
                    }
                    .padding(.vertical, 20)
                case .verifyingInstallations(let username):
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Проверяем установки для @\(username)…").font(.callout)
                    }
                    .padding(.vertical, 20)
                case .connected(let username, let host):
                    connectedView(username: username, host: host)
                case .failed(let message, let retry):
                    failedView(message: message, retry: retry)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var disconnectedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Подключение GitHub").font(.system(size: 15, weight: .semibold))
            Text("Необязательно. Локальное включение и выключение работает без входа. Вход добавляет подтверждённые online/busy/labels.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("Сервер:").font(.callout)
                TextField("github.com", text: Binding(
                    get: { props.github.serverHostText },
                    set: reactions.serverHostChanged
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .accessibilityIdentifier("GitHub server host field")
            }
            Button("Войти через GitHub", action: reactions.beginLogin)
                .buttonStyle(.borderedProminent).tint(.teal)
                .accessibilityIdentifier("GitHub sign in button")
            Text("Откроется код подтверждения. Пароль и 2FA вводятся только на сайте GitHub. Токены хранятся в Keychain.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let syncError = props.github.syncError {
                Text(syncError).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func awaitingView(userCode: String, uri: URL, expiresIn: Int, interval: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Подтвердите подключение на GitHub").font(.system(size: 15, weight: .semibold))
            Text(userCode)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("GitHub user code")
            Text("Код действует ~\(expiresIn / 60) мин. Опрос каждые \(interval) c.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Скопировать код") { reactions.copyCode(userCode) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("GitHub copy code button")
                Button("Открыть GitHub") { reactions.openVerification(uri) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("GitHub open verification button")
                Button("Отмена", action: reactions.cancelLogin)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("GitHub cancel login button")
            }
            Text("Браузер — системный по умолчанию. Отмена уничтожает временный код и прекращает опрос.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func connectedView(username: String, host: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Подключено как @\(username)").font(.system(size: 15, weight: .semibold))
                    Text(host).font(.callout).foregroundStyle(.secondary)
                    if let synced = props.github.lastSyncAt {
                        Text("Обновлено: \(synced.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Обновить", action: reactions.refreshInstallations)
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("GitHub refresh button")
            }
            if let syncError = props.github.syncError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(syncError).font(.caption).lineLimit(6)
                    Spacer(minLength: 0)
                }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                Button("Выйти на этом Mac", action: reactions.logout)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("GitHub logout button")
                Button("Отозвать доступ в GitHub…", action: reactions.revokeInGitHub)
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            }
            Text("Выход удаляет локальные токены и останавливает опрос GitHub. Локальные службы продолжают работать.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Установки GitHub App").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Предоставить доступ организации…", action: reactions.grantAccess)
                    .buttonStyle(.plain).font(.callout)
            }
            if props.github.installations.isEmpty {
                Text("Нет доступных установок. Предоставьте доступ организации или запросите одобрение владельца.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Установка", selection: Binding(
                    get: { props.github.selectedInstallationID },
                    set: reactions.selectInstallation
                )) {
                    ForEach(props.github.installations) { installation in
                        Text("\(installation.account) (\(installation.accountType))").tag(Optional(installation.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("GitHub installation picker")
            }
            Text("Репозитории").font(.system(size: 13, weight: .semibold))
            if props.github.repositories.isEmpty {
                Text("Репозитории выбранной установки появятся здесь.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(props.github.repositories) { repo in
                        Toggle(
                            repo.fullName,
                            isOn: Binding(
                                get: { props.github.selectedRepositoryIDs.contains(repo.id) },
                                set: { enabled in
                                    var next = props.github.selectedRepositoryIDs
                                    if enabled { next.insert(repo.id) } else { next.remove(repo.id) }
                                    reactions.selectRepositories(next)
                                }
                            )
                        )
                        .font(.callout)
                    }
                }
            }
            if !props.github.selectedRepositoryIDs.isEmpty {
                Text("Выбрано: \(props.github.selectedRepositoryIDs.count). Применяется при регистрации раннера.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func failedView(message: String, retry: GitHubAuth.RetryKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Не удалось подключить GitHub").font(.system(size: 15, weight: .semibold))
            }
            Text(message).font(.callout).textSelection(.enabled)
            HStack(spacing: 8) {
                switch retry {
                case .newCode:
                    Button("Получить новый код", action: reactions.beginLogin)
                        .buttonStyle(.borderedProminent).tint(.teal)
                case .retry:
                    Button("Повторить", action: reactions.beginLogin)
                        .buttonStyle(.borderedProminent).tint(.teal)
                case .relogin:
                    Button("Войти снова", action: reactions.beginLogin)
                        .buttonStyle(.borderedProminent).tint(.teal)
                case .grantAccess:
                    Button("Предоставить доступ…", action: reactions.grantAccess)
                        .buttonStyle(.borderedProminent).tint(.teal)
                    Button("Повторить", action: reactions.beginLogin)
                        .buttonStyle(.bordered)
                case .none:
                    EmptyView()
                }
                if retry != .none {
                    Button("Отмена", action: reactions.cancelLogin)
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    Button("Назад", action: reactions.cancelLogin)
                        .buttonStyle(.bordered)
                }
            }
            Text("Локальное управление раннерами остаётся доступным.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: - General

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Основные").font(.system(size: 15, weight: .semibold))
                Toggle(
                    "Открывать Runner Control при входе",
                    isOn: Binding(get: { props.general.launchAtLoginEnabled }, set: reactions.setLaunchAtLogin)
                )
                .font(.callout)
                Text("Отдельно от запуска CI. Для новых управляемых служб запуск раннера при входе выключен.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Версия \(props.general.appVersion)").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Проверить обновления…", action: reactions.checkForUpdates)
                        .disabled(!props.general.canCheckForUpdates)
                }
                Toggle("Проверять автоматически", isOn: Binding(get: { props.general.automaticChecks }, set: reactions.setAutomaticChecks))
                    .font(.callout)
                Toggle("Устанавливать автоматически", isOn: Binding(get: { props.general.automaticDownloads }, set: reactions.setAutomaticDownloads))
                    .font(.callout)
                    .disabled(!props.general.automaticChecks)
                Text("Выход и обновление приложения оставляют уже запущенные службы работать.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("RELUX WORKS").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Закрыть приложение", action: reactions.quit).buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
