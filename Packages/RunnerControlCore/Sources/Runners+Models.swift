import Foundation
extension Runners {
    public struct Definition: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let detail: String
        public let directory: URL
        public let githubURL: URL
        public init(id: String, title: String, detail: String, directory: URL, githubURL: URL) {
            self.id = id; self.title = title; self.detail = detail
            self.directory = directory; self.githubURL = githubURL
        }
        public var plist: URL { directory.appendingPathComponent("manual-service.plist") }
        public var logs: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/" + id) }
        public static func installed(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Self] {
            let root = home.appendingPathComponent("Library/GitHubActions")
            return [
                .init(id: "actions.runner.relux-works.macbook-iv", title: "Relux Works", detail: "curator · launcher · spec · project-management", directory: root.appendingPathComponent("macbook-iv"), githubURL: URL(string: "https://github.com/organizations/relux-works/settings/actions/runners")!),
                .init(id: "actions.runner.ivanopcode-cocoaskills.macbook-iv", title: "CocoaSkills", detail: "ivanopcode / cocoaskills", directory: root.appendingPathComponent("cocoaskills"), githubURL: URL(string: "https://github.com/ivanopcode/cocoaskills/settings/actions/runners")!)
            ]
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
