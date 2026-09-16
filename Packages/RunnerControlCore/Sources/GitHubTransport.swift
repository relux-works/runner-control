import Foundation

/// Minimal HTTP boundary for GitHub Device Flow and REST. Keeps URLSession out of business logic.
public protocol GitHubHTTPTransport: Sendable {
    func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse
}

public struct GitHubHTTPRequest: Sendable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?
    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
    }
}

public struct GitHubHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
}

public enum GitHubTransportError: LocalizedError, Sendable, Equatable {
    case offline
    case invalidResponse
    public var errorDescription: String? {
        switch self {
        case .offline: "Network unavailable. Local runner control still works."
        case .invalidResponse: "Unexpected GitHub response."
        }
    }
}

extension GitHubAuth {
    // MARK: - Device DTOs

    public struct DeviceCodeRequest: Encodable, Sendable {
        public let client_id: String
        public init(client_id: String) { self.client_id = client_id }
    }

    public struct DeviceCodeResponse: Decodable, Sendable {
        public let device_code: String
        public let user_code: String
        public let verification_uri: String
        public let expires_in: Int
        public let interval: Int
        public init(device_code: String, user_code: String, verification_uri: String, expires_in: Int, interval: Int) {
            self.device_code = device_code; self.user_code = user_code; self.verification_uri = verification_uri
            self.expires_in = expires_in; self.interval = interval
        }
    }

    public struct TokenPollRequest: Encodable, Sendable {
        public let client_id: String
        public let device_code: String
        public let grant_type: String
        public init(client_id: String, device_code: String, grant_type: String) {
            self.client_id = client_id; self.device_code = device_code; self.grant_type = grant_type
        }
    }

    public struct TokenRefreshRequest: Encodable, Sendable {
        public let client_id: String
        public let grant_type: String
        public let refresh_token: String
        public init(client_id: String, grant_type: String, refresh_token: String) {
            self.client_id = client_id; self.grant_type = grant_type; self.refresh_token = refresh_token
        }
    }

    public struct TokenSuccessResponse: Decodable, Sendable {
        public let access_token: String?
        public let refresh_token: String?
        public let expires_in: Int?
        public let token_type: String?
        public let error: String?
        public let error_description: String?
        public let interval: Int?
        public init(access_token: String? = nil, refresh_token: String? = nil, expires_in: Int? = nil, token_type: String? = nil, error: String? = nil, error_description: String? = nil, interval: Int? = nil) {
            self.access_token = access_token; self.refresh_token = refresh_token; self.expires_in = expires_in
            self.token_type = token_type; self.error = error; self.error_description = error_description; self.interval = interval
        }
    }

    public struct UserResponse: Decodable, Sendable {
        public let login: String
        public let id: Int64
        public init(login: String, id: Int64) { self.login = login; self.id = id }
    }

    public struct InstallationsResponse: Decodable, Sendable {
        public let installations: [InstallationDTO]
        public init(installations: [InstallationDTO]) { self.installations = installations }
    }

    public struct InstallationDTO: Decodable, Sendable {
        public let id: Int64
        public let account: AccountDTO
        public init(id: Int64, account: AccountDTO) { self.id = id; self.account = account }
    }

    public struct AccountDTO: Decodable, Sendable {
        public let login: String
        public let type: String
        public init(login: String, type: String) { self.login = login; self.type = type }
    }

    public struct RepositoriesResponse: Decodable, Sendable {
        public let repositories: [RepositoryDTO]
        public init(repositories: [RepositoryDTO]) { self.repositories = repositories }
    }

    public struct RepositoryDTO: Decodable, Sendable {
        public let id: Int64
        public let full_name: String
        public let `private`: Bool
        public init(id: Int64, full_name: String, isPrivate: Bool) { self.id = id; self.full_name = full_name; self.private = isPrivate }
    }
}

/// Production URLSession transport. Never logs bodies (they may contain tokens).
public actor URLSessionGitHubTransport: GitHubHTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: GitHubHTTPRequest) async throws -> GitHubHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw GitHubTransportError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw GitHubTransportError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k] = v }
        }
        return GitHubHTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

extension GitHubAuth {
    /// Maps REST status codes to typed auth errors. Local runners are never touched here.
    public enum RESTMapper {
        public static func map(status: Int, body: Data) -> AuthError? {
            if status == 401 { return .unauthorized }
            if status == 403 {
                let text = String(decoding: body, as: UTF8.self).lowercased()
                if text.contains("saml") || text.contains("sso") { return .ssoRequired }
                if text.contains("rate limit") || text.contains("rate_limit") { return .rateLimited(retryAfter: nil) }
                let message = String(decoding: body, as: UTF8.self)
                let short = String(message.prefix(300))
                return .forbidden(short)
            }
            if status == 429 { return .rateLimited(retryAfter: nil) }
            return nil
        }
    }

    /// Rejects personal access tokens. Only Device Flow user tokens (ghu_) are accepted.
    public enum PATGuard {
        public static func validate(token: String) throws {
            if token.hasPrefix("ghp_") || token.hasPrefix("github_pat_") {
                throw AuthError.patNotSupported
            }
        }

        public static func authorizationHeader(token: String) throws -> String {
            try validate(token: token)
            return "Bearer \(token)"
        }
    }
}
