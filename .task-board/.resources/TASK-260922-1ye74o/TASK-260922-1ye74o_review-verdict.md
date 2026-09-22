# TASK-260922-1ye74o — independent review verdict (fable)

Run: RUN-260922-85b26f · 2026-09-22 · reviewer: claude-fable-5-1
Candidate: uncommitted working tree vs fb85df5 (tracked diff 11 files + 7 new files under Packages/RunnerControlCLI, CLIInstallerService.swift, CLICompanionTests.swift, build-cli.sh, resolve-identity.sh, test_cli_parity.py, CLIInstallModel.swift).
Attacked artifact: .temp/products/RunnerControl.app/Contents/Helpers/runner-control (built 21:56, newer than every CLI/Core source; Apple Development V8V53456PB, x86_64+arm64).
Astra verdict NOT read (independent judgement, per task description).

## VERDICT: changes_requested → to-dev

Three blocking findings reproduced against the built candidate; one design-level parity finding whose reproduction was specified but not executed under the review guardrails. Everything else swept held. Reasons in the findings array below.

## Reran myself (not accepted from attached evidence)
- Core: `swift test --package-path Packages/RunnerControlCore` → 269 tests passed (3.6 s).
- CLI: `swift test --package-path Packages/RunnerControlCLI` → 18 tests passed.
- Python: `python3 -m unittest discover -s Scripts/tests` → 97 tests OK (125 s).
- Signing: `codesign --verify --deep --strict .temp/products/RunnerControl.app` OK; app and embedded CLI both TeamIdentifier=V8V53456PB (one identity, as build.sh intends); `lipo -archs` → x86_64 arm64; app entitlements empty (installed 1.2.0 release also has an empty entitlements dict, so the no-`--entitlements` re-seal in release.sh:42 drops nothing).
- Not run: release.sh end-to-end (needs Developer ID + notary creds); accepted only as static read + the stubbed harness `test_release_embeds_signed_cli` which I reran.
- Not run (guardrails): any command that boots HeadlessRuntime.restore() against the real identity. The dev CLI is team V8V53456PB while /Applications/RunnerControl.app is Developer ID 262RZ595FP, so a restore would be a cross-team Keychain read of the user's real token (prompt or denial). No sign-out, runner, Keychain or plist mutation was performed.

## Surface table (constructed from the DoD; brief carried no table)

| row | surface | result |
|---|---|---|
| R1 | GUI-effect parity, command by command | broken — F-login-item-mechanism (all Relux effects held, see matrix) |
| R2 | Shared session + Keychain safety (restore fix, identity store, token store) | held (with unknown N2) |
| R3 | JSON envelope + exit-code contract for harnesses | broken — F-error-envelope-bypass |
| R4 | Installer lease (flock) GUI↔CLI | held (notes N1, N3, N4) |
| R5 | Signing / embedding / re-seal (build.sh, release.sh, build-cli.sh) | held (dev artifact verified; release path static only) |
| R6 | CLI self-install / uninstall via PATH symlink | broken — F-argv0-self-location |
| R7 | Tests green (three suites) | held |

### R1 parity matrix (GUI dispatch sites vs CLI dispatch sites, grep of `*.Effect.*`)
GUI-only effects and their CLI equivalent: `selectRepositories` → pure state (GitHubAuth+Flow.swift:63), consumed by `register --repo-id`; `importCandidate` → `runners add` uses `importFolder`, which validates then calls `importCandidate` (Runners+Flow.swift:297-309); `refresh` → CLI uses `loadCatalog`, a superset (migrate + fresh snapshots, Runners+Flow.swift:204-214); `setEnabled` → `setEnabledMany` (same service call per id); `selectRunner`, `clearLog`, `updateDraft`, `cancel`, `reset`, `retry`, `dismissPermission` → in-memory UI state / re-run-as-retry. CLI `register` drives beginDraft→resolveGroup→prepareDownload→downloadAndInstall→registerRunner→setupService→applyRepositoryAccess→applyLabels; the GUI omits an explicit `prepareDownload` because `downloadAndInstall` performs it when `asset == nil` (RunnerRegistration+Flow.swift:503-510), so the CLI's explicit step is a harmless superset. `Relux.action{}` awaits the flow's `apply` (Relux+Dispatcher+Interface.swift:114-130), so every CLI read of state after `await action` sees settled state. Non-Relux GUI settings: Sparkle keys `SUEnableAutomaticChecks`/`SUAutomaticallyUpdate` written to the same defaults domain the GUI's SPUUpdater persists to (held); launch-at-login → broken (F-login-item-mechanism).

## findings (blocking, bypass first)

```json
[
  {
    "id": "argv0-self-location",
    "row": "R6",
    "invariant": "install-cli/uninstall-cli/app version/hostAppURL must locate the running binary regardless of how it was invoked; the PATH symlink is the intended way to invoke it.",
    "mechanism": "CLIInstallerService.currentExecutableURL() (Packages/RunnerControlCore/Sources/CLIInstallerService.swift:70-72) and CLIConfig.hostAppURL/clientID/appVersion/configProvider (Packages/RunnerControlCLI/Sources/CLIConfig.swift:39,48,53,60,82) derive the executable from CommandLine.arguments[0]. When the command is found via PATH (or via sudo), argv[0] is the bare name 'runner-control', so URL(fileURLWithPath:) resolves to $CWD/runner-control, a non-existent file. install() then classifies the real link as installedOther and replaces it (CLIInstallerService.swift:99-124).",
    "reproductions": [
      {
        "command": "ln -s <app>/Contents/Helpers/runner-control /tmp/rc/bin/runner-control; cd /tmp/rc/cwd; PATH=/tmp/rc/bin:/usr/bin:/bin runner-control app version --json",
        "expected_failure": "data.cli = /private/tmp/rc/cwd/runner-control, data.app = 'unknown (standalone CLI copy)', data.bundle = '—' (absolute-path invocation reports the real bundle and 1.2.0 (101.99)).",
        "observed": "reproduced (A5 vs A4)"
      },
      {
        "command": "cd /tmp/rc/cwd; PATH=/tmp/rc/bin:/usr/bin:/bin runner-control app install-cli --location /tmp/rc/link/runner-control --json; readlink /tmp/rc/link/runner-control; test -e /tmp/rc/link/runner-control",
        "expected_failure": "status ok, target=/private/tmp/rc/cwd/runner-control; the created symlink is DANGLING. With the default location this replaces a working /usr/local/bin link (e.g. after a GUI install, `sudo runner-control app install-cli`, which the CLI's own needsAdmin message recommends) with a broken one.",
        "observed": "reproduced (A6)"
      },
      {
        "command": "ln -sfn <app>/Contents/Helpers/runner-control /tmp/rc/link/runner-control; cd /tmp/rc/cwd; PATH=/tmp/rc/bin:/usr/bin:/bin runner-control app uninstall-cli --location /tmp/rc/link/runner-control --json",
        "expected_failure": "exit 2, 'Refusing to remove …: it points at <real binary>' — a correct link cannot be removed by the PATH-invoked CLI.",
        "observed": "reproduced (A7)"
      }
    ],
    "severity": "bypass",
    "repeat-of": "none",
    "fix_hint": "Resolve the executable via Bundle.main.executableURL (or _NSGetExecutablePath) and route every CLIConfig default through it; add a regression test that execs the built binary through a PATH symlink from an unrelated cwd and asserts data.cli/target equal the real binary path (the CLITests hostAppURL test only exercises a literal absolute path)."
  },
  {
    "id": "error-envelope-bypass",
    "row": "R3",
    "invariant": "Contract in DTOs.swift:4-13 and :25-26 — exit codes 0/1/2/3 (1 = usage) and 'every --json invocation prints exactly one doc'.",
    "mechanism": "CLIEntry.handle (Packages/RunnerControlCLI/Sources/CLIEntry.swift:42-51) envelopes only CLIFailure. Every other error falls to RunnerControl.exit(withError:): ArgumentParser parse/validation errors exit EX_USAGE=64 (swift-argument-parser MessageInfo.swift:176, Platform.swift:80) and any runtime error thrown by Foundation/Core (e.g. URLError from URLSession in AppCommands.swift:50) exits 1 — the documented usage code — with no JSON document on stdout in either case.",
    "reproductions": [
      {
        "command": "runner-control runners bogus --json; echo $?",
        "expected_failure": "exit 64, empty stdout, usage text on stderr (contract: 1 + {status:error}).",
        "observed": "reproduced (A1); same for `runner-control --json runners list` (A2)"
      },
      {
        "command": "copy the binary under /tmp/Fake/RunnerControl.app/Contents/Helpers/ with an Info.plist whose SUFeedURL=https://127.0.0.1:1/appcast.xml; run `runner-control app check-updates --json`; echo $?",
        "expected_failure": "exit 1 (usage code) and empty stdout; stderr 'Error: Could not connect to the server.' A harness cannot distinguish a network failure from a usage error and gets no envelope.",
        "observed": "reproduced (B1)"
      }
    ],
    "severity": "robustness",
    "repeat-of": "none",
    "fix_hint": "In handle(): map CommandError/ValidationError to CLIExit.usage (print the JSON error doc when --json is present) and every other error to CLIExit.failed with an envelope; add negative tests for both shapes (unknown subcommand with --json; a thrown non-CLIFailure error with --json) asserting exit code and single JSON doc."
  },
  {
    "id": "login-item-mechanism",
    "row": "R1",
    "invariant": "`app launch-at-login on|off|status` must read and write the same persisted setting as the GUI toggle (1:1 parity) without interactive prompts.",
    "mechanism": "GUI: LaunchAtLoginModel (Targets/RunnerControl/Sources/LaunchAtLoginModel.swift:9-17) uses SMAppService.mainApp register/unregister/status. CLI: AppSettings.loginItemEnabled/setLoginItem (Packages/RunnerControlCLI/Sources/AppCommands.swift:306-330) drive System Events 'login items' via osascript, i.e. the legacy LSSharedFileList mechanism. These are two distinct registrations: SMAppService.mainApp.status never reflects a System Events login item and System Events never lists an SMAppService registration, so CLI `status` disagrees with the GUI toggle and CLI `on` creates a second, different login item. Additionally, osascript→System Events requires an Automation (TCC) consent dialog for the calling terminal/harness app, which contradicts the no-prompt constraint in proposal.md.",
    "reproductions": [
      {
        "command": "In the GUI enable the launch-at-login toggle; then `runner-control app launch-at-login status --json`",
        "expected_failure": "enabled=false (GUI shows on). Then `runner-control app launch-at-login on` → System Settings › Login Items shows two entries and the GUI toggle still reads its own status.",
        "observed": "NOT EXECUTED under review guardrails (mutates the user's login items; triggers a TCC Automation prompt on this machine). Mechanism is API-level, not a suspicion; the implementer can reproduce in a throwaway user account."
      }
    ],
    "severity": "bypass",
    "repeat-of": "none",
    "fix_hint": "Use SMAppService.mainApp from the CLI as well (it is keyed by the app bundle; the CLI can construct SMAppService via the bundle identifier / loginItem API) or, if that proves impossible from a bare tool, document the command as out of scope rather than shipping a divergent mechanism."
  }
]
```

## notes (non-blocking)

- N1 Spec/doc mismatch: decomposition.md says CLIInstallerService carries a flock lease for the PATH-symlink install; it does not (CLIInstallerService.swift has no lock). The flock is in RunnerInstallerService (runner install root). Concurrent GUI+CLI symlink installs are unserialized; low impact (`ln -sf`) but the design doc overstates.
- N2 UNKNOWN, not verified: GitHubKeychainStore.swift:59-67 claims any Apple-signed binary of any team reads the items silently; verification.md itself records a "denied cross-team read". The production claim that matters — an item created by the GUI via SecItemAdd is readable by the same-team CLI with no SecurityAgent prompt — is not demonstrated by the attached evidence (the e2e seeded a TESTCLIENT slot; the seeding tool/ACL is not recorded). Recommend one recorded e2e: dev GUI login creates the item, dev CLI `auth status` reads it, no prompt. Release invariant "one identity for app and CLI" is satisfied by release.sh:37-42 and build.sh (re-seal with the same identity).
- N3 Negative-evidence shape: `installRootLockRefusesForeignProcessHolder` (CLICompanionTests.swift:124-182) returns silently — i.e. passes — when the child helper fails to start or never prints HELD (absent fixture treated as satisfied). Measured here: the helper reaches HELD in 0.57 s and the test took 0.93 s, consistent with the child having actually run, so the cross-process refusal is currently exercised. Make the skip explicit (Issue/known-issue) so an environment without `swift` cannot turn the only negative test for the lease into a green.
- N4 `lockInstallRoot` fails open on every error except EWOULDBLOCK (RunnerInstallerService.swift:196-216), documented; acceptable, but a lock file replaced by a directory silently degrades to in-process-only serialization.
- N5 Typed contract inconsistency: app-domain payloads emit booleans as strings ("enabled":"true", "updateAvailable":"true") while DTOs emit real booleans.
- N6 `runners remove --json` drops the "service keeps running" catalogError note that the text mode prints (RunnersCommands.swift:265-273).
- Held-by-reading: restoreSession nil-read fix (GitHubAuth+Flow.swift:313-321) is read-only and keeps identity; login/logout still repair; the new `flowRestoreSessionWithUnreadableTokenKeepsIdentity` test is a true negative test (fails on the pre-fix delete). `requireLogin` gates auth-requiring commands with exit 3. Destructive confirmations mirror the GUI (`--yes`/TTY for stops, typed `--confirm` for unregister, non-TTY refuses). No DTO carries a token.
