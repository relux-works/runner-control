# TASK-260916-97dhxd — github-login-and-management-window — outcome

Status: ready for review (board `to-review` via handoff).

## What shipped (uncommitted candidate in Story worktree)

- `GitHubAuth` Relux module (actor services, HybridState/reducer/Flow, Module):
  `GitHubAuth.swift`, `GitHubAuth+State.swift`, `GitHubAuth+State+Reducer.swift`,
  `GitHubAuth+Flow.swift`, `GitHubAuth+Module.swift`, `GitHubAuth+Models.swift`.
- Transport/security: `GitHubAppConfig.swift` (public client_id only, exact
  missing binding, `auditNoSecrets`), `GitHubTransport.swift` (HTTP boundary,
  DTOs, `RESTMapper`, `PATGuard`), `GitHubDeviceFlow.swift` (code/poll,
  slow_down +5), `GitHubAPIClient.swift` (/user, installations, repos),
  `GitHubTokenRefresh.swift` (serialized single-flight refresh),
  `GitHubKeychainStore.swift` (Keychain + in-memory backend),
  `GitHubRedaction.swift` (diagnostic scrub).
- App: `ManagementWindowContainer.swift` + `ManagementWindowPage.swift` (+Props)
  760×540 tabs (Runners/GitHub/General), `LaunchAtLoginModel.swift`,
  `AppRegistry.swift` (both modules, 3s local / 30s GitHub loops),
  `App.swift` (management window via reopen + notification, no new delegate),
  `RunnerContainer/Page` + "Раннеры и настройки…" (menu intact).
- Generator input only: `ios-app-manager.json` adds
  `macos.info_plist.GitHubAppClientID: ""` (placeholder; coordinator provisions
  real public client_id, then `ios-app-manager generate macos-app` converges
  `Project.swift`). `Project.swift`/`Package.swift` untouched by hand.
- `.spec/` materialized from approved-design with registration + removal in
  scope: README, github-login-device-flow, management-window,
  runner-registration, runner-removal, offline-local-control.

Missing binding (exact, user-visible when unprovisioned):
`Info.plist[GitHubAppClientID] (scaffold input ios-app-manager.json →
macos.info_plist.GitHubAppClientID, coordinator-provisioned public client_id)`

## AC coverage — 9 of 11 rows driven via committed tests

| # | AC row | Named committed test(s) | Production call site |
|---|---|---|---|
| 1 | App builds | BOUND (verified via build commands below, not a unit test) | `Scripts/build.sh` path: `tuist generate`, `xcodebuild -scheme RunnerControl`, `codesign --verify` |
| 2 | Real login UI drives production services | `flowLoginSuccessDrivesProductionEffectsToConnected` (Flow path UI calls; UI binding manual, no UI tests per task) | `ManagementWindowContainer.beginLogin → action { GitHubAuth.Effect.beginLogin } → GitHubAuth.Flow.apply` |
| 3 | Cancellation | `flowCancellationDestroysCodeAndStopsPoll`, `flowCancelWhileConnectedRestoresConnected` | `GitHubAuth.Flow.apply(.cancelLogin)` |
| 4 | slow_down | `flowSlowDownIncreasesIntervalThenSucceeds`, `slowDownAddsFiveSeconds` | `GitHubDeviceFlow.pollOnce` + `nextInterval` via `Flow.apply(.beginLogin)` |
| 5 | Expired code | `flowExpiredCodeFailsWithNewCode` | `GitHubDeviceFlow.pollOnce` via `Flow.apply(.beginLogin)` |
| 6 | Refresh concurrency | `refreshSavesAtomicallyAndCoalescesConcurrentCallers` | `GitHubTokenRefresh.refresh` |
| 7 | Logout | `flowLogoutClearsKeychainAndStopsSync` | `GitHubAuth.Flow.apply(.logout)` |
| 8 | 401 | `apiClientMaps401And403`, `flow401DuringRefreshRequiresRelogin` | `GitHubAPIClient.fetchInstallations` + `Flow.apply(.refreshInstallations)` |
| 9 | 403 | `apiClientMaps401And403`, `flow403DuringRefreshKeepsConnectedWithStaleError` | `GitHubAPIClient.fetchInstallations` + `Flow.apply(.refreshInstallations)` |
| 10 | No PAT fallback | `patGuardRejectsClassicAndFineGrainedPAT`, `apiClientRefusesPATWithoutNetwork`, `devicePollRejectsPATShapedToken` | `GitHubAuth.PATGuard.validate/authorizationHeader` via `GitHubAPIClient`/`GitHubDeviceFlow` |
| 11 | Existing menu functional | BOUND (Runners suite green incl. `reducerPreserves…`, `startIsIdempotent…`, `startWaits…`; menu UI wiring manual, no UI tests) | `RunnerContainer.change → Runners.Effect.setEnabled → Runners.Flow.apply` |

## Validation (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` → exit 0, 45 tests passed.
- Skill script `run-macos-package-tests.sh --package Packages/RunnerControlCore --output .temp/macos-tests` → exit 0, 45 passed, JUnit/logs under `.temp/macos-tests`.
- `tuist generate --no-open` → exit 0.
- `xcodebuild -workspace RunnerControl.xcworkspace -scheme RunnerControl -configuration Release -destination 'platform=macOS' … build` → BUILD SUCCEEDED (exit 0 via grep; full log exit 65 only on the pre-fix run, 0 after closure fix).
- `codesign --verify --deep --strict .temp/products/RunnerControl.app` → exit 0; bundle `works.relux.runnercontrol`, version `1.1.1`.
- `swiftlint lint` on new files → exit 0, 0 serious (warnings only; pre-existing files carry their own baseline warnings; `ManagementWindowPage` split to fix `type_body_length` error).
- Not run: `RUN_LAUNCH_AGENT_INTEGRATION=1` launchd integration (touches host launchd; default suite skips it), UI tests (forbidden by task), release/notary (other Story).

## Narrowing mutant evidence (gate stays, weakened to admit one member)

| Mutant | Narrowing (what it admits) | Named test that fails | Result |
|---|---|---|---|
| M1 PAT `ghp_` only | admits `github_pat_*` | `patGuardRejectsClassicAndFineGrainedPAT` | KILLED (exit 1, "admitted PAT 'github_pat_abc123'") |
| M2 REST 403 disabled (`4030`) | 403 falls to generic network | `apiClientMaps401And403` | KILLED (exit 1, got `.network` not `.forbidden`) |
| M3 `expired_token → pending` | expired loops as pending | `flowExpiredCodeFailsWithNewCode` | KILLED (exit 1, got `.retry` not `.newCode`) |
| M4 slow_down no +5 | interval stays 5 | `flowSlowDownIncreasesIntervalThenSucceeds` | KILLED (exit 1, got `pollIntervalUpdated(5)` not 10) |
| M5 `inFlight` disabled | concurrent refresh does 2× HTTP | `refreshSavesAtomicallyAndCoalescesConcurrentCallers` | KILLED (exit 1, `requests.count == 1` failed) |
| M6 logout skips Keychain delete | token survives logout | `flowLogoutClearsKeychainAndStopsSync` | KILLED (exit 1, `load(...) == nil` failed) |
| M7 audit `secret`-only | admits `private_key`/`token` keys | `auditRejectsEmbeddedSecrets` | KILLED (exit 1, admitted `AppPrivateKey`, `GitHubToken`, …) |
| M8 redaction drops `device_code` | `dev789` leaks | `redactionScrubsExactSecretsAndJSONShapes` | KILLED (exit 1, `contains("dev789")`) |
| M9 cancel drops `pollTask.cancel` | relies on generation+nil only | — (survivor) | SURVIVED (exit 0). Bound: cancellation has triple redundancy (generation + Task.cancel + `deviceCode=nil`); dropping Task.cancel alone still stops via generation check. Test proves generation gate, not Task.cancel necessity. |
| M9c cancel only when connected | login-phase cancel skips generation+cancel | — (survivor) | SURVIVED (exit 0). Bound: `deviceCode=nil` alone stops the sleep-phase loop via `guard let code`; test timing (cancel during sleep) does not isolate generation. |
| M9d cancel always `loginCancelled` | connected-cancel disconnects | `flowCancelWhileConnectedRestoresConnected` | KILLED (exit 1, got `loginCancelled` not `connected`) |

No source-text (grep) gates shipped; PAT/secret enforcement is behavioral
(`PATGuard`, `auditNoSecrets`, `Redaction`), so the "preserve token" mutant
clause is N/A. Delete-only mutants were not used as evidence.

## Notes / bounds

- Tokens/`device_code` never in `GitHubAuth.State`, logs, or `RuntimeLogger`
  (type-only). Keychain account `<host>:<userID>:<clientID>`.
- Offline/403/rate-limit keep local control; 401/revoked → relogin. Stale
  `busy=false` (>60s) is labeled stale, never idle proof.
- Enterprise hosts get host-scoped endpoints; App registration + Device Flow
  support must be verified per server (concrete error, local works).
- No `gh` credential import, no PAT UI, no client secret/private key fields.
- Work left uncommitted in Story worktree for handoff snapshot (no producer commit).
