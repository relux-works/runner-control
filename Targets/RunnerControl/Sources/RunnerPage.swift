import SwiftUI
import RunnerControlCore

struct RunnerPage: View {
    struct Props {
        let runners: [Runners.Snapshot]
        let changing: Set<String>
        let error: String?
    }
    struct Reactions {
        let setEnabled: (String, Bool) -> Void
        let enableAll: () -> Void
        let disableAll: () -> Void
        let openGitHub: (Runners.Definition) -> Void
        let openLogs: (Runners.Definition) -> Void
        let clearError: () -> Void
        let quit: () -> Void
    }
    let props: Props
    let reactions: Reactions
    private var active: Int { props.runners.filter { $0.status == .running }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Runner Control").font(.system(size: 16, weight: .semibold))
                    Text("macbook-iv · \(active) из \(props.runners.count) включено")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(active > 0 ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            }
            VStack(spacing: 10) {
                ForEach(props.runners) { runner in
                    RunnerCard(snapshot: runner, changing: props.changing.contains(runner.id),
                               setEnabled: { reactions.setEnabled(runner.id, $0) },
                               openGitHub: { reactions.openGitHub(runner.definition) },
                               openLogs: { reactions.openLogs(runner.definition) })
                }
            }
            if let error = props.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled).lineLimit(6)
                    Spacer(minLength: 0)
                    Button(action: reactions.clearError) { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                Button("Включить все", action: reactions.enableAll)
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(!props.changing.isEmpty || props.runners.allSatisfy { $0.status == .running || $0.status == .checking || $0.status == .missing || $0.status == .unknown })
                Button("Выключить все", action: reactions.disableAll)
                    .buttonStyle(.bordered)
                    .disabled(!props.changing.isEmpty || props.runners.allSatisfy { $0.status == .stopped || $0.status == .checking })
            }.controlSize(.regular)
            Text("CI включается вручную. После перезагрузки раннеры останутся выключенными.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text("RELUX WORKS").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(.tertiary)
                Spacer()
                Button("Закрыть приложение", action: reactions.quit).buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.secondary).disabled(!props.changing.isEmpty)
            }
        }.padding(20).frame(width: 370)
    }
}
