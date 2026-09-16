import Foundation

/// Serialized token refresh. Concurrent callers coalesce to a single network refresh.
public actor GitHubTokenRefresh {
    private let transport: any GitHubHTTPTransport
    private let store: any GitHubCredentialStoring
    private let now: @Sendable () -> Date
    private var inFlight: Task<GitHubAuth.TokenRecord, Error>?

    public init(
        transport: any GitHubHTTPTransport,
        store: any GitHubCredentialStoring,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.store = store
        self.now = now
    }

    /// Cancels the in-flight refresh so a superseding logout/login leaves no token behind.
    /// Callers awaiting the cancelled refresh observe `CancellationError`.
    public func cancelInFlight() {
        inFlight?.cancel()
        inFlight = nil
    }

    public func refresh(
        config: GitHubAuth.AppConfig,
        userID: Int64,
        current: GitHubAuth.TokenRecord
    ) async throws -> GitHubAuth.TokenRecord {
        // Fast path: another task already refreshed while we waited.
        if let latest = await store.load(serverHost: config.serverHost, userID: userID, clientID: config.clientID),
           latest.accessToken != current.accessToken {
            return latest
        }
        if let flight = inFlight {
            return try await flight.value
        }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw GitHubAuth.AuthError.tokenRefreshFailed
        }
        let transportCopy = transport
        let storeCopy = store
        let nowCopy = now
        let task: Task<GitHubAuth.TokenRecord, Error> = Task {
            let body = try JSONEncoder().encode(GitHubAuth.TokenRefreshRequest(
                client_id: config.clientID,
                grant_type: "refresh_token",
                refresh_token: refreshToken
            ))
            let request = GitHubHTTPRequest(
                method: "POST",
                url: config.tokenURL,
                headers: ["Accept": "application/json", "Content-Type": "application/json"],
                body: body
            )
            let response: GitHubHTTPResponse
            do {
                response = try await transportCopy.send(request)
            } catch {
                throw GitHubAuth.AuthError.network(GitHubTransportError.offline.localizedDescription)
            }
            let decoded: GitHubAuth.TokenSuccessResponse
            do {
                decoded = try JSONDecoder().decode(GitHubAuth.TokenSuccessResponse.self, from: response.body)
            } catch {
                throw GitHubAuth.AuthError.network(GitHubTransportError.invalidResponse.localizedDescription)
            }
            if let token = decoded.access_token, !token.isEmpty {
                try GitHubAuth.PATGuard.validate(token: token)
                let expiresAt: Date?
                if let seconds = decoded.expires_in {
                    expiresAt = nowCopy().addingTimeInterval(TimeInterval(seconds))
                } else {
                    expiresAt = nil
                }
                let next = GitHubAuth.TokenRecord(
                    accessToken: token,
                    refreshToken: decoded.refresh_token ?? refreshToken,
                    expiresAt: expiresAt,
                    obtainedAt: nowCopy()
                )
                // A superseding logout/login must not leave refreshed tokens behind.
                if Task.isCancelled { throw CancellationError() }
                try await storeCopy.save(next, serverHost: config.serverHost, userID: userID, clientID: config.clientID)
                if Task.isCancelled {
                    // Lost a race with cancel during the save: remove the orphan,
                    // but never touch tokens a newer login may have stored since.
                    if let current = await storeCopy.load(serverHost: config.serverHost, userID: userID, clientID: config.clientID),
                       current.accessToken == next.accessToken {
                        await storeCopy.delete(serverHost: config.serverHost, userID: userID, clientID: config.clientID)
                    }
                    throw CancellationError()
                }
                return next
            }
            if decoded.error == "invalid_grant" {
                throw GitHubAuth.AuthError.revoked
            }
            throw GitHubAuth.AuthError.tokenRefreshFailed
        }
        inFlight = task
        do {
            let value = try await task.value
            inFlight = nil
            return value
        } catch {
            inFlight = nil
            throw error
        }
    }

    public static func isExpiringSoon(_ record: GitHubAuth.TokenRecord, now: Date = Date(), within seconds: TimeInterval = 60) -> Bool {
        guard let expiresAt = record.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= seconds
    }
}
