import Foundation

extension GitHubAuth {
    /// Token metadata kept outside Relux state. Secret values live only in Keychain.
    public struct TokenRecord: Sendable, Equatable, Codable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresAt: Date?
        public let obtainedAt: Date

        public init(accessToken: String, refreshToken: String?, expiresAt: Date?, obtainedAt: Date = Date()) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.obtainedAt = obtainedAt
        }
    }

    public struct Installation: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let account: String
        public let accountType: String
        public init(id: Int64, account: String, accountType: String) {
            self.id = id; self.account = account; self.accountType = accountType
        }
    }

    public struct Repository: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let fullName: String
        public let isPrivate: Bool
        public init(id: Int64, fullName: String, isPrivate: Bool) {
            self.id = id; self.fullName = fullName; self.isPrivate = isPrivate
        }
    }

    /// Connection phases. No tokens, device codes, or secrets are stored here.
    public enum Connection: Sendable, Equatable {
        case disconnected
        case requestingCode
        case awaitingUser(userCode: String, verificationURI: URL, expiresIn: Int, interval: Int)
        case verifyingAccount
        case verifyingInstallations(username: String)
        case connected(username: String, serverHost: String)
        case failed(message: String, retry: RetryKind)
    }

    public enum RetryKind: Sendable, Equatable {
        case newCode
        case retry
        case relogin
        case grantAccess
        case none
    }

    public enum AuthError: LocalizedError, Sendable, Equatable {
        case cancelled
        case denied
        case codeExpired
        case slowDown
        case authorizationPending
        case network(String)
        case unauthorized
        case forbidden(String)
        case rateLimited(retryAfter: Int?)
        case needsInstallation
        case needsApproval
        case ssoRequired
        case revoked
        case missingClientID(binding: String)
        case patNotSupported
        case tokenRefreshFailed

        public var errorDescription: String? {
            switch self {
            case .cancelled: "Login cancelled."
            case .denied: "Access denied on GitHub. Approve Runner Control or try again."
            case .codeExpired: "Code expired. Get a new code."
            case .slowDown: "Polling too fast. Backing off."
            case .authorizationPending: "Waiting for confirmation on GitHub…"
            case .network(let message): message
            case .unauthorized: "Session expired or revoked (401). Sign in again."
            case .forbidden(let message): message.isEmpty ? "Access forbidden (403). Grant the App or approve access." : message
            case .rateLimited: "GitHub rate limit reached. Data may be stale; local control still works."
            case .needsInstallation: "GitHub App is not installed for this account. Grant access to continue."
            case .needsApproval: "Organization approval is required."
            case .ssoRequired: "SSO authorization is required for this organization."
            case .revoked: "Session was revoked. Sign in again."
            case .missingClientID(let binding): "GitHub App client_id is not provisioned. Missing binding: \(binding)."
            case .patNotSupported: "Personal access tokens are not supported. Use Sign in with GitHub (Device Flow)."
            case .tokenRefreshFailed: "Token refresh failed. Sign in again."
            }
        }
    }
}
