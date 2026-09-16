import Foundation

/// Log access without hardcoded `Library/Logs` names. Resolves the actual
/// StandardOutPath/StandardErrorPath from the service manifest plus the
/// runner `_diag` directory. Returns a bounded tail with token redaction.
public enum RunnerDiagnostics {
    public static let maxTailBytes = 64 * 1024
    public static let maxTailLines = 200

    /// Ordered log files for a definition: manifest stdout/stderr first,
    /// then newest `_diag` logs. Missing files are skipped.
    public static func logFiles(definition: Runners.Definition) -> [URL] {
        var values: [URL] = []
        if let data = try? Data(contentsOf: definition.plist),
           let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            if let out = object["StandardOutPath"] as? String, !out.isEmpty {
                values.append(URL(fileURLWithPath: out))
            }
            if let err = object["StandardErrorPath"] as? String, !err.isEmpty {
                values.append(URL(fileURLWithPath: err))
            }
        }
        let diag = definition.directory.appendingPathComponent("_diag")
        if let files = try? FileManager.default.contentsOfDirectory(
            at: diag, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        ) {
            let sorted = files.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
            values.append(contentsOf: sorted.prefix(3))
        }
        // Fallback to the legacy per-service log directory when the manifest
        // carries no explicit paths.
        if values.isEmpty {
            values.append(definition.logs)
        }
        return values
    }

    /// Bounded tail of the most recent log file, with secrets scrubbed.
    /// `secrets` are exact values to redact; common token JSON shapes are
    /// scrubbed even when the exact value is unknown.
    public static func tail(definition: Runners.Definition, secrets: [String] = []) -> String {
        for file in logFiles(definition: definition) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // Legacy directory fallback: read newest file inside.
                guard let inner = (try? FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: [.contentModificationDateKey]))?
                    .sorted(by: {
                        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        return a > b
                    }).first,
                      let text = tailFile(inner) else { continue }
                return GitHubAuth.Redaction.sanitize(text, secrets: secrets)
            }
            if let text = tailFile(file) {
                return GitHubAuth.Redaction.sanitize(text, secrets: secrets)
            }
        }
        return "No log output yet."
    }

    static func tailFile(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > UInt64(maxTailBytes) ? size - UInt64(maxTailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: maxTailBytes), !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // Drop a partial first line when we started mid-file.
        if start > 0, let first = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: first)...])
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxTailLines {
            return lines.suffix(maxTailLines).joined(separator: "\n")
        }
        return text
    }
}
