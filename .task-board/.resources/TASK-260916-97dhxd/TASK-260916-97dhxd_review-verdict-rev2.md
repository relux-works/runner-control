# TASK-260916-97dhxd — review verdict, CR-TASK-260916-97dhxd-2 revision 2

Verdict: **changes_requested → to-dev**
repeat-of: none (new class; F1–F5 from rev1 are resolved, see below)

Candidate tree 031c7f782535f39d66df41eb39d0126d6a9673fa (base 7d2126ae). Story worktree re-hashed to the same tree OID before and after review; worktree untouched (all mutants/attacks ran in a scratch copy).

## What I reran myself (not carried over)

- `swift test --package-path Packages/RunnerControlCore` → 56 tests passed, exit 0.
- `./Scripts/build.sh` (tuist generate + Release xcodebuild + `codesign --verify --deep --strict`) → BUILD SUCCEEDED, exit 0.
- Composed `RunnerControl.app/Contents/Info.plist`: `GitHubAppClientID=Iv23ligBUam7vZitsE1G`, `GitHubAppSlug=relux-runner-control`, `CFBundleShortVersionString=1.2.0`; no key matching secret/private/token. Binary strings carry no `ghu_`/`ghr_`/`ghp_`/`github_pat_`/`client_secret`/PRIVATE KEY material beyond the two PATGuard prefix literals.
- Generator reproducibility: ran `ios-app-manager generate macos-app` in a scratch copy → `Project.swift` byte-identical to the candidate. Not hand-edited.
- Producer rev2 mutant log (R1, R2, N1, N2, N3, W1, L1): each is a genuine narrowing mutant with a named failing test and exit 1. Accepted.
- Reviewer attack tests (file attached as `TASK-260916-97dhxd_reviewer-attack-tests-rev2.swift`, run in scratch copy): **3 of 3 FAILED against the candidate** — see F6.

## Rev1 findings — status

- F1 session restore: RESOLVED. `restoreSession` + identity store + `AppRegistry.start()` dispatch; logout reaches persisted stores via identity. Driven by named Flow tests; N1/N2 kill.
- F2 refresh concurrency at production call site: RESOLVED. `flowRefreshInstallationsRefreshesExpiringTokenViaProductionPath`, `flowConcurrentRefreshAndSelectCoalesceToSingleRefresh`, `flowRefreshInstallationsWithInvalidGrantDuringRefreshRequiresRelogin` drive `Flow.currentToken()`; R1/N3 kill.
- F3 PAT guard on refresh path: RESOLVED. `refreshRejectsFineGrainedPATWithoutSaving`; R2 kills.
- F4 audit wiring: RESOLVED. `AppConfig.current(bundle:)` calls `auditNoSecrets` fail-closed, `configAuditRunsThroughCurrentBundle` drives it; W1 kills. `Redaction.sanitize` stated bound accepted (no diagnostics export in this slice; RuntimeLogger logs action type only).
- F5 public binding: RESOLVED. Verified in composed plist and regen (above).

## New findings

### F6 — Logout does not cancel in-flight restore/refresh; restore revives a logged-out session (correctness, blocks acceptance)
Class: "logout отменяет фоновые операции" (design §9, additional criteria) / AC row "logout covered". `logout()` bumps `generation` and cancels only `pollTask`. `restoreSession()`, `restoreInstallations()`, `refreshInstallations()` and `selectInstallation()` never re-check `generation` (or `session`) after their `await`s, so a logout or a new login that interleaves with a network call is silently undone by the continuation.

Reproduced with a delaying transport (`SlowTransport`, 150–300 ms), all three fail on the candidate:
- **RA1 `reviewerLogoutDuringRestoreDoesNotReviveSession`**: restore awaiting `/user`, logout arrives. Observed sequence `restoreStarted, loggedOut, accountVerified, installationsLoaded, connected`. After logout the Flow has a live `session`, the identity store is **re-saved** (`identities.load() != nil`), UI shows "Подключено как @octo", and a subsequent `refreshInstallations` reaches the network. Keychain tokens are gone, so the next 30 s tick produces "Session was revoked. Sign in again." — the user's logout is reversed and then reported as a revocation.
- **RA2 `reviewerLogoutDuringRefreshDoesNotEmitSyncAfterLoggedOut`**: refresh awaiting `/user/installations`, logout arrives. Observed `…connected, loggedOut, installationsLoaded, syncSucceeded`: installations and `lastSyncAt` repopulate the disconnected state. Realistic window: every 30 s tick × network latency.
- **RA3 `reviewerLoginDuringRestoreIsNotClobberedByRestore`**: user presses "Войти через GitHub" while startup restore is in flight; restore's `.connected` lands after `codeReceived` and replaces the device-code screen while the poll keeps running.

The existing `flowLogoutClearsKeychainAndStopsSync` only checks a refresh dispatched *after* logout (`session == nil` guard) — positive-path for the sequential case; the interleaved class is unchecked.

Required: capture `generation` at entry of `restoreSession`, `restoreInstallations`, `refreshInstallations`, `selectInstallation` (and `currentToken`), and after every `await` guard `generation == gen` before mutating `session`, saving identity, or dispatching. Add the three attached tests (or equivalents named in the outcome) as committed regression tests, plus one narrowing mutant for this class (e.g. keep the guard in `restoreSession` but drop it only after `fetchUser`, so RA1 must fail). Because this is a first finding of its class, `repeat-of: none`; if it recurs, the next revision must carry the named regression test and mutant per the two-consecutive rule.

### F7 — "Lint 0 serious" does not reproduce (reported-fact finding, secondary)
`swiftlint lint` with the repo's default configuration (no `.swiftlint.yml` present) reports 38 `error`-level violations inside candidate files: `GitHubTransport.swift` snake_case DTO properties (`client_id`, `device_code`, `access_token`, …, plus `k`/`v` and one 209-char line) and `GitHubAuth+State+Reducer.swift` `reduce` cyclomatic complexity 21. The outcome claims "lint 0 serious" on 6 touched files; the reducer and transport files are part of the candidate. Either add `CodingKeys`/a checked-in `.swiftlint.yml` that documents the DTO exception, or state the exact bound with the count. Do not report a lint gate as clean when the tool reports errors.

### Minor (not blocking, fix alongside F6 if cheap)
- `selectInstallation`: `currentToken()` throwing `.revoked/.unauthorized/.tokenRefreshFailed` yields `syncFailed` while `refreshInstallations` yields `.failed(relogin)` for the same class; inconsistent user outcome for a revoked session.
- `restoreSession`: a non-auth refresh failure (5xx/rate-limit on the token endpoint) followed by a 401 on `/user` with the expired access token deletes the still-valid refresh token. Consider treating a 401 right after an *unrefreshed expiring* token as "retry later", not revoke.
- `UserDefaultsGitHubSessionIdentityStore` (production adapter) has no round-trip test; only the in-memory store is exercised.

## Accepted as-is
Device Flow transport and error mapping; cancellation (poll generation, code destroyed); 401→relogin / 403→stale with `.connected` preserved; no PAT UI, no `gh` import, PATGuard on all three call sites with negative tests; tokens absent from `GitHubAuth.State`/actions/logs; Keychain scoping and sweep; management window Container→Page composition dispatching production effects; menu keeps existing controls plus the settings entry; `.spec/` materialized with registration and removal in scope; generator-owned `Project.swift`.

## AC-row status after review
Producer table: 9 of 11 rows driven (rows 1 and 11 are stated bounds; row 1 build verified by me, row 11 menu wiring is manual/no UI tests). Row 7 (logout) is downgraded: driven for the sequential case only; the interleaved class fails (F6). All other driven rows hold under my reruns and the producer mutants.
