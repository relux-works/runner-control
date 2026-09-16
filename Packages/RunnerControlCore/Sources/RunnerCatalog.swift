import CryptoKit
import Foundation

extension Runners {
    /// How a catalog entry is controlled. Managed kinds use launchctl;
    /// unsupported entries are read-only (no fake toggle, no second process).
    public enum ControllerKind: String, Sendable, Equatable, Codable {
        case manualManaged
        case standardLaunchAgent
        case unsupported

        public var title: String {
            switch self {
            case .manualManaged: "Ручная служба"
            case .standardLaunchAgent: "LaunchAgent"
            case .unsupported: "Неподдерживаемое управление"
            }
        }

        public var canControl: Bool { self != .unsupported }
    }
}

/// Versioned persistent catalog of user-managed runner installations.
///
/// Stored as JSON in Application Support/RunnerControl/catalog.json. Holds
/// identity, paths, display overrides, controller kind and preferences.
/// Never holds secrets, tokens, or credentials.
public actor RunnerCatalogStore {
    public static let currentVersion = 1
    public static let fileName = "catalog.json"

    public struct Entry: Sendable, Equatable, Codable, Identifiable {
        public var localID: String
        public var directoryPath: String
        public var canonicalPath: String
        public var bookmarkBase64: String?
        public var displayName: String?
        public var serviceLabel: String
        public var servicePlistPath: String
        public var controllerKind: Runners.ControllerKind
        public var runAtLoad: Bool?
        public var serverHost: String?
        public var scopeKind: String?
        public var scope: String?
        public var remoteAgentID: Int64?
        public var agentName: String?
        public var workFolder: String?
        public var addedAt: Date
        public var lastSeenAt: Date?

        public var id: String { localID }

        public init(
            localID: String = UUID().uuidString,
            directoryPath: String,
            canonicalPath: String,
            bookmarkBase64: String? = nil,
            displayName: String? = nil,
            serviceLabel: String,
            servicePlistPath: String,
            controllerKind: Runners.ControllerKind,
            runAtLoad: Bool? = nil,
            serverHost: String? = nil,
            scopeKind: String? = nil,
            scope: String? = nil,
            remoteAgentID: Int64? = nil,
            agentName: String? = nil,
            workFolder: String? = nil,
            addedAt: Date = Date(),
            lastSeenAt: Date? = nil
        ) {
            self.localID = localID
            self.directoryPath = directoryPath
            self.canonicalPath = canonicalPath
            self.bookmarkBase64 = bookmarkBase64
            self.displayName = displayName
            self.serviceLabel = serviceLabel
            self.servicePlistPath = servicePlistPath
            self.controllerKind = controllerKind
            self.runAtLoad = runAtLoad
            self.serverHost = serverHost
            self.scopeKind = scopeKind
            self.scope = scope
            self.remoteAgentID = remoteAgentID
            self.agentName = agentName
            self.workFolder = workFolder
            self.addedAt = addedAt
            self.lastSeenAt = lastSeenAt
        }
    }

    struct File: Codable, Sendable, Equatable {
        var version: Int
        var entries: [Entry]
        /// True once one-time migration has run or any explicit user mutation
        /// sealed the catalog. An initialized-but-empty catalog is
        /// authoritative and never re-triggers migration. Legacy files without
        /// this key decode as false and are sealed on the next migration pass.
        var migrated: Bool

        enum CodingKeys: String, CodingKey {
            case version, entries, migrated
        }

        init(version: Int, entries: [Entry], migrated: Bool) {
            self.version = version
            self.entries = entries
            self.migrated = migrated
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            entries = try container.decode([Entry].self, forKey: .entries)
            migrated = try container.decodeIfPresent(Bool.self, forKey: .migrated) ?? false
        }
    }

    public enum CatalogError: LocalizedError, Sendable, Equatable {
        case duplicateDirectory(path: String)
        case duplicateLabel(label: String)
        case unknownEntry(id: String)
        case persistenceUnreadable(reason: String)
        case unsupportedVersion(found: Int)

        public var errorDescription: String? {
            switch self {
            case .duplicateDirectory(let path):
                "Runner directory is already in the catalog: \(path). One directory cannot be imported twice."
            case .duplicateLabel(let label):
                "Service '\(label)' is already in the catalog. Two entries must never share one control identity."
            case .unknownEntry(let id):
                "Unknown catalog entry: \(id)."
            case .persistenceUnreadable(let reason):
                reason
            case .unsupportedVersion(let found):
                "Catalog version \(found) is not supported by this app (expected \(RunnerCatalogStore.currentVersion)). Refusing to migrate or overwrite it."
            }
        }
    }

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = base.appendingPathComponent("RunnerControl/\(Self.fileName)")
        }
    }

    public nonisolated var url: URL { fileURL }

    /// Canonical directory identity. Symlink spellings collapse to one key,
    /// so the same installation cannot be imported twice via an alias path.
    public nonisolated static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Collision-safe service label for manifest-free folder imports. The
    /// agent name keeps the label readable; the canonical-path hash keeps it
    /// unique and persistent: two folders with the same agent name on
    /// different scopes or paths never share one control identity, and the
    /// same directory always maps to the same label.
    public nonisolated static func importedServiceLabel(agentName: String?, directory: URL) -> String {
        let raw = (agentName ?? directory.lastPathComponent)
            .lowercased().replacingOccurrences(of: " ", with: "-")
        let base = raw.isEmpty ? "runner" : raw
        let digest = SHA256.hash(data: Data(canonical(directory).utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "actions.runner.imported.\(base)-\(suffix)"
    }

    /// Checked file read. A missing file is first-run absence (nil). A present
    /// but unreadable or malformed file, or a version mismatch, fails closed
    /// instead of masquerading as an empty catalog.
    private func existingFile() throws -> File? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw CatalogError.persistenceUnreadable(reason: "Cannot read the catalog file at \(fileURL.path). Refusing to treat a read failure as an empty catalog.")
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            throw CatalogError.persistenceUnreadable(reason: "The catalog file at \(fileURL.path) is malformed. Refusing to migrate or overwrite it.")
        }
        guard file.version == Self.currentVersion else {
            throw CatalogError.unsupportedVersion(found: file.version)
        }
        return file
    }

    /// Fail-soft display read: missing, malformed or version-mismatched
    /// persistence all surface as an empty list for snapshots and discovery.
    /// Mutations (`add`/`remove`/`update`) and `migrateIfNeeded` use checked
    /// reads and fail closed instead of clobbering or re-seeding.
    public func load() -> [Entry] {
        guard let file = try? existingFile() else { return [] }
        return file.entries
    }

    /// Checked entries for mutations. Missing file starts from empty; a
    /// corrupt or unsupported store throws instead of being overwritten.
    private func checkedEntriesForMutation() throws -> [Entry] {
        try existingFile()?.entries ?? []
    }

    /// Persists entries and seals the catalog as user-authoritative: an
    /// explicit save (including an explicit emptying) never re-triggers
    /// migration.
    public func save(_ entries: [Entry]) throws {
        try write(entries: entries, migrated: true)
    }

    private func write(entries: [Entry], migrated: Bool) throws {
        let file = File(version: Self.currentVersion, entries: entries, migrated: migrated)
        let data = try JSONEncoder().encode(file)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Adds an entry. Refuses a second entry for the same canonical directory,
    /// including symlink spellings, and refuses a second entry sharing one
    /// service label: two entries must never share one control identity. Two
    /// identical agent names on different scopes stay two entries with two
    /// distinct labels.
    public func add(_ entry: Entry) throws {
        var entries = try checkedEntriesForMutation()
        let want = entry.canonicalPath
        if entries.contains(where: { $0.canonicalPath == want }) {
            throw CatalogError.duplicateDirectory(path: entry.directoryPath)
        }
        if entries.contains(where: { $0.serviceLabel == entry.serviceLabel }) {
            throw CatalogError.duplicateLabel(label: entry.serviceLabel)
        }
        entries.append(entry)
        try save(entries)
    }

    /// Removes only the catalog record. Deletes no files, no GitHub
    /// registration, no certificates, and never stops a running service.
    /// Returns the removed entry so the caller can warn when the service
    /// keeps running. An emptied catalog stays empty: removal seals the
    /// catalog and `migrateIfNeeded` never resurrects removed entries.
    @discardableResult
    public func remove(localID: String) throws -> Entry {
        var entries = try checkedEntriesForMutation()
        guard let index = entries.firstIndex(where: { $0.localID == localID }) else {
            throw CatalogError.unknownEntry(id: localID)
        }
        let removed = entries.remove(at: index)
        try save(entries)
        return removed
    }

    public func update(_ entry: Entry) throws {
        var entries = try checkedEntriesForMutation()
        guard let index = entries.firstIndex(where: { $0.localID == entry.localID }) else {
            throw CatalogError.unknownEntry(id: entry.localID)
        }
        // Directory moves must not collide with another entry's canonical path.
        if entries.enumerated().contains(where: { $0.offset != index && $0.element.canonicalPath == entry.canonicalPath }) {
            throw CatalogError.duplicateDirectory(path: entry.directoryPath)
        }
        // Labels must never collide either: one label is one control identity.
        if entries.enumerated().contains(where: { $0.offset != index && $0.element.serviceLabel == entry.serviceLabel }) {
            throw CatalogError.duplicateLabel(label: entry.serviceLabel)
        }
        entries[index] = entry
        try save(entries)
    }

    /// One-time migration: when the catalog was never initialized, import
    /// every discovered installation with its real directory, scope, label
    /// and preserved RunAtLoad policy, then seal the catalog — including an
    /// empty result. An initialized catalog (even an explicitly emptied one)
    /// is authoritative and is returned untouched; removing the last entry
    /// never resurrects it at restart. A malformed, unreadable or
    /// unsupported store fails closed instead of migrating. Never stops,
    /// renames, re-registers or changes autostart; discovery only reads.
    /// Returns the migrated or stored entries.
    public func migrateIfNeeded(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [Entry] {
        if let file = try existingFile() {
            if file.migrated || !file.entries.isEmpty {
                if !file.migrated {
                    // Legacy initialized store: seal without touching entries.
                    try write(entries: file.entries, migrated: true)
                }
                return file.entries
            }
            // Empty and never migrated: one-time import, then seal.
            let entries = collectMigrationEntries(home: home)
            try write(entries: entries, migrated: true)
            return entries
        }
        // First run: no catalog file yet.
        let entries = collectMigrationEntries(home: home)
        try write(entries: entries, migrated: true)
        return entries
    }

    private func collectMigrationEntries(home: URL) -> [Entry] {
        let definitions = RunnerDiscovery.installed(home: home)
        var entries: [Entry] = []
        for definition in definitions {
            let url = definition.directory
            let canonical = Self.canonical(url)
            if entries.contains(where: { $0.canonicalPath == canonical }) { continue }
            if entries.contains(where: { $0.serviceLabel == definition.id }) { continue }
            let info = RunnerRegistrationReader.read(directory: url)
            let runAtLoad = Self.readRunAtLoad(plist: definition.plist)
            let kind: Runners.ControllerKind = definition.plist.path.contains("/Library/LaunchAgents/")
                ? .standardLaunchAgent : .manualManaged
            let entry = Entry(
                directoryPath: url.path,
                canonicalPath: canonical,
                bookmarkBase64: Self.bookmark(for: url),
                serviceLabel: definition.id,
                servicePlistPath: definition.plist.path,
                controllerKind: kind,
                runAtLoad: runAtLoad,
                serverHost: info?.serverHost,
                scopeKind: info?.scopeKind,
                scope: info?.scopeDetail,
                remoteAgentID: info?.agentID,
                agentName: info?.agentName,
                workFolder: info?.workFolder
            )
            entries.append(entry)
        }
        return entries
    }

    nonisolated static func readRunAtLoad(plist: URL) -> Bool? {
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return object["RunAtLoad"] as? Bool
    }

    nonisolated static func bookmark(for url: URL) -> String? {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        return data.base64EncodedString()
    }

    /// Resolves the stored bookmark, falling back to the recorded path when
    /// no bookmark exists or resolution fails. Never synthesizes a different
    /// directory.
    nonisolated public static func resolve(entry: Entry) -> URL {
        if let base64 = entry.bookmarkBase64,
           let data = Data(base64Encoded: base64) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return URL(fileURLWithPath: entry.directoryPath)
    }
}
