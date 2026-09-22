# Embedded `runner-control` CLI — verification (2026-09-22)

Base: `fb85df5` + uncommitted CLI work. All observed this session.

- Core: 269/269 pass (incl. new
  `flowRestoreSessionWithUnreadableTokenKeepsIdentity`).
- CLI: 18/18 pass. Python (`Scripts/tests`): 97/97 pass.
- `./Scripts/build.sh`: dev app + embedded universal CLI build, Apple
  Development signed (team V8V53456PB both), re-sealed,
  `codesign --verify --deep --strict` clean.
- Shared session e2e (same-team dev): seeded GUI-shaped session (identity
  plist + Keychain token under a TESTCLIENT slot, real `gho_` bearer via
  pipe), dev CLI `auth status --json` → `connected:true`,
  `ivanopcode/98310998`, exit 0, no prompt; `runners list --json` read the
  shared catalog (2 running runners). Test slot removed precisely; the
  user's real token slot untouched.
- Restore fix: `restoreSession` no longer deletes the session identity
  when the token read returns nil (nil conflates missing with refused).
  Probes are now non-destructive; verified the orphaned real token +
  re-linked identity survive a denied cross-team read.
- Exit codes: needsLogin=3 with `{status:error}` envelope (identity
  removed → `auth installations --json` → 3, identity restored after);
  usage=1 (`app launch-at-login bogus`); install-cli to temp location OK.
- Parity: GUI-vs-CLI dispatched-effect diff reviewed manually. All
  persistent/user-goal effects covered; GUI-only effects are in-memory UI
  (`selectRunner`, `clearLog`, `dismissPermission`, repo-selection state,
  draft lifecycle) with CLI equivalents (flags incl. `--repos`-class
  options, `discover`→`add` two-step, re-run-as-retry). `list` is fresh
  (`loadCatalog` re-reads launchd snapshots). `check-updates` is
  intentionally read-only.
- Release path (static): `release.sh` builds the CLI with the same
  Developer ID identity (team 262RZ595FP), embeds under
  `Contents/Helpers`, re-seals, verifies, notarizes.

Open for reviewers: cross-surface write direction CLI→GUI (same code,
unit-tested, no live GUI relaunch observed); SIGINT-during-register token
hygiene (Keychain short-lived token, same leak profile as GUI kill);
any parity/effort gaps in `register` vs the wizard.

## Review integration (2026-09-22, astra/high + fable/high)

Both reviewers returned changes_requested; all blocking findings fixed,
each with a regression test that fails pre-fix (narrowing mutants):

- argv0 self-location (both): executable resolved from the process image
  (Bundle.main, dyld fallback); install refuses missing/non-executable
  targets. Blackbox: PATH lookup + direct symlink from a foreign cwd
  report the real binary; install/uninstall via PATH succeed; Swift:
  invalidTarget × 2, currentExecutableURL sanity.
- JSON/error envelope bypass (both): parse errors → usage(1) with native
  brief message (full usage on stderr for humans), run errors → failed(2),
  help/version native (exit 0). Blackbox: bogus subcommand ± --json,
  misplaced --json, bad feed (exit 2), --help/help/nested help. Swift:
  mapping unit tests × 2.
- installer-lock-fails-open (astra): fail-closed `installerUnavailable`,
  held lock for sync mutations, CLOEXEC, bounded EWOULDBLOCK spin for
  transient flakes. Swift: fail-closed on unopenable lock, explicit
  (non-silent) foreign-holder negative test.
- PATH-install lease (astra finding text, fable N1): fixed /tmp flock in
  CLIInstallerService with bounded retries; privileged root script keeps
  precondition re-checks (residual: concurrent privileged installs
  last-writer-win). Swift: refusal-while-held, concurrent-installs.
- shared-refresh-loser-erases-session (astra): compare-before-delete +
  single retry at all 7 restore cleanup sites. Swift: deterministic
  two-owner race test (loser adopts winner's session).
- login-item mechanism (fable): System Events removed; shared-defaults +
  distributed-notification bridge to the GUI's own SMAppService
  registration. Swift: 5 bridge state-machine tests. Live e2e (dev GUI
  instance, net-zero system state): request→pending→apply→clear→mirror,
  notify delivery, CLI status reads mirror. No prompts anywhere.
- Notes: group-access explicit-empty clears (was show-only); `remove --json`
  carries the warning note; app payloads use real JSON booleans; Keychain
  sharing comment corrected to the established same-team rule; lease test
  skips made loud.

Constraint → driving-test map (proposal §Constraints):
1. JSON/exit contract → CLITests mapping × 2 + blackbox ErrorEnvelope (6).
2. No-prompt session sharing → e2e above + restore regression tests × 2.
3. Parity by construction → effect diff (manual) + blackbox contract tests.
4. Fail-closed leases → lease tests × 4 + PATH lease tests × 2.
5. launch-at-login bridge → bridge tests × 5 + live e2e + status blackbox.

Residuals (documented, accepted): privileged-script PATH race;
register retry = re-run (idempotent markers); SIGINT-during-register
short-lived token (same as GUI kill); legacy System Events login item for
/Applications/RunnerControl.app predates the bridge (user can remove it in
System Settings; the CLI no longer manages it).
Final suites: Core 282, CLI 20, Python 112 — all green. (PATH-lease
test isolation: injected lock paths per test + one fixed-path
default-routing test, after a shared-lock budget race flaked.)
