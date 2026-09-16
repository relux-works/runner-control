import Foundation

/// GitHub REST client for user/installation/repository reads. Takes tokens explicitly; never stores them.
public actor GitHubAPIClient {
    private let transport: any GitHubHTTPTransport

    public init(transport: any GitHubHTTPTransport) {
        self.transport = transport
    }

    private func get(config: GitHubAuth.AppConfig, path: String, token: String) async throws -> GitHubHTTPResponse {
        let header: String
        do {
            header = try GitHubAuth.PATGuard.authorizationHeader(token: token)
        } catch {
            throw GitHubAuth.AuthError.patNotSupported
        }
        let url = config.apiBaseURL.appendingPathComponent(path)
        let request = GitHubHTTPRequest(
            method: "GET",
            url: url,
            headers: ["Accept": "application/vnd.github+json", "Authorization": header]
        )
        let response: GitHubHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw GitHubAuth.AuthError.network(GitHubTransportError.offline.localizedDescription)
        }
        if response.status == 200 { return response }
        if let mapped = GitHubAuth.RESTMapper.map(status: response.status, body: response.body) {
            throw mapped
        }
        throw GitHubAuth.AuthError.network("GitHub request failed (HTTP \(response.status)).")
    }

    public func fetchUser(config: GitHubAuth.AppConfig, token: String) async throws -> GitHubAuth.UserResponse {
        let response = try await get(config: config, path: "user", token: token)
        do {
            return try JSONDecoder().decode(GitHubAuth.UserResponse.self, from: response.body)
        } catch {
            throw GitHubAuth.AuthError.network(GitHubTransportError.invalidResponse.localizedDescription)
        }
    }

    public func fetchInstallations(config: GitHubAuth.AppConfig, token: String) async throws -> [GitHubAuth.Installation] {
        let response = try await get(config: config, path: "user/installations", token: token)
        do {
            let decoded = try JSONDecoder().decode(GitHubAuth.InstallationsResponse.self, from: response.body)
            return decoded.installations.map { GitHubAuth.Installation(id: $0.id, account: $0.account.login, accountType: $0.account.type) }
        } catch let error as GitHubAuth.AuthError {
            throw error
        } catch {
            throw GitHubAuth.AuthError.network(GitHubTransportError.invalidResponse.localizedDescription)
        }
    }

    public func fetchRepositories(config: GitHubAuth.AppConfig, token: String, installationID: Int64) async throws -> [GitHubAuth.Repository] {
        let response = try await get(config: config, path: "user/installations/\(installationID)/repositories", token: token)
        do {
            let decoded = try JSONDecoder().decode(GitHubAuth.RepositoriesResponse.self, from: response.body)
            return decoded.repositories.map { GitHubAuth.Repository(id: $0.id, fullName: $0.full_name, isPrivate: $0.private) }
        } catch let error as GitHubAuth.AuthError {
            throw error
        } catch {
            throw GitHubAuth.AuthError.network(GitHubTransportError.invalidResponse.localizedDescription)
        }
    }
}
