# Embedded `runner-control` CLI — decomposition

Work is implemented on top of `fb85df5` (v1.2.0, uncommitted):

- `Packages/RunnerControlCLI/` (new): ArgumentParser driver, `auth`,
  `runners`, `register`, `app` commands, JSON envelope, headless Relux boot.
- `Packages/RunnerControlCore/Sources/CLIInstallerService.swift` (new):
  shared PATH-install service used by GUI button and CLI, with its own
  fixed-path flock lease (serializes same-user GUI/CLI installs) and
  missing/non-executable target refusal. (The installer-wide flock for
  runner mutations lives in `RunnerInstallerService`, not here.)
- `Packages/RunnerControlCore/Sources/LoginItemBridge.swift` (new):
  launch-at-login shared-defaults + notification contract (Core); the GUI
  target owns the SMAppService apply/mirror, the CLI owns request/poll.
- Core diffs: `GitHubAuth+Flow.swift` (restore must not delete identity on
  unreadable token; destructive cleanup only when the dead record is still
  current, else one retry against the fresh record), `GitHubKeychainStore.swift`
  (sharing-rule comment), `RunnerInstallerService.swift` (fail-closed lease,
  CLOEXEC, transient-tolerant acquisition, held lock for sync mutations),
  `RunnerRuntime.swift` (injected identities/configProvider).
- `Targets/RunnerControl`: `CLIInstallModel.swift` + Install CLI UI wiring.
- `Scripts/build-cli.sh`, `Scripts/resolve-identity.sh` (new);
  `build.sh`/`release.sh` embed + re-seal; `test_cli_parity.py` (new).

Board:

- EPIC `embedded-cli-companion`
  - STORY `cli-parity-and-shared-session`
    - TASK `verify-cli-parity-and-session` (implementer, done inline with
      evidence in `verification.md`)
    - TASK `review-cli-parity-astra` (reviewer, codex/gpt-6-astra/high)
    - TASK `review-cli-parity-fable` (reviewer, claude/claude-fable-5-1/high)
    - TASK `integrate-review-verdicts` (implementer, after both reviews)
    - TASK `release-cli-companion` (implementer, final checks + release)
