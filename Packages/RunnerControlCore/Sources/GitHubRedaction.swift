import Foundation

extension GitHubAuth {
    /// Redacts secret values from diagnostics. Never logs raw tokens.
    /// Bound: no production caller in this slice. The diagnostics export
    /// (log tail, _diag archive) lands with catalog/lifecycle; until then
    /// RuntimeLogger emits action types only, so there is nothing to scrub.
    public enum Redaction {
        public static func sanitize(_ text: String, secrets: [String]) -> String {
            var result = text
            for secret in secrets where !secret.isEmpty {
                result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
            }
            // Scrub common token JSON shapes even when the exact value is unknown.
            for key in ["access_token", "refresh_token", "device_code"] {
                result = scrubJSONValue(for: key, in: result)
            }
            return result
        }

        private static func scrubJSONValue(for key: String, in text: String) -> String {
            // "key":"value" and "key": "value" shapes.
            var result = text
            for pattern in ["\"\(key)\":\"", "\"\(key)\": \""] {
                var searchFrom = result.startIndex
                while let keyRange = result.range(of: pattern, range: searchFrom..<result.endIndex) {
                    let valueStart = keyRange.upperBound
                    guard let valueEnd = result[valueStart...].firstIndex(of: "\"") else { break }
                    result.replaceSubrange(valueStart..<valueEnd, with: "[REDACTED]")
                    searchFrom = result.index(valueEnd, offsetBy: 0, limitedBy: result.endIndex) ?? result.endIndex
                    if searchFrom >= result.endIndex { break }
                }
            }
            return result
        }
    }
}
