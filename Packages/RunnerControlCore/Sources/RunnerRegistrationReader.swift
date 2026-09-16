import Foundation

/// Reads the local `.runner` registration without touching `.credentials`.
/// Never executes scripts. Does not rely on the service label format to
/// determine the organization or scope.
public enum RunnerRegistrationReader {
    public struct Info: Sendable, Equatable {
        public let agentID: Int64?
        public let agentName: String?
        public let gitHubURL: String?
        public let workFolder: String?
        public let serverHost: String?
        /// "org" for a single path component, "repo" for owner/name.
        public let scopeKind: String?
        /// Detail line: `acme` or `acme/app`.
        public let scopeDetail: String?

        public init(agentID: Int64?, agentName: String?, gitHubURL: String?, workFolder: String?, serverHost: String?, scopeKind: String?, scopeDetail: String?) {
            self.agentID = agentID
            self.agentName = agentName
            self.gitHubURL = gitHubURL
            self.workFolder = workFolder
            self.serverHost = serverHost
            self.scopeKind = scopeKind
            self.scopeDetail = scopeDetail
        }
    }

    /// Reads `.runner` only. Returns nil when the file is missing or
    /// unparseable; a present but incomplete file returns a partial struct
    /// so validation can name the exact missing field.
    public static func read(directory: URL) -> Info? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".runner")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var agentID: Int64?
        if let id = object["agentId"] as? Int64 { agentID = id }
        else if let id = object["agentId"] as? Int { agentID = Int64(id) }
        else if let id = object["agentId"] as? NSNumber { agentID = id.int64Value }
        let agentName = object["agentName"] as? String
        let gitHubURL = object["gitHubUrl"] as? String
        let workFolder = object["workFolder"] as? String
        var serverHost: String?
        var scopeKind: String?
        var scopeDetail: String?
        if let address = gitHubURL, let url = URL(string: address), url.scheme == "https", let host = url.host {
            serverHost = host
            let components = url.pathComponents.filter { $0 != "/" }
            if components.count == 1 {
                scopeKind = "org"
                scopeDetail = components[0]
            } else if components.count == 2 {
                scopeKind = "repo"
                scopeDetail = components.joined(separator: "/")
            }
        }
        return Info(
            agentID: agentID, agentName: agentName, gitHubURL: gitHubURL,
            workFolder: workFolder, serverHost: serverHost,
            scopeKind: scopeKind, scopeDetail: scopeDetail
        )
    }

    /// Settings URL for the registration scope, e.g.
    /// `/organizations/acme/settings/actions/runners` or `/acme/app/...`.
    /// Returns nil when server or scope is undefined.
    public static func settingsURL(info: Info) -> URL? {
        guard let address = info.gitHubURL, let url = URL(string: address),
              let kind = info.scopeKind, let scope = info.scopeDetail else { return nil }
        let path = kind == "org" ? "/organizations/\(scope)/settings/actions/runners" : "/\(scope)/settings/actions/runners"
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}
