import SwiftUI
import RunnerControlCore

struct RunnerPage: View {
    struct Props {
        let runners: [Runners.Snapshot]
        let changing: Set<String>
        let error: String?
        let catalogError: String?
        let remoteSyncError: String?
    }
    struct Reactions {
        let setEnabled: (String, Bool) -> Void
        let enableAll: () -> Void
        let disableAll: () -> Void
        let openGitHub: (Runners.Definition) -> Void
        let openLogs: (Runners.Definition) -> Void
        let openDetails: (Runners.Definition) -> Void
        let clearError: () -> Void
        let clearCatalogError: () -> Void
        let addRunner: () -> Void
        let openSettings: () -> Void
    }
    let props: Props
    let reactions: Reactions
    private var active: Int { props.runners.filter { $0.status == .running }.count }
    private var hasError: Bool {
        props.runners.contains { [.failed, .missing, .needsSetup, .unknown].contains($0.status) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: hasError ? "exclamationmark.circle.fill" : "bolt.circle.fill")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(hasError ? .orange : .teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Runner Control").font(.system(size: 16, weight: .semibold))
                    Text("\(Host.current().localizedName ?? "Этот Mac") · \(active) служб включено")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityLabel("\(Host.current().localizedName ?? "Этот Mac"), \(active) служб включено из \(props.runners.count)")
                }
                Spacer()
                Circle().fill(hasError ? Color.orange : (active > 0 ? Color.green : Color.secondary.opacity(0.4))).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            if props.runners.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Добавьте раннер на этом Mac").font(.callout.weight(.medium))
                    Text("Найдите существующие установки или выберите папку. Учётная запись GitHub не обязательна.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Добавить раннер…", action: reactions.addRunner)
                        .buttonStyle(.borderedProminent).tint(.teal)
                }
                .padding(.vertical, 6)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(props.runners) { runner in
                        RunnerCard(snapshot: runner, changing: props.changing.contains(runner.id),
                                   setEnabled: { reactions.setEnabled(runner.id, $0) },
                                   openGitHub: { reactions.openGitHub(runner.definition) },
                                   openLogs: { reactions.openLogs(runner.definition) },
                                   openDetails: { reactions.openDetails(runner.definition) })
                    }
                }
            }
            .frame(maxHeight: 420)
            if let error = props.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled).lineLimit(6)
                    Spacer(minLength: 0)
                    Button(action: reactions.clearError) { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if let catalogError = props.catalogError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(catalogError).font(.caption).textSelection(.enabled).lineLimit(6)
                    Spacer(minLength: 0)
                    Button(action: reactions.clearCatalogError) { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if let remoteError = props.remoteSyncError {
                Text("GitHub: \(remoteError)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("Включить все", action: reactions.enableAll)
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(!props.changing.isEmpty || props.runners.allSatisfy { $0.status == .running || $0.status == .checking || $0.status == .missing || $0.status == .needsSetup || $0.status == .unknown })
                Button("Выключить все…", action: reactions.disableAll)
                    .buttonStyle(.bordered)
                    .disabled(!props.changing.isEmpty || props.runners.allSatisfy { $0.status == .stopped || $0.status == .checking })
            }.controlSize(.regular)
            HStack(spacing: 8) {
                Button("Добавить раннер…", action: reactions.addRunner)
                    .buttonStyle(.bordered)
                Button("Раннеры и настройки…", action: reactions.openSettings)
                    .buttonStyle(.bordered)
            }.controlSize(.regular)
            Text("Закрытие приложения не останавливает CI. Автозапуск определяется настройками каждой службы.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 400)
    }
}
