import Foundation

/// Read-only discovery of user-owned runner service manifests. Never runs scripts.
public enum RunnerDiscovery {
    public static func installed(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Runners.Definition] {
        let fm = FileManager.default
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
        let root = home.appendingPathComponent("Library/GitHubActions")
        let agents = (try? fm.contentsOfDirectory(at: launchAgents, includingPropertiesForKeys: nil)) ?? []
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        // Prefer a standard service when both manifests describe the same registration.
        let candidates = agents.filter { $0.lastPathComponent.hasPrefix("actions.runner.") && $0.pathExtension == "plist" }.sorted { $0.path < $1.path }
            + folders.sorted { $0.path < $1.path }.map { $0.appendingPathComponent("manual-service.plist") }
        var ids = Set<String>()
        var directories = Set<String>()
        return candidates.compactMap { manifest in
            guard let data = try? Data(contentsOf: manifest),
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = object["Label"] as? String, label.hasPrefix("actions.runner."),
                  let path = object["WorkingDirectory"] as? String, path.hasPrefix("/"),
                  let args = object["ProgramArguments"] as? [String],
                  args == [URL(fileURLWithPath: path).appendingPathComponent("runsvc.sh").path] else { return nil }
            let directory = URL(fileURLWithPath: path)
            let canonical = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard !ids.contains(label), !directories.contains(canonical),
                  let registration = try? Data(contentsOf: directory.appendingPathComponent(".runner")),
                  let config = try? JSONSerialization.jsonObject(with: registration) as? [String: Any],
                  let name = config["agentName"] as? String, !name.isEmpty,
                  let address = config["gitHubUrl"] as? String,
                  let url = URL(string: address), url.scheme == "https", url.host != nil else { return nil }
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count == 1 || components.count == 2 else { return nil }
            let scope = components.joined(separator: "/")
            let settingsPath = components.count == 1
                ? "/organizations/\(scope)/settings/actions/runners"
                : "/\(scope)/settings/actions/runners"
            var settings = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            settings.path = settingsPath; settings.query = nil; settings.fragment = nil
            guard let settingsURL = settings.url else { return nil }
            ids.insert(label); directories.insert(canonical)
            return .init(id: label, title: name, detail: scope, directory: directory,
                         githubURL: settingsURL, servicePlist: manifest)
        }
    }
}
