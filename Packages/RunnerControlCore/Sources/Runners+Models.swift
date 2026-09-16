import Foundation
extension Runners {
    public struct Definition: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let detail: String
        public let directory: URL
        public let githubURL: URL
        private let servicePlist: URL?
        public init(id: String, title: String, detail: String, directory: URL, githubURL: URL, servicePlist: URL? = nil) {
            self.id = id; self.title = title; self.detail = detail
            self.directory = directory; self.githubURL = githubURL; self.servicePlist = servicePlist
        }
        public var plist: URL { servicePlist ?? directory.appendingPathComponent("manual-service.plist") }
        public var logs: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/" + id) }
        public static func installed(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Self] {
            RunnerDiscovery.installed(home: home)
        }
    }
    public enum Status: String, Sendable, Equatable {
        case checking, stopped, running, failed, missing, unknown
        public var title: String {
            switch self {
            case .checking: "Проверяем…"
            case .stopped: "Выключен"
            case .running: "Служба включена"
            case .failed: "Ошибка службы"
            case .missing: "Раннер не найден"
            case .unknown: "Статус недоступен"
            }
        }
    }
    public struct Snapshot: Identifiable, Sendable, Equatable {
        public let definition: Definition
        public var status: Status
        public var message: String?
        public var id: String { definition.id }
        public init(definition: Definition, status: Status = .checking, message: String? = nil) {
            self.definition = definition; self.status = status; self.message = message
        }
    }
}
