# Runner registration (in scope for this release)

Promoted from §2 "next stage" into this release. Implemented by
TASK-260916-13diw4; this slice provides login + installation/repo selection
that the wizard consumes.

## Scope

- Wizard downloads the architecture-matched official runner, verifies
  integrity, installs to a no-space path, obtains a scoped short-lived
  registration token, runs exact `config.sh` invocation, sets up
  `runsvc.sh` + manual LaunchAgent, retries idempotently with recovery.
- Org registration uses a dedicated per-Mac group + selected repo access;
  personal repos get separate installations. Repo access and labels remain
  editable; real IDs are fetched; permission errors are retained.
- Never mutates unrelated/shared groups without explicit UI scope.

## Preconditions (this slice)

- `GitHubAuth` connected with installations + selected repos.
- Required elevation (later): Self-hosted runners/write (org) or
  Administration/write (repo) + matching user rights. Absence blocks the
  wizard step with the concrete missing permission, not a generic error.

## Safety

- No auto-transfer of a running runner; relocation is a separate stopped
  operation with restore.
- No second controlling process; validate manifest + `.runner` + binaries +
  no-space paths immediately before action.
- Registration tokens are short-lived, Keychain-only, never logged.
