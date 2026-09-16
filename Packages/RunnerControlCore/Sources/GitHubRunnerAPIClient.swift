import Foundation

/// GitHub REST client for self-hosted runner registration. Takes the user
/// token explicitly per call; never stores it.
public actor GitHubRunnerAPIClient {
    private let transport: any GitHubHTTPTransport

    public init(transport: any GitHubHTTPTransport) {
        self.transport = transport
    }

    private func authorizedHeaders(token: String) throws -> [String: String] {
        let header: String
        do {
            header = try GitHubAuth.PATGuard.authorizationHeader(token: token)
        } catch {
            throw GitHubAuth.AuthError.patNotSupported
        }
        return ["Accept": "application/vnd.github+json", "Authorization": header]
    }

    /// Builds a list URL with real query items. Query strings must never be
    /// smuggled through `appendingPathComponent`: Foundation percent-encodes
    /// the `?` into the path (`%3F`) and GitHub never sees the parameters.
    private func listURL(
        config: GitHubAuth.AppConfig, path: String, queryItems: [URLQueryItem]
    ) throws -> URL {
        let base = config.apiBaseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw RunnerRegistration.RegistrationError.network("Invalid GitHub API URL for \(path).")
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw RunnerRegistration.RegistrationError.network("Invalid GitHub API URL for \(path).")
        }
        return url
    }

    private func send(
        method: String,
        config: GitHubAuth.AppConfig,
        path: String,
        token: String,
        body: Data? = nil
    ) async throws -> GitHubHTTPResponse {
        let url = config.apiBaseURL.appendingPathComponent(path)
        return try await perform(method: method, url: url, token: token, body: body)
    }

    private func perform(
        method: String,
        url: URL,
        token: String,
        body: Data? = nil
    ) async throws -> GitHubHTTPResponse {
        let headers = try authorizedHeaders(token: token)
        var all = headers
        if body != nil { all["Content-Type"] = "application/json" }
        let request = GitHubHTTPRequest(
            method: method,
            url: url,
            headers: all,
            body: body
        )
        let response: GitHubHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw RunnerRegistration.RegistrationError.network(
                GitHubTransportError.offline.localizedDescription
            )
        }
        switch response.status {
        // 204 is the documented success for PUT …/repositories; rejecting
        // it fails every production repository-access update (review F2).
        case 200, 201, 204:
            return response
        case 401:
            throw RunnerRegistration.RegistrationError.unauthorized
        case 403:
            throw RunnerRegistration.RegistrationError.forbidden(
                String(String(decoding: response.body, as: UTF8.self).prefix(300))
            )
        case 404:
            throw RunnerRegistration.RegistrationError.network("GitHub resource not found (404): \(url.path).")
        case 422:
            throw RunnerRegistration.RegistrationError.network(
                "GitHub rejected the request (422): " +
                    String(String(decoding: response.body, as: UTF8.self).prefix(300))
            )
        default:
            if response.status == 429
                || String(decoding: response.body, as: UTF8.self).lowercased().contains("rate limit") {
                throw RunnerRegistration.RegistrationError.rateLimited
            }
            throw RunnerRegistration.RegistrationError.network(
                "GitHub request failed (HTTP \(response.status))."
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: GitHubHTTPResponse) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw RunnerRegistration.RegistrationError.network(
                GitHubTransportError.invalidResponse.localizedDescription
            )
        }
    }

    // MARK: - Pagination (complete lists, never first-page-only)

    private static let listPageSize = "100"
    /// Hard stop against a non-terminating `Link` chain. Any failure —
    /// including hitting this cap — throws, so a partial list is never
    /// presented as a complete confirmation.
    private static let maxListPages = 100

    private static func listQuery() -> [URLQueryItem] {
        [URLQueryItem(name: "per_page", value: listPageSize)]
    }

    /// Parses the `Link` header's `rel="next"` URL. Returns nil when there is
    /// no next page. Refuses non-HTTPS or off-host URLs instead of following
    /// a crafted redirect.
    static func nextPageURL(headers: [String: String], allowedHost: String?) -> URL? {
        guard let link = headers.first(where: { $0.key.lowercased() == "link" })?.value else { return nil }
        for part in link.split(separator: ",") {
            let segments = part.split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard segments.count >= 2 else { continue }
            let raw = segments[0]
            guard raw.hasPrefix("<"), raw.hasSuffix(">") else { continue }
            let candidate = String(raw.dropFirst().dropLast())
            let isNext = segments.dropFirst().contains {
                $0.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "") == "rel=next"
            }
            guard isNext, let url = URL(string: candidate) else { continue }
            guard url.scheme == "https",
                  url.host?.lowercased() == allowedHost?.lowercased() else { continue }
            return url
        }
        return nil
    }

    /// Follows every page of a list endpoint, starting at `path`. Throws on
    /// any failed page so callers fail closed instead of acting on a partial
    /// list.
    private func getAllPages(
        config: GitHubAuth.AppConfig,
        path: String,
        token: String
    ) async throws -> [GitHubHTTPResponse] {
        var pages: [GitHubHTTPResponse] = []
        var url: URL? = try listURL(config: config, path: path, queryItems: Self.listQuery())
        while let current = url {
            guard pages.count < Self.maxListPages else {
                throw RunnerRegistration.RegistrationError.network(
                    "GitHub list pagination did not terminate for \(path)."
                )
            }
            let response = try await perform(method: "GET", url: current, token: token)
            pages.append(response)
            url = Self.nextPageURL(headers: response.headers, allowedHost: config.apiBaseURL.host)
        }
        return pages
    }

    // MARK: - Downloads

    public func fetchDownloads(
        config: GitHubAuth.AppConfig,
        token: String,
        scope: RunnerRegistration.Scope
    ) async throws -> [RunnerRegistration.DownloadAsset] {
        let response: GitHubHTTPResponse
        do {
            response = try await send(
                method: "GET", config: config,
                path: "\(scope.apiPrefix)/actions/runners/downloads", token: token
            )
        } catch let error as RunnerRegistration.RegistrationError {
            if case .forbidden(let text) = error {
                throw RunnerRegistration.RegistrationError.missingPermission(readHelp(scope: scope, detail: text))
            }
            throw error
        }
        let decoded = try decode([RunnerDownloadDTO].self, from: response)
        return decoded.compactMap { dto -> RunnerRegistration.DownloadAsset? in
            guard let url = URL(string: dto.downloadURL) else { return nil }
            return .init(
                osName: dto.osName, architecture: dto.architecture,
                downloadURL: url, filename: dto.filename,
                sha256Checksum: dto.sha256Checksum
            )
        }
    }

    // MARK: - Registration token (short-lived, single use)

    public func createRegistrationToken(
        config: GitHubAuth.AppConfig,
        token: String,
        scope: RunnerRegistration.Scope
    ) async throws -> (token: String, expiresAt: Date?) {
        let response: GitHubHTTPResponse
        do {
            response = try await send(
                method: "POST", config: config,
                path: "\(scope.apiPrefix)/actions/runners/registration-token", token: token
            )
        } catch let error as RunnerRegistration.RegistrationError {
            if case .forbidden(let text) = error {
                throw RunnerRegistration.RegistrationError.missingPermission(permissionHelp(scope: scope, detail: text))
            }
            throw error
        }
        let decoded = try decode(RegistrationTokenDTO.self, from: response)
        guard !decoded.token.isEmpty else {
            throw RunnerRegistration.RegistrationError.network(
                GitHubTransportError.invalidResponse.localizedDescription
            )
        }
        var expiresAt: Date?
        if let raw = decoded.expiresAt {
            expiresAt = ISO8601DateFormatter().date(from: raw)
        }
        return (decoded.token, expiresAt)
    }

    private func permissionHelp(scope: RunnerRegistration.Scope, detail: String) -> String {
        writeHelp(scope: scope, detail: detail)
    }

    private func readHelp(scope: RunnerRegistration.Scope, detail: String) -> String {
        let need: String
        switch scope {
        case .organization:
            need = "Self-hosted runners/read for the organization"
        case .repository:
            need = "Administration/read for the repository"
        }
        let suffix = detail.isEmpty ? "" : " GitHub says: \(detail)"
        return "Missing permission: \(need).\(suffix)"
    }

    private func writeHelp(scope: RunnerRegistration.Scope, detail: String) -> String {
        let need: String
        switch scope {
        case .organization:
            need = "Self-hosted runners/write for the organization"
        case .repository:
            need = "Administration/write for the repository"
        }
        let suffix = detail.isEmpty ? "" : " GitHub says: \(detail)"
        return "Missing permission: \(need).\(suffix)"
    }

    private func groupReadHelp(org: String, detail: String) -> String {
        let suffix = detail.isEmpty ? "" : " GitHub says: \(detail)"
        return "Missing permission: Self-hosted runners/read for the organization \(org).\(suffix)"
    }

    // MARK: - Runners (fetch real IDs)

    public func fetchRunners(
        config: GitHubAuth.AppConfig,
        token: String,
        scope: RunnerRegistration.Scope
    ) async throws -> [RunnerRegistration.RegisteredRunner] {
        let pages: [GitHubHTTPResponse]
        do {
            pages = try await getAllPages(
                config: config,
                path: "\(scope.apiPrefix)/actions/runners", token: token
            )
        } catch let error as RunnerRegistration.RegistrationError {
            if case .forbidden(let text) = error {
                throw RunnerRegistration.RegistrationError.missingPermission(readHelp(scope: scope, detail: text))
            }
            throw error
        }
        return try pages.flatMap { page in
            try decode(RunnersListDTO.self, from: page).runners.map {
                RunnerRegistration.RegisteredRunner(
                    id: $0.id, name: $0.name, labels: $0.labels.map(\.name),
                    status: $0.status, busy: $0.busy
                )
            }
        }
    }

    // MARK: - Remove token (short-lived, single use)

    /// Mints a short-lived remove token for explicit unregister. The token
    /// is consumed by `config.sh remove` and never stored.
    public func createRemoveToken(
        config: GitHubAuth.AppConfig,
        token: String,
        scope: RunnerRegistration.Scope
    ) async throws -> (token: String, expiresAt: Date?) {
        let response: GitHubHTTPResponse
        do {
            response = try await send(
                method: "POST", config: config,
                path: "\(scope.apiPrefix)/actions/runners/remove-token", token: token
            )
        } catch let error as RunnerRegistration.RegistrationError {
            if case .forbidden(let text) = error {
                throw RunnerRegistration.RegistrationError.missingPermission(writeHelp(scope: scope, detail: text))
            }
            throw error
        }
        let decoded = try decode(RegistrationTokenDTO.self, from: response)
        guard !decoded.token.isEmpty else {
            throw RunnerRegistration.RegistrationError.network(
                GitHubTransportError.invalidResponse.localizedDescription
            )
        }
        var expiresAt: Date?
        if let raw = decoded.expiresAt {
            expiresAt = ISO8601DateFormatter().date(from: raw)
        }
        return (decoded.token, expiresAt)
    }

    // MARK: - Runner groups (org only)

    public func fetchGroups(
        config: GitHubAuth.AppConfig,
        token: String,
        org: String
    ) async throws -> [RunnerRegistration.RunnerGroup] {
        let pages: [GitHubHTTPResponse]
        do {
            pages = try await getAllPages(
                config: config,
                path: "orgs/\(org)/actions/runner-groups", token: token
            )
        } catch let error as RunnerRegistration.RegistrationError {
            if case .forbidden(let text) = error {
                throw RunnerRegistration.RegistrationError.missingPermission(groupReadHelp(org: org, detail: text))
            }
            throw error
        }
        return try pages.flatMap { page in
            try decode(RunnerGroupsListDTO.self, from: page).runnerGroups.map {
                RunnerRegistration.RunnerGroup(
                    id: $0.id, name: $0.name, visibility: $0.visibility,
                    allowsPublicRepositories: $0.allowsPublicRepositories ?? false
                )
            }
        }
    }

    public func createGroup(
        config: GitHubAuth.AppConfig,
        token: String,
        org: String,
        name: String,
        selectedRepositoryIDs: Set<Int64>,
        allowsPublicRepositories: Bool = true
    ) async throws -> RunnerRegistration.RunnerGroup {
        let payload = CreateGroupDTO(
            name: name, visibility: "selected",
            selectedRepositoryIDs: Array(selectedRepositoryIDs).sorted(),
            allowsPublicRepositories: allowsPublicRepositories
        )
        let body = try JSONEncoder().encode(payload)
        let response: GitHubHTTPResponse
        do {
            response = try await send(
                method: "POST", config: config,
                path: "orgs/\(org)/actions/runner-groups", token: token, body: body
            )
        } catch let error as RunnerRegistration.RegistrationError {
            if case .forbidden(let text) = error {
                throw RunnerRegistration.RegistrationError.missingPermission(
                    permissionHelp(scope: .organization(org: org), detail: text)
                )
            }
            throw error
        }
        let decoded = try decode(RunnerGroupDTO.self, from: response)
        return .init(
            id: decoded.id, name: decoded.name, visibility: decoded.visibility,
            allowsPublicRepositories: decoded.allowsPublicRepositories ?? allowsPublicRepositories
        )
    }

    /// Enables selected public repositories on an owned dedicated group.
    /// GitHub defaults `allows_public_repositories` to false, which silently
    /// denies every selected public repo; dedicated per-Mac groups always
    /// opt in because `selected` visibility still bounds access to the
    /// chosen repository IDs.
    public func updateGroupAllowsPublic(
        config: GitHubAuth.AppConfig,
        token: String,
        org: String,
        groupID: Int64,
        allowsPublic: Bool
    ) async throws -> RunnerRegistration.RunnerGroup {
        let payload = UpdateGroupDTO(allowsPublicRepositories: allowsPublic)
        let body = try JSONEncoder().encode(payload)
        let response: GitHubHTTPResponse
        do {
            response = try await send(
                method: "PATCH", config: config,
                path: "orgs/\(org)/actions/runner-groups/\(groupID)", token: token, body: body
            )
        } catch let error as RunnerRegistration.RegistrationError {
            if case .forbidden(let text) = error {
                throw RunnerRegistration.RegistrationError.missingPermission(
                    permissionHelp(scope: .organization(org: org), detail: text)
                )
            }
            throw error
        }
        let decoded = try decode(RunnerGroupDTO.self, from: response)
        return .init(
            id: decoded.id, name: decoded.name, visibility: decoded.visibility,
            allowsPublicRepositories: decoded.allowsPublicRepositories ?? allowsPublic
        )
    }

    /// Lists the runners currently in a group (every page followed).
    /// Used to resolve fresh API group membership for imported runners:
    /// local `.runner` pool fields can lag server-side moves, so the
    /// membership answer always comes from this endpoint, matched by
    /// agent ID, never by name.
    public func fetchGroupRunners(
        config: GitHubAuth.AppConfig,
        token: String,
        org: String,
        groupID: Int64
    ) async throws -> [RunnerRegistration.RegisteredRunner] {
        let pages: [GitHubHTTPResponse]
        do {
            pages = try await getAllPages(
                config: config,
                path: "orgs/\(org)/actions/runner-groups/\(groupID)/runners", token: token
            )
        } catch let error as RunnerRegistration.RegistrationError {
            if case .forbidden(let text) = error {
                throw RunnerRegistration.RegistrationError.missingPermission(groupReadHelp(org: org, detail: text))
            }
            throw error
        }
        return try pages.flatMap { page in
            try decode(RunnersListDTO.self, from: page).runners.map {
                RunnerRegistration.RegisteredRunner(
                    id: $0.id, name: $0.name, labels: $0.labels.map(\.name),
                    status: $0.status, busy: $0.busy
                )
            }
        }
    }

    public func fetchGroupRepositories(
        config: GitHubAuth.AppConfig,
        token: String,
        org: String,
        groupID: Int64
    ) async throws -> [Int64] {
        let pages: [GitHubHTTPResponse]
        do {
            pages = try await getAllPages(
                config: config,
                path: "orgs/\(org)/actions/runner-groups/\(groupID)/repositories", token: token
            )
        } catch let error as RunnerRegistration.RegistrationError {
            if case .forbidden(let text) = error {
                throw RunnerRegistration.RegistrationError.missingPermission(groupReadHelp(org: org, detail: text))
            }
            throw error
        }
        return try pages.flatMap { page in
            try decode(GroupRepositoriesDTO.self, from: page).repositories.map(\.id)
        }
    }

    public func setGroupRepositories(
        config: GitHubAuth.AppConfig,
        token: String,
        org: String,
        groupID: Int64,
        selectedRepositoryIDs: Set<Int64>
    ) async throws {
        let payload = SetGroupRepositoriesDTO(selectedRepositoryIDs: Array(selectedRepositoryIDs).sorted())
        let body = try JSONEncoder().encode(payload)
        do {
            _ = try await send(
                method: "PUT", config: config,
                path: "orgs/\(org)/actions/runner-groups/\(groupID)/repositories", token: token, body: body
            )
        } catch let error as RunnerRegistration.RegistrationError {
            if case .forbidden(let text) = error {
                throw RunnerRegistration.RegistrationError.missingPermission(
                    permissionHelp(scope: .organization(org: org), detail: text)
                )
            }
            throw error
        }
    }

    // MARK: - Labels (editable after registration)

    public func setRunnerLabels(
        config: GitHubAuth.AppConfig,
        token: String,
        scope: RunnerRegistration.Scope,
        runnerID: Int64,
        labels: [String]
    ) async throws {
        let payload = SetLabelsDTO(labels: labels)
        let body = try JSONEncoder().encode(payload)
        do {
            _ = try await send(
                method: "PUT", config: config,
                path: "\(scope.apiPrefix)/actions/runners/\(runnerID)/labels", token: token, body: body
            )
        } catch let error as RunnerRegistration.RegistrationError {
            if case .forbidden(let text) = error {
                throw RunnerRegistration.RegistrationError.missingPermission(writeHelp(scope: scope, detail: text))
            }
            throw error
        }
    }
}

// MARK: - DTOs

private struct RunnerDownloadDTO: Decodable, Sendable {
    let osName: String
    let architecture: String
    let downloadURL: String
    let filename: String
    let sha256Checksum: String?

    private enum CodingKeys: String, CodingKey {
        case osName = "os"
        case architecture
        case downloadURL = "download_url"
        case filename
        case sha256Checksum = "sha256_checksum"
    }
}

private struct RegistrationTokenDTO: Decodable, Sendable {
    let token: String
    let expiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

private struct RunnersListDTO: Decodable, Sendable {
    let runners: [RunnerDTO]
}

private struct RunnerDTO: Decodable, Sendable {
    let id: Int64
    let name: String
    let labels: [LabelDTO]
    let status: String?
    let busy: Bool?
}

private struct LabelDTO: Decodable, Sendable {
    let name: String
}

private struct RunnerGroupsListDTO: Decodable, Sendable {
    let runnerGroups: [RunnerGroupDTO]

    private enum CodingKeys: String, CodingKey {
        case runnerGroups = "runner_groups"
    }
}

private struct RunnerGroupDTO: Decodable, Sendable {
    let id: Int64
    let name: String
    let visibility: String
    let allowsPublicRepositories: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case visibility
        case allowsPublicRepositories = "allows_public_repositories"
    }
}

private struct GroupRepositoriesDTO: Decodable, Sendable {
    let repositories: [GroupRepositoryDTO]
}

private struct GroupRepositoryDTO: Decodable, Sendable {
    let id: Int64
}

private struct CreateGroupDTO: Encodable, Sendable {
    let name: String
    let visibility: String
    let selectedRepositoryIDs: [Int64]
    let allowsPublicRepositories: Bool

    private enum CodingKeys: String, CodingKey {
        case name
        case visibility
        case selectedRepositoryIDs = "selected_repository_ids"
        case allowsPublicRepositories = "allows_public_repositories"
    }
}

private struct UpdateGroupDTO: Encodable, Sendable {
    let allowsPublicRepositories: Bool

    private enum CodingKeys: String, CodingKey {
        case allowsPublicRepositories = "allows_public_repositories"
    }
}

private struct SetGroupRepositoriesDTO: Encodable, Sendable {
    let selectedRepositoryIDs: [Int64]

    private enum CodingKeys: String, CodingKey {
        case selectedRepositoryIDs = "selected_repository_ids"
    }
}

private struct SetLabelsDTO: Encodable, Sendable {
    let labels: [String]
}
