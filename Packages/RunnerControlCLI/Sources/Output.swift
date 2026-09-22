import Foundation

/// Stdout/stderr emitters. Text goes to stdout, diagnostics to stderr, so
/// `runner-control --json ... | jq` never sees stray lines.
public enum Output {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static func json<Payload: Encodable>(_ payload: Payload) {
        let envelope = CLIEnvelope(status: "ok", data: payload)
        print(String(data: (try? encoder.encode(envelope)) ?? Data("{\"status\":\"ok\"}".utf8), encoding: .utf8) ?? "")
    }

    public static func jsonError(_ message: String) {
        let envelope = CLIEnvelope<EmptyPayload>(status: "error", error: message)
        print(String(data: (try? encoder.encode(envelope)) ?? Data("{\"status\":\"error\"}".utf8), encoding: .utf8) ?? "")
    }

    public static func text(_ line: String) {
        print(line)
    }

    public static func warn(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Encodes one envelope without printing. Test seam for the JSON contract.
    public static func encode<Payload: Encodable>(_ payload: Payload) throws -> String {
        let envelope = CLIEnvelope(status: "ok", data: payload)
        return String(data: try encoder.encode(envelope), encoding: .utf8) ?? ""
    }

    /// Aligned two-column table. Pure function; tested.
    public static func table(rows: [(String, String)]) -> String {
        guard !rows.isEmpty else { return "" }
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { key, value in
            key.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value
        }.joined(separator: "\n")
    }

    public static func isTTY() -> Bool {
        isatty(STDIN_FILENO) == 1
    }

    /// Reads one line from stdin (TTY prompts). Returns nil on EOF.
    public static func readLine(prompt: String) -> String? {
        FileHandle.standardError.write(Data(prompt.utf8))
        return Swift.readLine(strippingNewline: true)
    }
}

/// Flag-value parsing shared by commands. Pure; tested.
public enum Parse {
    /// Parses a comma-separated ID list (`--repo-id 1,2,3`). Empty entries
    /// are dropped; non-numeric entries are usage errors naming the flag.
    public static func idList(_ text: String, flag: String) throws -> [Int64] {
        var values: [Int64] = []
        for part in text.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let value = Int64(trimmed) else {
                throw CLIFailure(.usage, "\(flag) must be comma-separated integers, got “\(trimmed)”.")
            }
            values.append(value)
        }
        return values
    }
}
