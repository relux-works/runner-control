import Foundation

/// Read-only discovery of user-owned runner service manifests. Never runs scripts.
/// Never reads `.credentials`.
public enum RunnerDiscovery {
    /// A discovery candidate with its verification state. Discovery never
    /// launches anything; the user explicitly adds a candidate.
    public struct Candidate: Sendable, Equatable, Identifiable {
        public let directory: URL
        public let manifest: URL?
        public let label: String?
        public let controllerKind: Runners.ControllerKind
        public let agentName: String?
        public let scope: String?
        public let serverHost: String?
        public let agentID: Int64?
        public let workFolder: String?
        public let runAtLoad: Bool?
        public let runsvcExists: Bool
        public let binaryExists: Bool
        public let registrationReadable: Bool
        public let manifestMatches: Bool
        public let noSpacePath: Bool
        public let noSpaceWork: Bool
        public let unsupportedReason: String?
        public let issues: [String]

        public var id: String { directory.path + "|" + (manifest?.path ?? "-") }

        /// Importable when every check passes and control is supported.
        public var isImportable: Bool {
            controllerKind.canControl && unsupportedReason == nil && issues.isEmpty
                && registrationReadable && manifestMatches && noSpacePath && noSpaceWork
                && runsvcExists && binaryExists
                && agentName != nil && scope != nil && serverHost != nil
        }

        /// Needs relocation when the only blocker is a spaced path.
        public var needsRelocation: Bool {
            !noSpacePath && registrationReadable && runsvcExists && binaryExists
        }

        public init(
            directory: URL, manifest: URL? = nil, label: String? = nil,
            controllerKind: Runners.ControllerKind = .manualManaged,
            agentName: String? = nil, scope: String? = nil, serverHost: String? = nil,
            agentID: Int64? = nil, workFolder: String? = nil, runAtLoad: Bool? = nil,
            runsvcExists: Bool = false, binaryExists: Bool = false,
            registrationReadable: Bool = false, manifestMatches: Bool = false,
            noSpacePath: Bool = true, noSpaceWork: Bool = true,
            unsupportedReason: String? = nil, issues: [String] = []
        ) {
            self.directory = directory
            self.manifest = manifest
            self.label = label
            self.controllerKind = controllerKind
            self.agentName = agentName
            self.scope = scope
            self.serverHost = serverHost
            self.agentID = agentID
            self.workFolder = workFolder
            self.runAtLoad = runAtLoad
            self.runsvcExists = runsvcExists
            self.binaryExists = binaryExists
            self.registrationReadable = registrationReadable
            self.manifestMatches = manifestMatches
            self.noSpacePath = noSpacePath
            self.noSpaceWork = noSpaceWork
            self.unsupportedReason = unsupportedReason
            self.issues = issues
        }
    }
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

    // MARK: - Candidates

    /// Discovers candidates in the allowed places without scanning the whole
    /// disk: the managed `~/Library/GitHubActions` root, known
    /// `actions.runner.*` manifests in `~/Library/LaunchAgents`, and
    /// previously chosen directories. `knownCanonicals` excludes directories
    /// already in the catalog. Never launches anything.
    public static func discoverCandidates(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        knownCanonicals: Set<String> = [],
        extraDirectories: [URL] = []
    ) -> [Candidate] {
        let fm = FileManager.default
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
        let root = home.appendingPathComponent("Library/GitHubActions")
        let agents = ((try? fm.contentsOfDirectory(at: launchAgents, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("actions.runner.") && $0.pathExtension == "plist" }
            .sorted { $0.path < $1.path }
        let folders = (((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            + extraDirectories).sorted { $0.path < $1.path }
        var seen = knownCanonicals
        var values: [Candidate] = []
        // Standard services first: when both manifests describe the same
        // registration the standard one wins and the manual duplicate is skipped.
        for manifest in agents {
            let candidate = validateManifest(manifest)
            let canonical = candidate.directory.resolvingSymlinksInPath().standardizedFileURL.path
            if seen.contains(canonical) { continue }
            seen.insert(canonical)
            values.append(candidate)
        }
        for folder in folders {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let canonical = folder.resolvingSymlinksInPath().standardizedFileURL.path
            if seen.contains(canonical) { continue }
            seen.insert(canonical)
            let manual = folder.appendingPathComponent("manual-service.plist")
            if fm.fileExists(atPath: manual.path) {
                values.append(validateManifest(manual, fallbackDirectory: folder))
            } else if fm.fileExists(atPath: folder.appendingPathComponent(".runner").path) {
                values.append(validateFolder(folder))
            }
        }
        return values
    }

    /// Validates an arbitrary user-chosen folder. Checks `.runner`,
    /// server/scope, binaries, spaces and manifest match. Never executes
    /// candidate scripts and never reads `.credentials`.
    public static func validateFolder(_ folder: URL) -> Candidate {
        let fm = FileManager.default
        let info = RunnerRegistrationReader.read(directory: folder)
        let runsvcExists = fm.fileExists(atPath: folder.appendingPathComponent("runsvc.sh").path)
        let binaryExists = fm.fileExists(atPath: folder.appendingPathComponent("run.sh").path)
        let noSpacePath = !folder.path.contains(" ")
        let work = info?.workFolder ?? ""
        let noSpaceWork = !work.contains(" ")
        var issues: [String] = []
        if info == nil { issues.append("Cannot read .runner registration.") }
        else {
            if (info?.agentName ?? "").isEmpty { issues.append("Registration name is missing.") }
            if info?.serverHost == nil || info?.scopeDetail == nil { issues.append("Server or scope is undefined.") }
            if work.isEmpty { issues.append("Work folder is missing.") }
        }
        if !runsvcExists { issues.append("runsvc.sh is missing.") }
        if !binaryExists { issues.append("run.sh is missing.") }
        if !noSpacePath { issues.append("Path contains a space; relocation is required.") }
        if !noSpaceWork { issues.append("Work folder contains a space.") }
        let manual = folder.appendingPathComponent("manual-service.plist")
        if fm.fileExists(atPath: manual.path) {
            return validateManifest(manual, fallbackDirectory: folder)
        }
        issues.append("No service manifest; adding will create a manual service (RunAtLoad off).")
        return Candidate(
            directory: folder, manifest: nil, label: nil,
            controllerKind: .manualManaged,
            agentName: info?.agentName, scope: info?.scopeDetail,
            serverHost: info?.serverHost, agentID: info?.agentID,
            workFolder: info?.workFolder, runAtLoad: false,
            runsvcExists: runsvcExists, binaryExists: binaryExists,
            registrationReadable: info != nil, manifestMatches: false,
            noSpacePath: noSpacePath, noSpaceWork: noSpaceWork,
            issues: issues
        )
    }

    /// Validates one manifest file against its working directory. Manifests
    /// that do not match the expected runsvc shape become unsupported
    /// candidates with an explicit reason instead of a fake toggle.
    public static func validateManifest(_ manifest: URL, fallbackDirectory: URL? = nil) -> Candidate {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: manifest),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = object["Label"] as? String else {
            let dir = fallbackDirectory ?? manifest.deletingLastPathComponent()
            return Candidate(
                directory: dir, manifest: manifest, label: nil,
                controllerKind: .unsupported,
                unsupportedReason: "Manifest is unreadable.",
                issues: ["Manifest is unreadable."]
            )
        }
        let kind: Runners.ControllerKind = manifest.path.contains("/Library/LaunchAgents/") ? .standardLaunchAgent : .manualManaged
        let runAtLoad = object["RunAtLoad"] as? Bool
        guard let path = object["WorkingDirectory"] as? String, path.hasPrefix("/"),
              let args = object["ProgramArguments"] as? [String] else {
            let dir = fallbackDirectory ?? manifest.deletingLastPathComponent()
            return Candidate(
                directory: dir, manifest: manifest, label: label,
                controllerKind: .unsupported, runAtLoad: runAtLoad,
                unsupportedReason: "Manifest does not describe a GitHub runner service.",
                issues: ["Manifest does not describe a GitHub runner service."]
            )
        }
        let directory = URL(fileURLWithPath: path)
        let expected = [directory.appendingPathComponent("runsvc.sh").path]
        if args != expected {
            return Candidate(
                directory: directory, manifest: manifest, label: label,
                controllerKind: .unsupported, runAtLoad: runAtLoad,
                unsupportedReason: "Unknown supervisor: ProgramArguments do not launch this directory's runsvc.sh. No second process will be created.",
                issues: ["Unknown supervisor: ProgramArguments do not launch this directory's runsvc.sh."]
            )
        }
        if let user = object["UserName"] as? String, user != NSUserName() {
            return Candidate(
                directory: directory, manifest: manifest, label: label,
                controllerKind: .unsupported, runAtLoad: runAtLoad,
                unsupportedReason: "Service belongs to another user (\(user)).",
                issues: ["Service belongs to another user (\(user))."]
            )
        }
        let info = RunnerRegistrationReader.read(directory: directory)
        let runsvcExists = fm.fileExists(atPath: directory.appendingPathComponent("runsvc.sh").path)
        let binaryExists = fm.fileExists(atPath: directory.appendingPathComponent("run.sh").path)
        let noSpacePath = !directory.path.contains(" ")
        let work = info?.workFolder ?? ""
        let noSpaceWork = !work.contains(" ")
        var issues: [String] = []
        if info == nil { issues.append("Cannot read .runner registration.") }
        else {
            if (info?.agentName ?? "").isEmpty { issues.append("Registration name is missing.") }
            if info?.serverHost == nil || info?.scopeDetail == nil { issues.append("Server or scope is undefined.") }
            if work.isEmpty { issues.append("Work folder is missing.") }
        }
        if !runsvcExists { issues.append("runsvc.sh is missing.") }
        if !binaryExists { issues.append("run.sh is missing.") }
        if !noSpacePath { issues.append("Path contains a space; relocation is required.") }
        if !noSpaceWork { issues.append("Work folder contains a space.") }
        return Candidate(
            directory: directory, manifest: manifest, label: label,
            controllerKind: kind,
            agentName: info?.agentName, scope: info?.scopeDetail,
            serverHost: info?.serverHost, agentID: info?.agentID,
            workFolder: info?.workFolder, runAtLoad: runAtLoad,
            runsvcExists: runsvcExists, binaryExists: binaryExists,
            registrationReadable: info != nil, manifestMatches: true,
            noSpacePath: noSpacePath, noSpaceWork: noSpaceWork,
            issues: issues
        )
    }
}
