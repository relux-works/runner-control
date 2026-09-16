# TASK-260916-304bw2 — R4 immutable authority rework (developer outcome)

Status: ready for review (board `to-review`).

Revision 4 adopts the three exact rev3 reviewer probes as maintained
production-entry regressions and fixes R3-F1–F3 at the root cause with two
coherent immutable boundaries: a unique login incarnation shared through
production auth/session composition, and an immutable Load-time editor
authority consumed by Apply. Prior mutable account/catalog comparisons are
replaced, not patched. Accepted registration/global installer lease,
stopped-only unregister, distinct service identities, fail-closed
persistence, corrected real login policy, and the existing repository
editor are preserved. No production runner was stopped, re-registered, or
interrupted; the candidate is left UNCOMMITTED in the Story worktree.

## Fixes by finding

### R3-F1 — immutable editor authority, relink bound to full identity
- `Runners.EditorAuthority` (new): immutable server/scope/agentID/agentName/
  canonical/localID tuple captured at Load, carried in `GroupAccess`.
- `Runners.Flow.loadGroupAccess`: stores the authority on success, clears
  the invalidated flag, publishes access with authority.
- `Runners.Flow.applyGroupAccess`: when a Load established an editor, consumes
  that tuple via `consumeStoredEditorAuthority` and refuses on any mismatch
  (server, scope, agent, name, canonical, localID) with an explicit
  invalidation requiring a new Load — never reconstructs authority from the
  mutable current catalog. A direct Apply without a prior Load establishes
  its own single-write start authority (session probes stay non-vacuous).
- `Runners.Flow.relink`: now requires the full original server/scope/agent
  identity (same-ID different-scope/host refuses with drift naming); any
  successful move changes canonical and invalidates the editor; any
  mismatch refusal also invalidates, so a later Apply without a fresh Load
  refuses instead of falling back to current values (`editorInvalidated`).
- `Runners.Action.groupAccessInvalidated` + reducer: clears the stale group
  so the UI returns to an explicit Load instead of submitting a retained ID.
- `removeFromApp` clears both stored authority and the invalidated flag.

### R3-F2/R3-F3 — login incarnation across Load/Apply/unregister
- `GitHubSessionIdentity.sessionIncarnation` (new, optional, Codable-
  compatible): fresh UUID on every successful Device Flow login, preserved
  on restore when the user is unchanged (legacy nil stays nil), deleted on
  logout, never touched by token refresh.
- `RunnerRuntime.make`: passes the same identities store instance to
  `GitHubAuth.Flow`, so the incarnation is shared through production
  composition, not just the UserDefaults key.
- `Runners.Flow.sessionStill`: now requires userID + normalized serverHost
  + incarnation equality. Logout, account/server switch, and logout +
  same-account re-login all invalidate; ordinary refresh stays valid.
- Applied at every async boundary: Apply pre-PUT/PUT-boundary/post-PUT/
  pre-publish/error, Load pre-fetch/repos-fetch/pre-publish/error,
  unregister post-token/boundary/error, and `refreshRemote` per-scope
  (now via `sessionStill`, replacing manual userID/server checks).
- Invalidated attempts stop silently (no writes into the new incarnation);
  unregister still guarantees its epilogue so retry proceeds.

## Production call sites

| Fix | Call site |
|---|---|
| R3-F1 | `Runners.Flow.apply(.loadGroupAccess)` → store `EditorAuthority` → `Runners.Flow.apply(.applyGroupAccess)` → `editorRequiresReload`/`consumeStoredEditorAuthority` → `GitHubRunnerAPIClient.setGroupRepositories`; `Runners.Flow.apply(.relinkDirectory)` → full-identity gate → `invalidateEditor` |
| R3-F2 | `Runners.Flow.apply(.applyGroupAccess/.loadGroupAccess)` → `sessionStill` (incarnation) at fetch/PUT/confirm/publish/error → `fetchGroupRepositories`/`groupAccessLoaded` |
| R3-F3 | `Runners.Flow.apply(.unregister)` → `runUnregister` post-token + boundary `sessionStill` (incarnation) → `RunnerInstallerService.unregister` |

## Tests: 8 new, 224 total green

Adopted probes (failed exit 1 with 5 assertion failures on rev3, pass now):
`reviewR3SameAccountReloginDuringPutMustNotPublishAccess`,
`reviewR3SameAccountReloginDuringRemoveTokenMustRefuseSideEffect`,
`reviewR3RelinkMustNotRebindLoadedEditorToOtherOrg`.

New bounds: `reviewR3SiblingLoadDuringReloginMustNotPublishAccess` (sibling
Load with real relogin), `applySucceedsAfterTokenRefreshWithinSameLogin`
(positive refresh control), `unregisterRetryInNewIncarnationSucceeds`
(retry in new session), `relinkRefusesChangedScopeAndRequiresReload`
(refusal + invalidated + Load recovery to original),
`relinkSameIdentityMoveRequiresReload` (move invalidates + recovery).

AC coverage: 18 of 19 named rows driven through production entry points
(row 18, full UI paths, remains the stated manual-UI bound; no UI tests
per task). Findings touched rows 11/16 and the async/session contract.

## Mutant evidence: 4 narrowing, 0 survivors

Tree reverted after each run (grep-verified clean, backup diff identical);
focused suite re-run green afterwards. Each mutant keeps the gate present
and weakens it to admit exactly one rejected subclass; a retained-gate
control still passes.

| Mutant | Narrows the gate to | Named failing test | Exit |
|---|---|---|---|
| `relink-admits-scope-drift` | Relink keeps host + agent checks, drops scope-vs-original | `relinkRefusesChangedScopeAndRequiresReload` (4 issues: catalog rewritten, PUT to other-org); `relinkRequiresSameAgent` still passes | 1 |
| `apply-completion-admits-relogin` | Apply keeps pre-PUT incarnation checks, admits renewed same-account session at post-PUT + pre-publish | `reviewR3SameAccountReloginDuringPutMustNotPublishAccess` (2 issues: published + 4th request); `applyGroupAccessStopsWhenSessionChangesMidApply` still passes | 1 |
| `unregister-admits-relogin` | Unregister keeps stopped + local-identity gates, admits renewed same-account session at post-token + boundary | `reviewR3SameAccountReloginDuringRemoveTokenMustRefuseSideEffect` (2 issues: installer ran + ID cleared); `unregisterRefusesRunningService` + `unregisterRevalidatesStoppedAtSideEffectBoundary` still pass | 1 |
| `load-completion-admits-relogin` | Load keeps membership verification, admits renewed same-account session at repos fetch + publication | `reviewR3SiblingLoadDuringReloginMustNotPublishAccess` (2 issues: published + 3rd request); `loadGroupAccessStopsPublishingAfterMidLoadLogout` still passes | 1 |

No survivors. No delete-only rows claimed as narrowing.

## Validation (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` → exit 0, 224
  tests passed (216 R3 + 8 R4), re-run green after mutant reverts.
- `python3 -m unittest discover -s Scripts/tests` → exit 0, 62 tests OK
  (release machinery untouched).
- `./Scripts/build.sh` → exit 0, `BUILD SUCCEEDED`;
  `codesign --verify --deep --strict` → exit 0;
  `1.2.0`, `works.relux.runnercontrol`, team `262RZ595FP`, fresh
  candidate in `.temp/products/`.
- No configured linter (no SwiftLint config); build shows only the
  pre-existing pattern, none in changed files.
- Production (read-only): `macbook-iv` service `state = running`,
  exactly one `runsvc.sh` + one `Runner.Listener` per runner
  (macbook-iv, cocoaskills); no `actions.runner.*` in
  `~/Library/LaunchAgents` (manual external login OFF preserved).

## Stated bounds

- UI confirmation paths are manual (root CUA on the fresh candidate; no
  UI tests per task). The production Flow gates behind them are covered.
- An in-flight membership page loop may finish its current read after a
  mid-loop login replacement; no write, confirmation read, or publication
  follows (next read uses the old token against fake HTTP in tests, 401s
  in production, and the error completion is suppressed by incarnation).
- Catalog entries without a recorded server/scope predate the original
  binding and rely on disk-vs-session checks for relink; the immutable
  editor still binds canonical/localID/agent on every Load/Apply.
- Concurrent wizard + catalog edits to the same group remain
  last-write-wins (rev1 bound, unchanged).
- A remove token minted just before a session invalidation expires
  unused; the refused side effect is `config.sh remove` (proven
  installer-idle).
