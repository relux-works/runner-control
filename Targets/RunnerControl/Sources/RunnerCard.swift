import SwiftUI
import RunnerControlCore

struct RunnerCard: View {
    let snapshot: Runners.Snapshot
    let changing: Bool
    let setEnabled: (Bool) -> Void
    let openGitHub: () -> Void
    let openLogs: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.definition.title).font(.system(size: 13, weight: .semibold))
                    Text(snapshot.definition.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if changing { ProgressView().controlSize(.small) }
                Toggle(snapshot.definition.title, isOn: Binding(get: { snapshot.status == .running }, set: setEnabled))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.teal)
                    .disabled(changing || [.checking, .missing, .unknown].contains(snapshot.status))
                    .accessibilityIdentifier("Runners menu \(snapshot.definition.title) toggle")
            }
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(changing ? "Меняем состояние…" : snapshot.status.title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: openLogs) { Image(systemName: "doc.text.magnifyingglass") }.help("Открыть журналы")
                Button(action: openGitHub) { Image(systemName: "arrow.up.right.square") }.help("Открыть раннеры в GitHub")
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            if let message = snapshot.message {
                Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(3)
            }
        }.padding(13).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private var color: Color {
        switch snapshot.status {
        case .running: .green
        case .failed, .missing, .unknown: .orange
        default: .secondary.opacity(0.6)
        }
    }
}
