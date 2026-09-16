import Foundation
import Testing
@testable import RunnerControlCore

@Test func discoversManualAndStandardServicesWithoutMachineNames() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let fm = FileManager.default
    let agents = home.appendingPathComponent("Library/LaunchAgents")
    try fm.createDirectory(at: agents, withIntermediateDirectories: true)
    func install(_ folder: URL, _ manifest: URL, _ label: String, _ scope: String) throws {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let config: [String: Any] = ["agentName": "any-mac", "gitHubUrl": "https://github.com/" + scope, "workFolder": "_work"]
        var registration = Data([0xef, 0xbb, 0xbf])
        registration.append(try JSONSerialization.data(withJSONObject: config))
        try registration.write(to: folder.appendingPathComponent(".runner"))
        let plist: [String: Any] = ["Label": label, "WorkingDirectory": folder.path, "ProgramArguments": [folder.appendingPathComponent("runsvc.sh").path]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: manifest)
    }
    let manual = home.appendingPathComponent("Library/GitHubActions/manual")
    try install(manual, manual.appendingPathComponent("manual-service.plist"), "actions.runner.example.manual", "example/project")
    let other = home.appendingPathComponent("custom-install")
    let service = agents.appendingPathComponent("actions.runner.example.other.plist")
    try install(other, service, "actions.runner.example.other", "example")
    // Duplicate manifest must not create another controllable row.
    try install(manual, agents.appendingPathComponent("actions.runner.example.manual.plist"), "actions.runner.example.manual", "example/project")
    let found = RunnerDiscovery.installed(home: home)
    #expect(found.count == 2)
    #expect(Set(found.map(\.title)) == ["any-mac"])
    #expect(found.first { $0.directory.path == other.path }?.plist.resolvingSymlinksInPath() == service.resolvingSymlinksInPath())
    #expect(found.first { $0.directory.path == other.path }?.githubURL.absoluteString == "https://github.com/organizations/example/settings/actions/runners")
    #expect(found.first { $0.directory.path == manual.path }?.githubURL.absoluteString == "https://github.com/example/project/settings/actions/runners")
    try Data("invalid".utf8).write(to: service)
    #expect(RunnerDiscovery.installed(home: home).count == 1)
}

@Test func missingDiscoveryRootsReturnEmpty() {
    #expect(RunnerDiscovery.installed(home: URL(fileURLWithPath: "/nonexistent-" + UUID().uuidString)).isEmpty)
}
