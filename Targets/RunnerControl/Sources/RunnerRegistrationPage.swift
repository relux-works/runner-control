import SwiftUI
import RunnerControlCore

/// New-runner wizard. Pure view: all state arrives via props, all actions
/// leave via reactions that dispatch production `RunnerRegistration.Effect`s.
struct RunnerRegistrationPage: View {
    struct Props {
        let phase: RunnerRegistration.Phase
        let working: Bool
        let scopeKind: ScopeKind
        let org: String
        let repoOwner: String
        let repoName: String
        let runnerName: String
        let labelsText: String
        let installDirName: String
        let workFolder: String
        let groupName: String
        let allowGroupMutation: Bool
        let allowGroupTakeover: Bool
        let allowReplace: Bool
        let selectedRepositoryIDs: Set<Int64>
        let repositories: [GitHubAuth.Repository]
        let installations: [GitHubAuth.Installation]
        let githubConnected: Bool
        let githubUsername: String?
        let group: RunnerRegistration.RunnerGroup?
        let groupRepositoryIDs: [Int64]
        let assetFilename: String?
        let installPath: String?
        let runnerID: Int64?
        let localAgentID: Int64?
        let completedSteps: Set<String>
        let error: String?
        let failedStep: String?
        let permissionError: String?
    }

    enum ScopeKind: Hashable {
        case organization
        case repository
    }

    struct Reactions {
        let scopeKindChanged: (ScopeKind) -> Void
        let orgChanged: (String) -> Void
        let repoOwnerChanged: (String) -> Void
        let repoNameChanged: (String) -> Void
        let runnerNameChanged: (String) -> Void
        let labelsChanged: (String) -> Void
        let installDirChanged: (String) -> Void
        let workFolderChanged: (String) -> Void
        let groupNameChanged: (String) -> Void
        let allowGroupMutationChanged: (Bool) -> Void
        let allowGroupTakeoverChanged: (Bool) -> Void
        let allowReplaceChanged: (Bool) -> Void
        let repositoriesChanged: (Set<Int64>) -> Void
        let beginDraft: () -> Void
        let resolveGroup: () -> Void
        let downloadAndInstall: () -> Void
        let registerRunner: () -> Void
        let setupService: () -> Void
        let applyRepositoryAccess: () -> Void
        let applyLabels: () -> Void
        let retry: () -> Void
        let cancel: () -> Void
        let reset: () -> Void
        let dismissPermission: () -> Void
        let close: () -> Void
    }

    let props: Props
    let reactions: Reactions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !props.githubConnected {
                    githubRequired
                }
                WizardForm(props: props, reactions: reactions)
                WizardSteps(props: props, reactions: reactions)
                WizardStatus(props: props, reactions: reactions)
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 640, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Новый раннер на этом Mac").font(.system(size: 15, weight: .semibold))
            Text("Официальная сборка GitHub под вашу архитектуру, регистрация без терминала.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var githubRequired: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Войдите через GitHub во вкладке «GitHub», затем вернитесь сюда.")
                Text("Регистрация требует подтверждённой сессии.")
            }
            .font(.callout)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if props.working {
                Button("Отмена", action: reactions.cancel)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("Registration cancel button")
            } else if props.phase != .idle {
                Button("Сбросить", action: reactions.reset)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("Registration reset button")
            }
            Spacer()
            Button("Закрыть", action: reactions.close)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("Registration close button")
        }
    }
}

/// Wizard input form: scope, runner identity, and group access.
private struct WizardForm: View {
    typealias Props = RunnerRegistrationPage.Props
    typealias Reactions = RunnerRegistrationPage.Reactions
    typealias ScopeKind = RunnerRegistrationPage.ScopeKind

    let props: Props
    let reactions: Reactions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            scopeSection
            runnerSection
            if props.scopeKind == .organization {
                groupSection
            }
            if props.working {
                Text("Правка области, имени, папок или группы во время работы отменяет текущий шаг — повторите его после правки. Правка меток отменяет применение меток, правка репозиториев — применение доступа.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Область регистрации").font(.system(size: 13, weight: .semibold))
            Picker("Область", selection: Binding(
                get: { props.scopeKind },
                set: reactions.scopeKindChanged
            )) {
                Text("Организация").tag(ScopeKind.organization)
                Text("Репозиторий").tag(ScopeKind.repository)
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            .accessibilityIdentifier("Registration scope picker")
            if props.scopeKind == .organization {
                labeledField(
                    "Организация", text: props.org, set: reactions.orgChanged,
                    placeholder: "acme", id: "Registration org field"
                )
            } else {
                HStack(spacing: 8) {
                    labeledField(
                        "Владелец", text: props.repoOwner, set: reactions.repoOwnerChanged,
                        placeholder: "octo", id: "Registration repo owner field"
                    )
                    labeledField(
                        "Репозиторий", text: props.repoName, set: reactions.repoNameChanged,
                        placeholder: "app", id: "Registration repo name field"
                    )
                }
                Text("Личные репозитории получают отдельную установку без общих групп.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var runnerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Раннер").font(.system(size: 13, weight: .semibold))
            labeledField(
                "Имя раннера", text: props.runnerName, set: reactions.runnerNameChanged,
                placeholder: Host.current().localizedName ?? "macbook",
                id: "Registration runner name field"
            )
            labeledField(
                "Метки (через запятую)", text: props.labelsText, set: reactions.labelsChanged,
                placeholder: "self-hosted, macOS", id: "Registration labels field"
            )
            HStack(spacing: 8) {
                labeledField(
                    "Папка установки", text: props.installDirName, set: reactions.installDirChanged,
                    placeholder: "my-mac-runner", id: "Registration install dir field"
                )
                labeledField(
                    "Рабочая папка", text: props.workFolder, set: reactions.workFolderChanged,
                    placeholder: "_work", id: "Registration work folder field"
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Пути без пробелов: ~/Library/GitHubActions/<папка>.")
                Text("Повторный запуск продолжает с места остановки и не создаёт дубликатов.")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            Toggle(
                "Заменить регистрацию GitHub с таким же именем (опасно для других Mac)",
                isOn: Binding(get: { props.allowReplace }, set: reactions.allowReplaceChanged)
            )
            .font(.callout)
            .accessibilityIdentifier("Registration allow replace toggle")
        }
    }

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Группа и доступ к репозиториям").font(.system(size: 13, weight: .semibold))
            labeledField(
                "Группа этого Mac", text: props.groupName, set: reactions.groupNameChanged,
                placeholder: "RunnerControl-Mac", id: "Registration group name field"
            )
            if let group = props.group {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Группа: \(group.name) · id \(group.id) · \(group.visibility).")
                    Text("Доступ: \(props.groupRepositoryIDs.count) репозиториев · публичные: \(group.allowsPublicRepositories ? "да" : "нет").")
                }
                .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Группа создаётся только для этого Mac. Чужие и общие группы приложение не изменяет.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle(
                "Разрешаю изменять доступ только для указанной группы этого Mac",
                isOn: Binding(get: { props.allowGroupMutation }, set: reactions.allowGroupMutationChanged)
            )
            .font(.callout)
            .accessibilityIdentifier("Registration allow group mutation toggle")
            Toggle(
                "Группа с таким именем уже существует, и это группа этого Mac (перенять)",
                isOn: Binding(get: { props.allowGroupTakeover }, set: reactions.allowGroupTakeoverChanged)
            )
            .font(.callout)
            .accessibilityIdentifier("Registration allow group takeover toggle")
            if props.repositories.isEmpty {
                Text("Репозитории выбранной установки появятся здесь после входа.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(props.repositories) { repo in
                        Toggle(
                            repo.fullName,
                            isOn: Binding(
                                get: { props.selectedRepositoryIDs.contains(repo.id) },
                                set: { enabled in
                                    var next = props.selectedRepositoryIDs
                                    if enabled { next.insert(repo.id) } else { next.remove(repo.id) }
                                    reactions.repositoriesChanged(next)
                                }
                            )
                        )
                        .font(.callout)
                    }
                }
                if props.group != nil {
                    Button("Применить доступ к репозиториям", action: reactions.applyRepositoryAccess)
                        .buttonStyle(.bordered)
                        .disabled(props.working || !props.allowGroupMutation)
                        .accessibilityIdentifier("Registration apply repo access button")
                }
            }
        }
    }

    private func labeledField(
        _ title: String, text: String, set: @escaping (String) -> Void,
        placeholder: String, id: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(placeholder, text: Binding(get: { text }, set: set))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(id)
        }
    }
}

/// Wizard step buttons with per-step completion state.
private struct WizardSteps: View {
    typealias Props = RunnerRegistrationPage.Props
    typealias Reactions = RunnerRegistrationPage.Reactions

    let props: Props
    let reactions: Reactions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Шаги").font(.system(size: 13, weight: .semibold))
            stepRow(
                title: "Черновик", done: props.phase != .idle,
                action: reactions.beginDraft, button: "Начать",
                id: "Registration begin button"
            )
            if props.scopeKind == .organization {
                stepRow(
                    title: "Группа этого Mac",
                    done: props.completedSteps.contains("resolveGroup"),
                    action: reactions.resolveGroup, button: "Найти или создать",
                    id: "Registration resolve group button"
                )
            }
            stepRow(
                title: "Загрузка и проверка сборки",
                done: props.completedSteps.contains("downloadAndInstall"),
                action: reactions.downloadAndInstall, button: "Загрузить и установить",
                id: "Registration install button",
                detail: props.assetFilename ?? props.installPath
            )
            stepRow(
                title: "Регистрация",
                done: props.completedSteps.contains("registerRunner"),
                action: reactions.registerRunner, button: "Зарегистрировать",
                id: "Registration register button",
                detail: props.runnerID.map { "id \($0)" }
            )
            stepRow(
                title: "Служба (автозапуск выключен)",
                done: props.completedSteps.contains("setupService"),
                action: reactions.setupService, button: "Настроить службу",
                id: "Registration setup service button",
                detail: props.completedSteps.contains("registerRunner") ? nil : "Сначала зарегистрируйте раннер",
                enabled: props.completedSteps.contains("registerRunner")
            )
            HStack(spacing: 8) {
                Button("Метки: применить текущие", action: reactions.applyLabels)
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(props.working || props.runnerID == nil)
                    .accessibilityIdentifier("Registration apply labels button")
                if props.failedStep != nil {
                    Button("Повторить шаг", action: reactions.retry)
                        .buttonStyle(.borderedProminent).tint(.teal).controlSize(.small)
                        .disabled(props.working)
                        .accessibilityIdentifier("Registration retry button")
                }
                if props.working {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func stepRow(
        title: String, done: Bool, action: @escaping () -> Void,
        button: String, id: String, detail: String? = nil, enabled: Bool = true
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button(button, action: action)
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(props.working || !props.githubConnected || !enabled)
                .accessibilityIdentifier(id)
        }
    }
}

/// Wizard outcome: retained permission errors, step errors, and completion.
private struct WizardStatus: View {
    typealias Props = RunnerRegistrationPage.Props
    typealias Reactions = RunnerRegistrationPage.Reactions

    let props: Props
    let reactions: Reactions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let permission = props.permissionError {
                permissionView(permission)
            } else if let error = props.error {
                errorView(error)
            }
            if props.phase == .done {
                doneView
            }
        }
    }

    private func permissionView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.triangle.fill").foregroundStyle(.red)
                Text(message).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Повторить шаг", action: reactions.retry)
                    .buttonStyle(.borderedProminent).tint(.teal).controlSize(.small)
                    .disabled(props.working)
                Button("Скрыть", action: reactions.dismissPermission)
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            }
            Text("Ошибка прав сохранена и не стирается правками черновика.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).textSelection(.enabled).lineLimit(6)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Раннер зарегистрирован").font(.callout.weight(.medium))
            }
            if let path = props.installPath {
                Text(path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Включите его во вкладке «Раннеры», когда будете готовы. Токен регистрации уже удалён.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}
