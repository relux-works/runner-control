# Validation

- Core: 10 Swift Testing tests passed, including parameterized cases and real temporary launchd service start/stop.
- No UI test target or XCUITest run.
- Native panel manually inspected: Relux Works enabled; CocoaSkills disabled; two independent switches, shared controls, logs and GitHub links visible.
- macOS build succeeded with bundle ID `works.relux.runnercontrol` and Apple Development team `262RZ595FP`; signature verified with codesign.
- Full `ios-app-manager` Go suite passed after adding native scaffold; focused scaffold tests passed after target signing refinement.
- Registration path: `/Users/iv/Library/GitHubActions/macbook-iv/_work`; no spaced Application Support path in `.runner`, `.env`, `.path` or service manifest.
- Existing GitHub job https://github.com/relux-works/skill-project-management/actions/runs/35028909296/job/104582517367 passed `actions/setup-go@v5`. Its remaining test suite was still in progress during validation.

## Upstream changes landed

- https://github.com/relux-works/skill-ios-app-manager/commit/71a3fff
- https://github.com/relux-works/skill-ios-app-manager/commit/b2aee6c
- https://github.com/relux-works/skill-swift-relux/commit/cafaa85
- https://github.com/relux-works/skill-ios-testing-tools/commit/171258a
