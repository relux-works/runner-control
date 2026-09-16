import Foundation

extension GitHubAuth {
    public enum PollResult: Sendable, Equatable {
        case pending
        case slowDown
        case success(accessToken: String, refreshToken: String?, expiresIn: Int?)
        case denied
        case expired
    }
}

/// Device Flow transport. Holds no tokens beyond the in-flight call.
public actor GitHubDeviceFlow {
    private let transport: any GitHubHTTPTransport

    public init(transport: any GitHubHTTPTransport) {
        self.transport = transport
    }

    public func requestCode(config: GitHubAuth.AppConfig) async throws -> GitHubAuth.DeviceCodeResponse {
        let body = try JSONEncoder().encode(GitHubAuth.DeviceCodeRequest(client_id: config.clientID))
        let request = GitHubHTTPRequest(
            method: "POST",
            url: config.deviceAuthorizationURL,
            headers: ["Accept": "application/json", "Content-Type": "application/json"],
            body: body
        )
        let response: GitHubHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw GitHubAuth.AuthError.network(GitHubTransportError.offline.localizedDescription)
        }
        guard response.status == 200 else {
            if let mapped = GitHubAuth.RESTMapper.map(status: response.status, body: response.body) {
                throw mapped
            }
            throw GitHubAuth.AuthError.network("Device code request failed (HTTP \(response.status)).")
        }
        do {
            return try JSONDecoder().decode(GitHubAuth.DeviceCodeResponse.self, from: response.body)
        } catch {
            throw GitHubAuth.AuthError.network(GitHubTransportError.invalidResponse.localizedDescription)
        }
    }

    public func pollOnce(config: GitHubAuth.AppConfig, deviceCode: String) async throws -> GitHubAuth.PollResult {
        let body = try JSONEncoder().encode(GitHubAuth.TokenPollRequest(
            client_id: config.clientID,
            device_code: deviceCode,
            grant_type: "urn:ietf:params:oauth:grant-type:device_code"
        ))
        let request = GitHubHTTPRequest(
            method: "POST",
            url: config.tokenURL,
            headers: ["Accept": "application/json", "Content-Type": "application/json"],
            body: body
        )
        let response: GitHubHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw GitHubAuth.AuthError.network(GitHubTransportError.offline.localizedDescription)
        }
        // HTTP 200 does not imply success: Device Flow reports errors in the body.
        let decoded: GitHubAuth.TokenSuccessResponse
        do {
            decoded = try JSONDecoder().decode(GitHubAuth.TokenSuccessResponse.self, from: response.body)
        } catch {
            throw GitHubAuth.AuthError.network(GitHubTransportError.invalidResponse.localizedDescription)
        }
        if let token = decoded.access_token, !token.isEmpty {
            try GitHubAuth.PATGuard.validate(token: token)
            return .success(accessToken: token, refreshToken: decoded.refresh_token, expiresIn: decoded.expires_in)
        }
        switch decoded.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        case "expired_token": return .expired
        case .none:
            throw GitHubAuth.AuthError.network(GitHubTransportError.invalidResponse.localizedDescription)
        case .some(let other):
            throw GitHubAuth.AuthError.network(decoded.error_description ?? other)
        }
    }

    /// slow_down increases the poll interval by 5 seconds (GitHub docs).
    public static func nextInterval(current: Int, after result: GitHubAuth.PollResult) -> Int {
        if result == .slowDown { return current + 5 }
        return current
    }
}
