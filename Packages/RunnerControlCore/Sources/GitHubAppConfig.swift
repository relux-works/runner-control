import Foundation

extension GitHubAuth {
    /// Public GitHub App configuration. Only the public client_id lives here.
    /// Client secrets and private keys are never embedded (see auditNoSecrets).
    public struct AppConfig: Sendable, Equatable {
        public let clientID: String
        public let serverHost: String
        public let deviceAuthorizationURL: URL
        public let tokenURL: URL
        public let apiBaseURL: URL

        public init(clientID: String, serverHost: String = "github.com") {
            self.clientID = clientID
            self.serverHost = serverHost
            if serverHost == "github.com" || serverHost == "www.github.com" {
                self.deviceAuthorizationURL = URL(string: "https://github.com/login/device/code")!
                self.tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
                self.apiBaseURL = URL(string: "https://api.github.com")!
            } else {
                self.deviceAuthorizationURL = URL(string: "https://\(serverHost)/login/device/code")!
                self.tokenURL = URL(string: "https://\(serverHost)/login/oauth/access_token")!
                self.apiBaseURL = URL(string: "https://\(serverHost)/api/v3")!
            }
        }

        /// Exact scaffold binding the coordinator must provision.
        public static let missingBindingHelp = "Info.plist[GitHubAppClientID] (scaffold input ios-app-manager.json → macos.info_plist.GitHubAppClientID, coordinator-provisioned public client_id)"

        public static func current(bundle: Bundle = .main, serverHost: String = "github.com") throws -> Self {
            if let info = bundle.infoDictionary {
                try auditNoSecrets(in: info)
            }
            let raw = bundle.object(forInfoDictionaryKey: "GitHubAppClientID") as? String
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                throw ConfigError.missingClientID(binding: missingBindingHelp)
            }
            return Self(clientID: trimmed, serverHost: serverHost)
        }

        /// Fail-closed audit: Info.plist must not carry secrets or private keys.
        public static func auditNoSecrets(in dictionary: [String: Any]) throws {
            let forbidden = ["secret", "private_key", "privatekey", "token"]
            for key in dictionary.keys {
                let lowered = key.lowercased()
                for token in forbidden where lowered.contains(token) {
                    if key == "GitHubAppClientID" { continue }
                    throw ConfigError.embeddedSecret(key: key)
                }
            }
        }
    }

    public enum ConfigError: LocalizedError, Sendable, Equatable {
        case missingClientID(binding: String)
        case embeddedSecret(key: String)
        case unsupportedEnterprise(host: String)

        public var errorDescription: String? {
            switch self {
            case .missingClientID(let binding):
                "GitHub App client_id is not provisioned. Missing binding: \(binding)."
            case .embeddedSecret(let key):
                "Refusing to load embedded secret '\(key)'. Secrets must stay in Keychain, never in plist/state/logs."
            case .unsupportedEnterprise(let host):
                "GitHub Enterprise Server '\(host)' needs its own App registration and Device Flow support check. Local control remains available offline."
            }
        }
    }
}
