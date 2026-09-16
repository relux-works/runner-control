import Foundation
import Security

/// Keychain-backed credential store. Secret values never enter Relux state or logs.
public protocol GitHubCredentialStoring: Sendable {
    func save(_ record: GitHubAuth.TokenRecord, serverHost: String, userID: Int64, clientID: String) async throws
    func load(serverHost: String, userID: Int64, clientID: String) async -> GitHubAuth.TokenRecord?
    func delete(serverHost: String, userID: Int64, clientID: String) async
    func deleteAll(serverHost: String, clientID: String) async
}

public actor GitHubKeychainStore: GitHubCredentialStoring {
    private let service: String
    private let backend: any KeychainBackend

    public init(service: String = "works.relux.runnercontrol.github-token", backend: (any KeychainBackend)? = nil) {
        self.service = service
        self.backend = backend ?? SecurityKeychainBackend()
    }

    public static func account(serverHost: String, userID: Int64, clientID: String) -> String {
        "\(serverHost):\(userID):\(clientID)"
    }

    private func account(serverHost: String, userID: Int64, clientID: String) -> String {
        Self.account(serverHost: serverHost, userID: userID, clientID: clientID)
    }

    public func save(_ record: GitHubAuth.TokenRecord, serverHost: String, userID: Int64, clientID: String) async throws {
        let data = try JSONEncoder().encode(record)
        try backend.save(data, service: service, account: account(serverHost: serverHost, userID: userID, clientID: clientID))
    }

    public func load(serverHost: String, userID: Int64, clientID: String) async -> GitHubAuth.TokenRecord? {
        guard let data = backend.load(service: service, account: account(serverHost: serverHost, userID: userID, clientID: clientID)) else { return nil }
        return try? JSONDecoder().decode(GitHubAuth.TokenRecord.self, from: data)
    }

    public func delete(serverHost: String, userID: Int64, clientID: String) async {
        backend.delete(service: service, account: account(serverHost: serverHost, userID: userID, clientID: clientID))
    }

    public func deleteAll(serverHost: String, clientID: String) async {
        // Best-effort sweep: Keychain has no wildcard delete; callers pass known userIDs.
        // This entry point exists so logout can clear without knowing the user when needed
        // by enumerating via backend when supported.
        backend.deleteMatching(service: service, accountPrefix: "\(serverHost):", accountSuffix: ":\(clientID)")
    }
}

/// Injectable Keychain boundary for tests.
public protocol KeychainBackend: Sendable {
    func save(_ data: Data, service: String, account: String) throws
    func load(service: String, account: String) -> Data?
    func delete(service: String, account: String)
    func deleteMatching(service: String, accountPrefix: String, accountSuffix: String)
}

public struct SecurityKeychainBackend: KeychainBackend, Sendable {
    public init() {}
    public func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw GitHubKeychainError.saveFailed(status) }
    }
    public func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    public func delete(service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
    public func deleteMatching(service: String, accountPrefix: String, accountSuffix: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return }
        for entry in list {
            if let account = entry[kSecAttrAccount as String] as? String,
               account.hasPrefix(accountPrefix), account.hasSuffix(accountSuffix) {
                delete(service: service, account: account)
            }
        }
    }
}

public enum GitHubKeychainError: LocalizedError, Sendable, Equatable {
    case saveFailed(OSStatus)
    public var errorDescription: String? { "Could not save GitHub credentials in Keychain." }
}

/// In-memory backend for unit tests. Never used in production.
public final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    public init() {}
    private func key(service: String, account: String) -> String { "\(service)\u{0}\(account)" }
    public func save(_ data: Data, service: String, account: String) throws {
        lock.withLock { storage[key(service: service, account: account)] = data }
    }
    public func load(service: String, account: String) -> Data? {
        lock.withLock { storage[key(service: service, account: account)] }
    }
    public func delete(service: String, account: String) {
        lock.withLock { _ = storage.removeValue(forKey: key(service: service, account: account)) }
    }
    public func deleteMatching(service: String, accountPrefix: String, accountSuffix: String) {
        lock.withLock {
            for key in storage.keys where key.hasPrefix("\(service)\u{0}\(accountPrefix)") && key.hasSuffix(accountSuffix) {
                storage.removeValue(forKey: key)
            }
        }
    }
}
