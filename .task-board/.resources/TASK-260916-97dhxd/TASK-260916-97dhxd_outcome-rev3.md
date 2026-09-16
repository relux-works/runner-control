# TASK-260916-97dhxd — rework rev3 outcome (review findings F6, F7)

Status: ready for review (board `to-review` via handoff).
Candidate: uncommitted in Story worktree, branch tip unchanged at `7d2126a`.
F1–F5 preserved as accepted; no generator rerun (no scaffold change this round).

## F6 — logout/login supersede in-flight restore/refresh/select (blocking, fixed)

Root cause (confirmed by reproducing all three reviewer attacks on the
candidate before the fix): `logout()` bumped `generation` but
`restoreSession`/`restoreInstallations`/`refreshInstallations`/
`selectInstallation`/`currentToken` never captured or re-checked it, so a
continuation landing after logout/new login revived the session, re-saved
the identity, and emitted state. The token-refresh helper could also save
refreshed tokens after logout.

Fix (production call sites):

- `GitHubAuth.Flow` (`Packages/RunnerControlCore/Sources/GitHubAuth+Flow.swift`):
  `beginLogin`/`cancelLogin`/`logout` bump `generation` and now also
  `await refresher.cancelInFlight()`. `restoreSession`,
  `restoreInstallations`, `refreshInstallations`, `selectInstallation`,
  and `currentToken(generation:)` capture the generation at entry and
  `guard !isStale(gen) else { return }` after every `await` before
  mutating `session`, saving identity/tokens, or dispatching.
  `CancellationError` from a cancelled refresh is a silent return, never
  an error dispatch. `handlePollSuccess` gained the missing guards around
  its Keychain save, identity save, and `accountVerified` dispatch, and
  `loginInstallationsFailed` takes the generation and guards each dispatch.
- `GitHubTokenRefresh` (`GitHubTokenRefresh.swift`): new
  `cancelInFlight()` cancels and drops the coalesced task; the task
  throws `CancellationError` at a pre-save `Task.isCancelled` check, and
  a post-save check compare-and-deletes the just-saved record (access
  token still equals the fresh value, so a newer login's tokens are never
  touched) if cancel landed mid-save.
- Minor, local to touched logic: `selectInstallation` now maps
  revoked/unauthorized/`tokenRefreshFailed` from `currentToken` to
  `.failed(relogin)`, matching `refreshInstallations` (was `syncFailed`).
- Minor, local to touched logic: a 401 in `restoreSession` with an
  unrefreshed expiring token (refresh failed transiently) keeps Keychain
  + identity and reports `connected` + `syncFailed` for a later retry
  instead of deleting a still-valid refresh token and demanding relogin.
- Spec: `.spec/github-login-device-flow.md` gains a Lifecycle boundary
  section and the 401-heuristic note under Session restore.

Committed regression tests
(`Packages/RunnerControlCore/Tests/GitHubAuthLifecycleTests.swift`):

- `reviewerLogoutDuringRestoreDoesNotReviveSession` (RA1, reviewer
  verbatim modulo a zero-behavior line wrap),
- `reviewerLogoutDuringRefreshDoesNotEmitSyncAfterLoggedOut` (RA2, verbatim),
- `reviewerLoginDuringRestoreIsNotClobberedByRestore` (RA3, verbatim),
- `reviewerLogoutDuringRefreshLeavesNoTokensBehind` (RA4, new: logout
  mid-refresh leaves Keychain + identity empty, nothing after `loggedOut`),
- `refreshCancelInFlightNeverSavesRefreshedRecord` (new helper proof),
- `flowRestoreWithFailedRefreshThen401KeepsTokensAndStaysStale` (new),
- `flowSelectInstallationWithRevokedTokenRequiresRelogin` (new),
- `userDefaultsSessionIdentityStoreRoundTrips` (new production-adapter test).

Observed authentic failure first: on the pre-fix candidate RA1 produced
`[restoreStarted, loggedOut, accountVerified, installationsLoaded,
connected]` with re-saved identity and live session; RA2 produced
`installationsLoaded, syncSucceeded` after `loggedOut`; RA3 produced
`connected` after `codeReceived`. After the fix: RA1
`[restoreStarted, loggedOut]`, RA2 ends at `loggedOut`, RA3
`[restoreStarted, loginStarted, codeReceived, failed]` (the trailing
`failed` is the poll consuming the shared slow queue's next response,
allowed by the test).

## F7 — truthful lint scope/count (secondary, resolved as bound)

Tool: `swiftlint lint`, version 0.57.0, default config (no
`.swiftlint.yml` in repo), exit code 2. First-party errors: **45**
(third-party checkouts + build artifacts contribute 97 more, excluded):

| File | Errors | Class |
|---|---|---|
| `GitHubTransport.swift` | 37 (36 `identifier_name` + 1 `line_length`) | Pre-existing rev1: snake_case DTO names match GitHub JSON keys; `k`/`v`; one 209-char line |
| `GitHubAuth+State+Reducer.swift` | 1 (`cyclomatic_complexity` 21) | Pre-existing rev1 |
| `GitHubAuth+Flow.swift` | 3 (`restoreSession` complexity 42 + body 110 lines; `restoreInstallations` complexity 26) | NEW this round: required per-await lifecycle-guard density; splitting would obscure the audit-critical guard sequence |
| `Runners+Service.swift` | 2 (`identifier_name` `d`) | Pre-existing, untouched by this task |
| `RunnerControlCoreTests.swift` | 1 (`line_length`) | Pre-existing |
| `RunnerContainer.swift` | 1 (`line_length`) | Earlier rev of this task |
| `GitHubAuthLifecycleTests.swift` | 0 errors (warnings only) | 2 reviewer-RA long lines wrapped this round, zero behavior change |

No broad style cleanup performed. Lint is reported red with this exact
count, not as clean.

## AC coverage — 9 of 11 rows driven via committed tests

Same ratio as rev2; row 7 is upgraded from sequential-only to full
interleaved coverage (reviewer downgrade lifted).

| # | AC row | Named committed test(s) | Production call site |
|---|---|---|---|
| 1 | App builds | BOUND (`./Scripts/build.sh` below, not a unit test) | `tuist generate` → `xcodebuild -scheme RunnerControl` → `codesign --verify` |
| 2 | Real login UI drives production services | `flowLoginSuccessDrivesProductionEffectsToConnected` (+ identity persistence; UI binding manual, no UI tests) | `ManagementWindowContainer.beginLogin → GitHubAuth.Effect.beginLogin → GitHubAuth.Flow.apply` |
| 3 | Cancellation | `flowCancellationDestroysCodeAndStopsPoll`, `flowCancelWhileConnectedRestoresConnected` | `GitHubAuth.Flow.apply(.cancelLogin)` |
| 4 | slow_down | `flowSlowDownIncreasesIntervalThenSucceeds`, `slowDownAddsFiveSeconds` | `GitHubDeviceFlow.pollOnce` + `nextInterval` via `Flow.apply(.beginLogin)` |
| 5 | Expired code | `flowExpiredCodeFailsWithNewCode` | `GitHubDeviceFlow.pollOnce` via `Flow.apply(.beginLogin)` |
| 6 | Refresh concurrency | `flowRefreshInstallationsRefreshesExpiringTokenViaProductionPath`, `flowConcurrentRefreshAndSelectCoalesceToSingleRefresh`, `flowRefreshInstallationsWithInvalidGrantDuringRefreshRequiresRelogin` | `GitHubAuth.Flow.currentToken(generation:)` via `Flow.apply(.refreshInstallations)` / `.selectInstallation` |
| 7 | Logout + interleaving | `reviewerLogoutDuringRestoreDoesNotReviveSession`, `reviewerLogoutDuringRefreshDoesNotEmitSyncAfterLoggedOut`, `reviewerLoginDuringRestoreIsNotClobberedByRestore`, `reviewerLogoutDuringRefreshLeavesNoTokensBehind`, `refreshCancelInFlightNeverSavesRefreshedRecord`, `flowLogoutClearsKeychainAndStopsSync`, restore/401/select/UserDefaults tests | `Flow.apply(.logout)` vs `.restoreSession` / `.refreshInstallations` / `.beginLogin`; `GitHubTokenRefresh.cancelInFlight` |
| 8 | 401 | `flowLoginPhase401DuringInstallationsRequiresRelogin`, `flow401DuringRefreshRequiresRelogin`, `apiClientMaps401And403`, `flowRestoreWithFailedRefreshThen401KeepsTokensAndStaysStale` | `GitHubAPIClient.*` via `Flow.apply(...)` |
| 9 | 403 | `flow403DuringRefreshKeepsConnectedWithStaleError`, `apiClientMaps401And403` | `GitHubAPIClient.fetchInstallations` via `Flow.apply(.refreshInstallations)` |
| 10 | No PAT fallback | `refreshRejectsFineGrainedPATWithoutSaving`, `patGuardRejectsClassicAndFineGrainedPAT`, `apiClientRefusesPATWithoutNetwork`, `devicePollRejectsPATShapedToken` | `GitHubAuth.PATGuard.validate` via device poll, API client, token refresh |
| 11 | Existing menu functional | BOUND (Runners suite green; menu UI wiring manual, no UI tests) | `RunnerContainer.change → Runners.Effect.setEnabled → Runners.Flow.apply` |

## Validation (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` → exit 0, 64/64 passed.
- `./Scripts/build.sh` (tuist generate + Release xcodebuild + `codesign --verify --deep --strict`) → exit 0, BUILD SUCCEEDED.
- `codesign --verify --deep --strict .temp/products/RunnerControl.app` → exit 0.
- Release `Info.plist`: `GitHubAppClientID=Iv23ligBUam7vZitsE1G`, `GitHubAppSlug=relux-runner-control`, `CFBundleShortVersionString=1.2.0`; 0 plist keys matching secret/private_key/token.
- `swiftlint lint` (default config) → exit 2, 45 first-party errors per F7 table above (reported red, not clean).
- Not run: `RUN_LAUNCH_AGENT_INTEGRATION=1` launchd integration (touches host launchd; default suite skips it), UI tests (forbidden), release/notary (other Story).

## Narrowing mutant evidence, rev3 round (all killed, exit 1)

Each mutant ran in a scratch copy (`/tmp/mutant-F6a|b|c`) with a clean
`.build`; the worktree was never mutated.

| Mutant | Narrowing (what it admits) | Named test that fails | Result |
|---|---|---|---|
| F6a: drop ONLY the post-`fetchUser` guard in `restoreSession` (later guards kept) | admits session set + identity re-save after logout; later guards still block `accountVerified`/`connected` dispatches | `reviewerLogoutDuringRestoreDoesNotReviveSession` | KILLED exit 1: session live (post-logout refresh emitted `failed` instead of no-op) and `identities.load() == nil` failed |
| F6b: drop ONLY the post-`fetchInstallations` guard in `refreshInstallations` (pre-`syncSucceeded` guard kept) | admits exactly one emission after logout | `reviewerLogoutDuringRefreshDoesNotEmitSyncAfterLoggedOut` | KILLED exit 1: `afterLogout == ["installationsLoaded"]`, `syncSucceeded` still suppressed |
| F6c: drop ONLY the pre-save `Task.isCancelled` check in `GitHubTokenRefresh` (post-save compare-and-delete kept) | admits overwriting the old record on cancel; post-save cleanup then deletes it instead of preserving the old token | `refreshCancelInFlightNeverSavesRefreshedRecord` | KILLED exit 1: store no longer holds `ghu_old` |

Rev1 mutants M1–M8/M9d and rev2 mutants R1/R2/N1/N2/N3/W1/L1 were
accepted by the reviewer and touch unchanged behavior; not rerun. No new
survivors in rev3.

## Bounds restated

- Tokens/`device_code` never in `GitHubAuth.State`, actions, logs, or
  `RuntimeLogger` (type-only). Identity store holds no secrets.
- The sub-microsecond true-concurrency window between the helper's
  pre-save cancel check and the save call is closed best-effort by the
  post-save compare-and-delete; the load-then-delete pair is not atomic,
  so a save from a newer login interleaving exactly inside that pair is a
  stated residual bound (real-world tokens differ per login, so the
  compare protects the newer login).
- `Redaction.sanitize` still has no production caller (accepted rev2
  bound: no diagnostics export in this slice).
- Enterprise hosts get host-scoped endpoints; per-server App
  registration + Device Flow support still required (concrete error).
- No `gh` import, no PAT UI, no client secret/private key anywhere.
- Root's live run reached the real GitHub authorization page in Brave;
  no Authorize action taken by this run; no browser or production runner
  services altered.
- Work left uncommitted in Story worktree; branch tip unchanged.
