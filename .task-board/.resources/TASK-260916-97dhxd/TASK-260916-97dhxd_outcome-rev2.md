# TASK-260916-97dhxd — rework rev2 outcome (review findings F1–F5)

Status: ready for review (board `to-review` via handoff).
Candidate: uncommitted in Story worktree, branch tip unchanged at `7d2126a`.

## F1 — session restore from Keychain (was: in-memory only)

- New `GitHubSessionIdentityStore.swift`: non-secret identity
  (`serverHost`, `userID`, `clientID`, `username`) in UserDefaults;
  tokens stay in Keychain. In-memory store for tests.
- New `GitHubAuth.Effect.restoreSession` + `Action.restoreStarted`
  (reducer → existing `.verifyingAccount`; no UI change needed).
  Flow loads identity → Keychain record → PAT-shape check →
  opportunistic serialized refresh → `GET /user` validation →
  installations (+ first-installation repositories) → `.connected`.
- 401/revoked/`invalid_grant`/PAT-shaped store → clears Keychain +
  identity, `.failed(relogin|none)`. Offline/403/rate-limit →
  restored session with stale `syncFailed`; local control and logout
  stay available. Missing Keychain record clears orphan identity.
- `logout` also deletes identity, and reaches persisted stores via the
  identity when the in-memory session is already gone (relaunch can
  never orphan tokens).
- Production call site: `AppRegistry.start()` dispatches
  `.restoreSession` once after `RunnerRuntime.make`, before the loops,
  so the 30 s GitHub loop sees `.connected`.
- Spec: `.spec/github-login-device-flow.md` gains a Session restore section.

## F2 — refresh concurrency at the production call site

`GitHubAuth.Flow.currentToken()` (used by `.refreshInstallations` and
`.selectInstallation`) is now driven directly: expiring token
(`expiresAt` now+30 s) → one refresh POST observed in
`TestTransport.requests` → stored token rotates → `syncSucceeded`;
`invalid_grant` on refresh → `.failed(relogin)`; two concurrent Flow
callers (`refreshInstallations` + `selectInstallation(7)`) coalesce to
exactly one `refresh_token` grant (URL-routing test transport).

## F3 — PAT guard on the refresh path

`refreshRejectsFineGrainedPATWithoutSaving` feeds
`{"access_token":"github_pat_..."}` to `GitHubTokenRefresh.refresh`,
expects `.patNotSupported`, and proves the Keychain still holds the
old `ghu_` token. All three `PATGuard` call sites now have negative tests.

## F4 — audit wired; redaction bounded

- `AppConfig.current(bundle:serverHost:)` now calls
  `auditNoSecrets(in: bundle.infoDictionary)` first and fails closed.
  `configAuditRunsThroughCurrentBundle` drives both branches through
  `current(bundle:)` with real temp `.bundle` plists (tainted → 
  `.embeddedSecret("ClientSecret")`; clean → loads).
- `Redaction.sanitize` has no production caller: STATED BOUND.
  No diagnostics export exists in this slice (log tail / `_diag`
  lands with catalog/lifecycle); `RuntimeLogger` emits action types
  only, so there is nothing to scrub. Noted in code + here.

## F5 — public binding embedded via generator

- `ios-app-manager.json`: `GitHubAppClientID: "Iv23ligBUam7vZitsE1G"`,
  `GitHubAppSlug: "relux-runner-control"`, `marketing_version: "1.2.0"`.
- Regenerated with `/Users/iv/Documents/Codex/2026-09-15/new-chat-4/work/ios-app-manager generate macos-app`
  (exit 0, "existing source files preserved"). `Project.swift` diff is
  exactly: version 1.2.0 + the two public keys. Never hand-edited.
- Release `Info.plist` carries `GitHubAppClientID` /
  `GitHubAppSlug`; plist + binary strings contain no
  `secret`/`private_key`/`ghp_`/`github_pat_`/`ghu_`/`ghr_` material.
  No installation IDs, accounts, users, orgs, or repos hardcoded.

## Incidental (kept minimal)

- `handlePollSuccess` split into `loadLoginRepositories` +
  `loginInstallationsFailed` (identical dispatch order) to fix the
  pre-existing `cyclomatic_complexity` lint error (22 → under 20).
- Fixed pre-existing lint errors in touched test files
  (`try!` → `try` / scoped disable, `a`/`b`/`v` renames).
- New test `flowLoginPhase401DuringInstallationsRequiresRelogin`
  closes the login-tail 401 branch the split touched.

## AC coverage — 9 of 11 rows driven via committed tests

| # | AC row | Named committed test(s) | Production call site |
|---|---|---|---|
| 1 | App builds | BOUND (verified via `./Scripts/build.sh` below, not a unit test) | `tuist generate` → `xcodebuild -scheme RunnerControl` → `codesign --verify` |
| 2 | Real login UI drives production services | `flowLoginSuccessDrivesProductionEffectsToConnected` (+ `flowLoginPersistsSessionIdentityForLaterRestore`; UI binding manual, no UI tests) | `ManagementWindowContainer.beginLogin → GitHubAuth.Effect.beginLogin → GitHubAuth.Flow.apply` |
| 3 | Cancellation | `flowCancellationDestroysCodeAndStopsPoll`, `flowCancelWhileConnectedRestoresConnected` | `GitHubAuth.Flow.apply(.cancelLogin)` |
| 4 | slow_down | `flowSlowDownIncreasesIntervalThenSucceeds`, `slowDownAddsFiveSeconds` | `GitHubDeviceFlow.pollOnce` + `nextInterval` via `Flow.apply(.beginLogin)` |
| 5 | Expired code | `flowExpiredCodeFailsWithNewCode` | `GitHubDeviceFlow.pollOnce` via `Flow.apply(.beginLogin)` |
| 6 | Refresh concurrency | `flowRefreshInstallationsRefreshesExpiringTokenViaProductionPath`, `flowConcurrentRefreshAndSelectCoalesceToSingleRefresh`, `flowRefreshInstallationsWithInvalidGrantDuringRefreshRequiresRelogin` (+ helper `refreshSavesAtomicallyAndCoalescesConcurrentCallers`) | `GitHubAuth.Flow.currentToken()` via `Flow.apply(.refreshInstallations)` / `.selectInstallation` |
| 7 | Logout (+ F1 restore) | `flowRestoreSessionConnectsFromPersistedIdentityThenLogoutClearsBoth`, `flowRestoreSessionWithRevokedTokenRequiresReloginAndClearsStorage`, `flowRestoreSessionWithoutIdentityIsNoop`, `flowLogoutClearsKeychainAndStopsSync`, `githubReducerRestoreStartedShowsVerifyingAccount` | `GitHubAuth.Flow.apply(.restoreSession)` from `AppRegistry.start()`; `Flow.apply(.logout)` |
| 8 | 401 | `flowLoginPhase401DuringInstallationsRequiresRelogin`, `flow401DuringRefreshRequiresRelogin`, `apiClientMaps401And403` | `GitHubAPIClient.*` via `Flow.apply(.beginLogin/.refreshInstallations/.restoreSession)` |
| 9 | 403 | `flow403DuringRefreshKeepsConnectedWithStaleError`, `apiClientMaps401And403` | `GitHubAPIClient.fetchInstallations` via `Flow.apply(.refreshInstallations)` |
| 10 | No PAT fallback | `refreshRejectsFineGrainedPATWithoutSaving`, `patGuardRejectsClassicAndFineGrainedPAT`, `apiClientRefusesPATWithoutNetwork`, `devicePollRejectsPATShapedToken` | `GitHubAuth.PATGuard.validate` via device poll, API client, and token refresh |
| 11 | Existing menu functional | BOUND (Runners suite green; menu UI wiring manual, no UI tests) | `RunnerContainer.change → Runners.Effect.setEnabled → Runners.Flow.apply` |

## Validation (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` → exit 0, 56/56 passed.
- Skill script `run-macos-package-tests.sh --package Packages/RunnerControlCore --output .temp/macos-tests` → exit 0, 56 passed.
- `./Scripts/build.sh` (tuist generate + Release xcodebuild + codesign verify) → exit 0, BUILD SUCCEEDED.
- `codesign --verify --deep --strict .temp/products/RunnerControl.app` → exit 0.
- `swiftlint lint` on 6 touched files → exit 0, 0 serious (118 warnings, same baseline classes as rev1: line_length, trailing_comma).
- Not run: `RUN_LAUNCH_AGENT_INTEGRATION=1` launchd integration (touches host launchd; default suite skips it), UI tests (forbidden), release/notary (other Story).

## Narrowing mutant evidence, rev2 round (all killed, exit 1)

| Mutant | Narrowing (what it admits) | Named test that fails | Result |
|---|---|---|---|
| R1 (reviewer rerun) Flow refreshes only when `refreshToken == nil` | expiring refreshable token never refreshed | `flowRefreshInstallationsRefreshesExpiringTokenViaProductionPath`, `flowConcurrentRefreshAndSelectCoalesceToSingleRefresh` | KILLED (exit 1; 0 refresh grants, stored token stale, no `syncSucceeded`) |
| R2 (reviewer rerun) refresh-path PAT check is `ghp_`-only | admits `github_pat_*` on refresh | `refreshRejectsFineGrainedPATWithoutSaving` | KILLED (exit 1; mutant saved the PAT, store no longer `ghu_old`) |
| N1 restore 401 narrowed to stale | revoked token restores as connected instead of relogin+clear | `flowRestoreSessionWithRevokedTokenRequiresReloginAndClearsStorage` | KILLED (exit 1; got connected-path actions, not `.failed(relogin)`) |
| N2 logout skips identity delete | identity survives logout | `flowRestoreSessionConnectsFromPersistedIdentityThenLogoutClearsBoth` | KILLED (exit 1; `identities.load() == nil` failed) |
| N3 refresh threshold narrowed to already-expired | admits soon-expiring (now+30 s) without refresh | `flowRefreshInstallationsRefreshesExpiringTokenViaProductionPath` | KILLED (exit 1; 1 token POST not 2, stored token stale) |
| W1 `current(bundle:)` skips audit call | admits embedded `ClientSecret` | `configAuditRunsThroughCurrentBundle` | KILLED (exit 1; admitted secret). Wiring proof; class coverage is M7 (rev1, accepted) |
| L1 login-tail 401 narrowed to `.revoked`-only | login-phase 401 connects instead of relogin | `flowLoginPhase401DuringInstallationsRequiresRelogin` | KILLED (exit 1; got connected-path, not `.failed(relogin)`) |

Rev1 mutants M1–M8, M9d were accepted by the reviewer (killed); M9/M9c
survivors carry the accepted triple-redundancy bound on untouched
cancellation code — not rerun. No new survivors in rev2.

## Bounds restated

- Tokens/`device_code` never in `GitHubAuth.State`, actions, logs, or
  `RuntimeLogger` (type-only). Identity store holds no secrets.
- Offline/403/rate-limit keep local control and the restored session;
  401/revoked → relogin with storage cleared.
- Enterprise hosts get host-scoped endpoints; per-server App
  registration + Device Flow support still required (concrete error).
- No `gh` import, no PAT UI, no client secret/private key anywhere.
- Work left uncommitted in Story worktree; branch tip unchanged.
