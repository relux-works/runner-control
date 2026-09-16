# TASK-260916-97dhxd — review verdict, CR-TASK-260916-97dhxd-1 revision 1

Verdict: **changes_requested → to-dev**
repeat-of: none

Candidate tree 019df1c6751160ea86589b4e157459edbf9bda76 (base 7d2126ae). Working tree in the Story worktree re-hashed to the same tree OID before review.

## What I reran myself (not carried over)

- `swift test --package-path Packages/RunnerControlCore` → 45 tests passed (exit 0).
- `tuist generate --no-open` + `xcodebuild -scheme RunnerControl -configuration Release` in a scratch copy → BUILD SUCCEEDED.
- Composed `RunnerControl.app/Contents/Info.plist`: no `GitHubAppClientID` key, no secret/token/private-key keys; binary strings carry no `ghp_`/`github_pat_`/`client_secret`/PRIVATE KEY material.
- Producer mutants M1–M8, M9d: log reviewed, all are genuine narrowing mutants with named failing tests. M9/M9c survivors are honestly bounded. Accepted.
- Two reviewer mutants applied in a scratch copy (worktree untouched), full suite run:
  - **R1** `GitHubAuth+Flow.swift` `currentToken()`: refresh only when `record.refreshToken == nil` (i.e. a refreshable expiring token is never refreshed). **SURVIVED — 45/45 green.**
  - **R2** `GitHubTokenRefresh.swift`: replace `PATGuard.validate` with a `ghp_`-only check (refresh path admits `github_pat_*`). **SURVIVED — 45/45 green.**

## Findings (ordered by severity)

### F1 — No session restore from Keychain; logout cannot reach persisted tokens after relaunch (correctness, blocks acceptance)
`GitHubAuth.Flow.session` is in-memory only. Nothing at composition (`RunnerRuntime.make`, `AppRegistry.start`) or in the Flow loads the Keychain record and re-establishes `.connected`. After an app relaunch:
- UI shows `disconnected`; the user must run a full Device Flow again on every launch, so the Keychain persistence delivers nothing.
- The 30 s `refreshInstallations` loop in `AppRegistry` is gated on `.connected` and never runs.
- "Выйти на этом Mac" is not offered (state is disconnected) and `logout()` only deletes when `session != nil`, so the ghu_/ghr_ pair stays in Keychain indefinitely — contradicting the design ("Выйти на этом Mac удаляет локальные токены") and the task's "login/logout with Keychain".
Required: a restore path (e.g. Effect `.restoreSession` at startup that loads the Keychain record for the persisted server/user identity, validates via `/user` or 401 → relogin, and sets `session`), driven by a named Flow test, plus logout after restore proving Keychain deletion. Persisting the non-secret identity (serverHost, userID, clientID) is needed for the lookup; it must not carry the tokens.

### F2 — AC row "refresh concurrency" is driven only at the helper, not at the production call site
The outcome names `GitHubTokenRefresh.refresh` as the call site, but the production caller is `GitHubAuth.Flow.currentToken()` → `refresher.refresh`. No test creates an expiring token and drives `.refreshInstallations`/`.selectInstallation` through it; mutant R1 (Flow never refreshes) survives. Shape: helper unit-tested, production path uncalled by any test. Required: a named Flow test with `expiresAt` inside the 60 s window that observes one refresh request via `TestTransport.requests`, plus the 401/`invalid_grant`-on-refresh → `.relogin` branch through `refreshInstallations`. Coalescing of two concurrent Flow callers (`refreshInstallations` + `selectInstallation`) should be asserted at that level too.

### F3 — "No PAT fallback" gate is narrowed on the refresh path without a failing test
`PATGuard.validate` has three production call sites (device poll, API client, token refresh). Only the first two have negative tests; mutant R2 survives. Required: a named test that feeds `{"access_token":"github_pat_..."}` to the refresh response and expects `.patNotSupported` with no Keychain save.

### F4 — `auditNoSecrets` and `Redaction.sanitize` have zero production callers
`grep` over `Packages/RunnerControlCore/Sources` and `Targets/RunnerControl/Sources`: neither is invoked outside tests. The outcome claims "no secrets in state/logs (Keychain + Redaction + audit)"; M7/M8 prove only that the helpers compile and behave when called. Shape: check present but uncalled from production. Required: call `auditNoSecrets(in: bundle.infoDictionary)` from `AppConfig.current` (fail closed) with a test that drives it through `current(bundle:)`, and either wire `Redaction.sanitize` into the diagnostics path that exists or record it as an explicitly stated bound for the diagnostics slice.

### F5 — Public client ID binding left empty and `Project.swift` not converged (required rework, per coordinator directive)
`ios-app-manager.json` gains `GitHubAppClientID: ""` but `Project.swift` was not regenerated (`ios-app-manager` is not installed in this environment; I could not run it either). The composed plist therefore has no key; behaviourally identical to the empty placeholder, and `configReportsExactMissingBinding` proves the exact binding message. Required in the next revision (coordinator directive on this run): the public binding (client ID `Iv23ligBUam7vZitsE1G`, slug `relux-runner-control`, attached as `github-app-public-binding.md`) must become the product default in `ios-app-manager.json` → `macos.info_plist.GitHubAppClientID`, `Project.swift` regenerated via `ios-app-manager generate macos-app` (never hand-edited), and the Release build rerun so the composed `Info.plist` carries the key. Only the public client ID and slug are embedded; no secret or private key. Installation IDs and accounts stay smoke fixtures, never hardcoded. Without this, AC row 2 (real login UI drives production services) cannot be exercised end to end, and the missing binding is not an external blocker.

## Accepted as-is
- Device Flow transport: body-error handling on HTTP 200, `slow_down` +5 s, expiry deadline, denied/expired → newCode. Tests named and mutants kill.
- Cancellation: generation + Task.cancel + `deviceCode=nil`; survivor bounds M9/M9c are honest.
- Logout (in-session): Keychain delete + sweep; background refresh no-op after logout.
- 401 → relogin, 403 → `syncFailed` with `.connected` preserved (reducer proof included). Local Runners state untouched by GitHub actions.
- No PAT UI, no `gh` import, no secrets in `GitHubAuth.State`/actions; `RuntimeLogger` logs action type only.
- Management window composition (Container → Page, production effects), menu keeps existing controls plus "Раннеры и настройки…"; `.spec/` materialized with registration and removal.
- Generator input only; `Project.swift`/`Package.swift` not hand-edited.

## AC-row status after review
9 of 11 rows driven by the producer; of those, row 6 (refresh concurrency) is downgraded to helper-only, and row 10 (no PAT) is partial on the refresh path. F1 is a functional gap not enumerated in the AC row list but inside "login/logout with Keychain" scope. Rows 1 and 11 remain stated bounds (build verified by me; menu UI manual).
