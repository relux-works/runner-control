import Foundation

extension RunnerRegistration {
    /// Short-lived registration token. Lives in Keychain + Flow actor
    /// privates only; never enters Relux state, logs, or diagnostics.
    public struct ScopedToken: Sendable, Equatable, Codable {
        public let token: String
        public let expiresAt: Date?
        public let obtainedAt: Date
        public init(token: String, expiresAt: Date?, obtainedAt: Date = Date()) {
            self.token = token; self.expiresAt = expiresAt; self.obtainedAt = obtainedAt
        }
        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }
}

/// Keychain boundary for scoped short-lived registration tokens.
public protocol RunnerRegistrationTokenStoring: Sendable {
    func save(_ token: RunnerRegistration.ScopedToken, scopeKey: String) async throws
    func load(scopeKey: String) async -> RunnerRegistration.ScopedToken?
    func delete(scopeKey: String) async
}

public actor RunnerRegistrationTokenStore: RunnerRegistrationTokenStoring {
    private let backend: any KeychainBackend
    private let service: String

    public init(
        service: String = "works.relux.runnercontrol.runner-registration-token",
        backend: (any KeychainBackend)? = nil
    ) {
        self.service = service
        self.backend = backend ?? SecurityKeychainBackend()
    }

    public func save(_ token: RunnerRegistration.ScopedToken, scopeKey: String) async throws {
        let data = try JSONEncoder().encode(token)
        try backend.save(data, service: service, account: scopeKey)
    }

    public func load(scopeKey: String) async -> RunnerRegistration.ScopedToken? {
        guard let data = backend.load(service: service, account: scopeKey) else { return nil }
        guard let decoded = try? JSONDecoder().decode(RunnerRegistration.ScopedToken.self, from: data) else {
            return nil
        }
        if decoded.isExpired {
            backend.delete(service: service, account: scopeKey)
            return nil
        }
        return decoded
    }

    public func delete(scopeKey: String) async {
        backend.delete(service: service, account: scopeKey)
    }
}

/// In-memory registration-token backend for unit tests. Never used in production.
public final class InMemoryRegistrationTokenBackend: KeychainBackend, @unchecked Sendable {
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
            let prefix = "\(service)\u{0}\(accountPrefix)"
            let doomed = storage.keys.filter { $0.hasPrefix(prefix) && $0.hasSuffix(accountSuffix) }
            for key in doomed {
                storage.removeValue(forKey: key)
            }
        }
    }
}
