# TASK-260916-97dhxd — review verdict, CR-TASK-260916-97dhxd-3 revision 3

Verdict: **accepted** (`accept_cr`, revision 3)
repeat-of: none

Candidate tree 78a50593fd6982c65740b787a19885e9d233f528 (base 7d2126ae). Story worktree diffed against the candidate tree before and after review: 0 differing paths, HEAD unchanged at 7d2126ae. All mutants and attacks ran in scratch copies (`/tmp/rev3-scratch`, `/tmp/rev3-build`); the worktree was never mutated.

## What I reran myself (not carried over)

- `swift test --package-path Packages/RunnerControlCore` → 64 tests passed, exit 0. RA1–RA4 sequences observed: RA1 `[restoreStarted, loggedOut]`, RA2 ends at `loggedOut`, RA3 `[restoreStarted, loginStarted, codeReceived, failed]` (trailing `failed` is the poll draining the shared slow queue, as the outcome states), RA4 ends at `loggedOut`.
- `./Scripts/build.sh` (tuist generate + Release xcodebuild + codesign verify) → exit 0, BUILD SUCCEEDED (73 s). Composed `Info.plist`: `GitHubAppClientID=Iv23ligBUam7vZitsE1G`, `GitHubAppSlug=relux-runner-control`, `CFBundleShortVersionString=1.2.0`, no key matching secret/private/token; `codesign --verify --deep --strict` exit 0.
- `swiftlint lint` default config: 142 errors total, **45 first-party** — per-file split identical to the F7 table (Transport 37, Flow 3, Reducer 1, Runners+Service 2, RunnerControlCoreTests 1, RunnerContainer 1). The reported-fact finding is resolved: lint is reported red with the exact count.
- Secret scan over `Packages/*/Sources`, `Targets`, `ios-app-manager.json`, `.spec`: no `client_secret`, private key, or token-shaped literal beyond the PATGuard prefixes.
- `.spec/github-login-device-flow.md` carries the new "Lifecycle boundary" section matching the implemented generation guards.

## Rev2 findings — status

- **F6 (logout/login vs in-flight restore/refresh/select) — RESOLVED.** `beginLogin`/`cancelLogin`/`logout` bump `generation` and `await refresher.cancelInFlight()`. `restoreSession`, `restoreInstallations`, `refreshInstallations`, `selectInstallation`, `currentToken(generation:)`, `handlePollSuccess`, `loginInstallationsFailed` capture the generation and guard after every await before session/identity/token writes and every dispatch. `GitHubTokenRefresh` throws `CancellationError` at a pre-save check and compare-and-deletes an orphan after a mid-save cancel. RA1–RA3 are committed verbatim, plus RA4 and the helper-level test.
- **F7 (lint claim) — RESOLVED** as a truthful bound (count reproduced above).
- Minor items from rev2: `selectInstallation` revoked path now yields `.failed(relogin)` (`flowSelectInstallationWithRevokedTokenRequiresRelogin`); restore keeps tokens on 401-after-failed-refresh (`flowRestoreWithFailedRefreshThen401KeepsTokensAndStaysStale`); `UserDefaultsGitHubSessionIdentityStore` round-trip test added. All three verified present and green.

## Reviewer attack (rev3) — narrowing mutants I ran, all KILLED

| Mutant | Narrowing | Failing named test | Result |
|---|---|---|---|
| RV-A: `restoreSession` post-`fetchUser` guard replaced by proxy signal `session == nil` (gate present, wrong signal) | admits session/identity revival after logout when session happens to be nil | `reviewerLogoutDuringRestoreDoesNotReviveSession` | exit 1: post-logout refresh emitted `failed`, identity re-saved |
| RV-B: `beginLogin` bumps `generation` only when `pollTask != nil` | admits a fresh login not superseding an in-flight restore | `reviewerLoginDuringRestoreIsNotClobberedByRestore` | exit 1: `connected` after `codeReceived` |
| RV-C: `cancelInFlight` drops the task reference without `cancel()` | admits the coalesced refresh finishing and saving after logout | `refreshCancelInFlightNeverSavesRefreshedRecord`, `reviewerLogoutDuringRefreshLeavesNoTokensBehind` | exit 1: `ghu_new` saved / Keychain non-empty after logout |

Producer mutants F6a/F6b/F6c are genuine narrowing mutants with named failing tests; accepted on the log. Rev1/rev2 mutants cover unchanged behavior and were not rerun.

## AC-row status

9 of 11 rows driven by named committed tests through `Flow.apply` production call sites; rows 1 (build) and 11 (menu wiring) are stated bounds, row 1 verified by my build run, row 11 manual per "no UI tests". Row 7 (logout) is now driven for the interleaved class; the rev2 downgrade is lifted.

## Residual bounds (accepted, not blocking)

- A logout landing exactly inside `store.save` in `handlePollSuccess` (before identity is saved) can leave a token record with no identity; real Keychain writes are sub-millisecond, next restore/login for that user overwrites or sweeps it. Same class as the producer's stated helper-level non-atomic load/delete bound.
- `refreshInstallations` 401 path dispatches `.failed(relogin)` without clearing `session`/Keychain (rev2-accepted behavior); the next user action is a relogin which supersedes it.
- `Redaction.sanitize` still has no production caller (rev2-accepted bound: no diagnostics export in this slice).
- Design AC "existing menu remains functional": Runners suite green, wiring reviewed by reading `RunnerContainer`/`RunnerPage` diff (+4/+3 lines adding the settings entry); no UI test by task constraint.

Repository delta present; accepted as the complete login/window slice. Integration is the bound producer run's step.
