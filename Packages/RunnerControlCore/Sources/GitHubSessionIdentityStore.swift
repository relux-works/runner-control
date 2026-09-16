import Foundation

/// Non-secret session identity persisted separately from Keychain tokens.
/// Lets the app find its Keychain record after relaunch without storing secrets.
/// `sessionIncarnation` is a unique login incarnation: every successful Device
/// Flow login mints a fresh UUID, logout deletes the identity, and token
/// refresh never touches it. Operations capture the incarnation at start and
/// refuse to continue after a logout/login cycle — even for the same
/// account/server — while ordinary refresh stays valid. Legacy persisted
/// identities without this key decode as nil and keep working.
public struct GitHubSessionIdentity: Sendable, Equatable, Codable {
    public let serverHost: String
    public let userID: Int64
    public let clientID: String
    public let username: String
    public let sessionIncarnation: String?

    public init(serverHost: String, userID: Int64, clientID: String, username: String, sessionIncarnation: String? = nil) {
        self.serverHost = serverHost
        self.userID = userID
        self.clientID = clientID
        self.username = username
        self.sessionIncarnation = sessionIncarnation
    }

    enum CodingKeys: String, CodingKey {
        case serverHost, userID, clientID, username, sessionIncarnation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverHost = try container.decode(String.self, forKey: .serverHost)
        userID = try container.decode(Int64.self, forKey: .userID)
        clientID = try container.decode(String.self, forKey: .clientID)
        username = try container.decode(String.self, forKey: .username)
        sessionIncarnation = try container.decodeIfPresent(String.self, forKey: .sessionIncarnation)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverHost, forKey: .serverHost)
        try container.encode(userID, forKey: .userID)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(sessionIncarnation, forKey: .sessionIncarnation)
    }
}

public protocol GitHubSessionIdentityStoring: Sendable {
    func save(_ identity: GitHubSessionIdentity) async
    func load() async -> GitHubSessionIdentity?
    func delete() async
}

/// Production store: UserDefaults holds only non-secret identity, never tokens.
public actor UserDefaultsGitHubSessionIdentityStore: GitHubSessionIdentityStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "works.relux.runnercontrol.github.sessionIdentity.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func save(_ identity: GitHubSessionIdentity) async {
        if let data = try? JSONEncoder().encode(identity) {
            defaults.set(data, forKey: key)
        }
    }

    public func load() async -> GitHubSessionIdentity? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GitHubSessionIdentity.self, from: data)
    }

    public func delete() async {
        defaults.removeObject(forKey: key)
    }
}

/// In-memory store for unit tests. Never used in production.
public final class InMemoryGitHubSessionIdentityStore: GitHubSessionIdentityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: GitHubSessionIdentity?
    public init(value: GitHubSessionIdentity? = nil) { self.value = value }
    public func save(_ identity: GitHubSessionIdentity) async {
        lock.withLock { value = identity }
    }
    public func load() async -> GitHubSessionIdentity? {
        lock.withLock { value }
    }
    public func delete() async {
        lock.withLock { value = nil }
    }
}
