import Foundation

/// Controller capabilities for one definition. Managed kinds use launchctl;
/// unsupported entries are read-only.
public enum RunnerControllers {
    /// Refuses control of unsupported entries with an explicit reason.
    /// Never creates a second process and never fakes a toggle.
    public static func requireControllable(_ definition: Runners.Definition) throws {
        if definition.controllerKind == .unsupported {
            throw RunnerError.unsupported(
                "Runner «\(definition.displayTitle)» uses unsupported management. Control it with its own supervisor instead of Runner Control."
            )
        }
    }

    /// Re-validates configuration immediately before a start. Start is
    /// blocked on any mismatch; stop stays possible when registration or
    /// manifest is damaged (the service identity alone is enough to bootout).
    /// Import-time checks (binaries, server/scope) live in discovery
    /// candidates so existing fixtures and running services are not broken
    /// by stricter start gates.
    public static func validateForStart(_ definition: Runners.Definition) throws {
        try requireControllable(definition)
        try validateManifestMatches(definition)
        try validateNoSpace(definition)
        try validateWorkFolder(definition)
    }

    public static func validateManifestMatches(_ definition: Runners.Definition) throws {
        let data: Data
        do {
            data = try Data(contentsOf: definition.plist)
        } catch {
            throw RunnerError.manifestMismatch("Service manifest is missing for «\(definition.displayTitle)».")
        }
        // Paths compare by canonical identity: the stored path and the
        // bookmark-resolved directory can differ in spelling (/var vs
        // /private/var) while naming the same installation.
        let wantDirectory = RunnerCatalogStore.canonical(definition.directory)
        let wantRunsvc = URL(fileURLWithPath: wantDirectory).appendingPathComponent("runsvc.sh").path
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == definition.id,
              let args = plist["ProgramArguments"] as? [String], args.count == 1,
              RunnerCatalogStore.canonical(URL(fileURLWithPath: args[0])) == wantRunsvc,
              let working = plist["WorkingDirectory"] as? String,
              RunnerCatalogStore.canonical(URL(fileURLWithPath: working)) == wantDirectory else {
            throw RunnerError.manifestMismatch("Настройки службы не соответствуют раннеру \(definition.title).")
        }
    }

    public static func validateNoSpace(_ definition: Runners.Definition) throws {
        if definition.directory.path.contains(" ") {
            throw RunnerError.noSpacePath("Путь раннера содержит пробел. Исправьте путь перед запуском.")
        }
        let registration = try? Data(contentsOf: definition.directory.appendingPathComponent(".runner"))
        if let registration,
           let object = try? JSONSerialization.jsonObject(with: registration) as? [String: Any],
           let work = object["workFolder"] as? String, work.contains(" ") {
            throw RunnerError.noSpacePath("Рабочий каталог раннера отсутствует или содержит пробел.")
        }
    }

    public static func validateWorkFolder(_ definition: Runners.Definition) throws {
        let url = definition.directory.appendingPathComponent(".runner")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let work = object["workFolder"] as? String, !work.isEmpty, !work.contains(" ") else {
            throw RunnerError.message("Рабочий каталог раннера отсутствует или содержит пробел.")
        }
    }

    /// Import-time registration check: name and server/scope must be defined.
    /// Used by discovery candidates, not by the start gate.
    public static func validateRegistration(_ definition: Runners.Definition) throws {
        try validateWorkFolder(definition)
        // Server/scope must be defined; the label format is never trusted.
        let info = RunnerRegistrationReader.read(directory: definition.directory)
        if (info?.agentName ?? "").isEmpty {
            throw RunnerError.message("Registration name is missing for «\(definition.displayTitle)».")
        }
        if info?.serverHost == nil || info?.scopeDetail == nil {
            throw RunnerError.message("Server or scope is undefined for «\(definition.displayTitle)».")
        }
    }

    public static func validateBinaries(_ definition: Runners.Definition) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: definition.directory.appendingPathComponent("runsvc.sh").path) {
            throw RunnerError.message("runsvc.sh is missing for «\(definition.displayTitle)». Reinstall before starting.")
        }
        if !fm.fileExists(atPath: definition.directory.appendingPathComponent("run.sh").path) {
            throw RunnerError.message("run.sh is missing for «\(definition.displayTitle)». Reinstall before starting.")
        }
    }

    // MARK: - Effective login-start

    /// Login registration path for a label. Only plists in this directory
    /// are loaded by launchd at login.
    public static func loginRegistrationURL(label: String, home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// True when a plist dictionary describes this definition's service
    /// (same label, same directory, same runsvc entry point). Paths compare
    /// by canonical identity so bookmark-resolved spellings still match.
    public static func references(_ plist: [String: Any], definition: Runners.Definition) -> Bool {
        guard plist["Label"] as? String == definition.id,
              let working = plist["WorkingDirectory"] as? String,
              let args = plist["ProgramArguments"] as? [String], args.count == 1 else {
            return false
        }
        let wantDirectory = RunnerCatalogStore.canonical(definition.directory)
        let wantRunsvc = URL(fileURLWithPath: wantDirectory).appendingPathComponent("runsvc.sh").path
        return RunnerCatalogStore.canonical(URL(fileURLWithPath: working)) == wantDirectory
            && RunnerCatalogStore.canonical(URL(fileURLWithPath: args[0])) == wantRunsvc
    }

    /// Effective login-start for one definition. Standard manifests use
    /// their own RunAtLoad. External manual plists are ON only when a
    /// matching registration exists in `~/Library/LaunchAgents` with
    /// RunAtLoad true: RunAtLoad outside LaunchAgents controls bootstrap
    /// startup only, never login persistence. Nil for unsupported control
    /// or an unreadable standard manifest.
    public static func effectiveLogin(_ definition: Runners.Definition, home: URL) -> Bool? {
        if definition.controllerKind == .unsupported { return nil }
        if definition.controllerKind == .standardLaunchAgent {
            guard let data = try? Data(contentsOf: definition.plist),
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return nil
            }
            return object["RunAtLoad"] as? Bool
        }
        let copy = loginRegistrationURL(label: definition.id, home: home)
        guard let data = try? Data(contentsOf: copy),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              references(object, definition: definition) else {
            return false
        }
        return (object["RunAtLoad"] as? Bool) ?? false
    }
}
