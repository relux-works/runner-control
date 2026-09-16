import SwiftUI
import RunnerControlCore

struct RunnerCard: View {
    let snapshot: Runners.Snapshot
    let changing: Bool
    let setEnabled: (Bool) -> Void
    let openGitHub: () -> Void
    let openLogs: () -> Void
    var openDetails: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: { openDetails?() }) {
                        Text(snapshot.definition.displayTitle).font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Открыть подробности")
                    Text(scopeLine).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if changing { ProgressView().controlSize(.small) }
                if snapshot.definition.controllerKind.canControl {
                    if snapshot.status == .running || snapshot.status == .stopping {
                        Button("Выключить…") { setEnabled(false) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(changing)
                            .accessibilityIdentifier("Runners \(snapshot.definition.displayTitle) disable")
                    } else {
                        Button("Включить") { setEnabled(true) }
                            .buttonStyle(.borderedProminent).tint(.teal).controlSize(.small)
                            .disabled(changing || [.checking, .missing, .needsSetup, .unknown].contains(snapshot.status))
                            .accessibilityIdentifier("Runners \(snapshot.definition.displayTitle) enable")
                    }
                } else {
                    Text("Только чтение").font(.caption2).foregroundStyle(.secondary)
                        .help(snapshot.message ?? "Unsupported management")
                }
            }
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(changing ? "Меняем состояние…" : snapshot.status.title)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: openLogs) { Image(systemName: "doc.text.magnifyingglass") }.help("Открыть журналы")
                Button(action: openGitHub) { Image(systemName: "arrow.up.right.square") }.help("Открыть раннеры в GitHub")
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            Text(remoteLine)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .accessibilityLabel(remoteLine)
            if let message = snapshot.message {
                Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(3)
            }
        }.padding(13).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private var scopeLine: String {
        var parts: [String] = [snapshot.definition.detail]
        if let host = snapshot.definition.serverHost, host != "github.com" {
            parts.append(host)
        }
        if snapshot.definition.displayName != nil {
            parts.append("· \(snapshot.definition.title)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var remoteLine: String {
        snapshot.remote?.signature ?? "GitHub: не подключён"
    }
    private var color: Color {
        switch snapshot.status {
        case .running: .green
        case .starting, .stopping: .teal
        case .failed, .missing, .needsSetup, .unknown: .orange
        default: .secondary.opacity(0.6)
        }
    }
}
