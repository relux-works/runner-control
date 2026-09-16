# TASK-260916-304bw2 — R3 session-and-editor-binding rework (developer outcome)

Status: ready for review (board `to-review`).

Revision 3 adopts the three exact rev2 reviewer probes as maintained
production-entry regressions and fixes R2-F1–F3 at the root cause with one
coherent immutable operation/session ownership boundary: every mutating
catalog operation captures the catalog generation plus the initiating
GitHub session once, and re-checks both at every asynchronous boundary
through confirmation and publication — never only before the side effect.
Accepted registration/global installer lease, stopped-only unregister,
distinct service identities, fail-closed persistence, corrected real login
policy, and the existing repository editor are preserved. No production
runner was stopped, re-registered, or interrupted; the candidate is left
UNCOMMITTED in the Story worktree for handoff snapshot.

## Fixes by finding

### R2-F1 — editor/write authority bound to the catalog original
- `Runners.Flow.verifiedOrgRunner` (extended): the mutable on-disk
  registration must still agree with the server host and org scope
  recorded at import (or explicit relink). A same-host scope edit on disk
  without re-verification refuses with a message naming both scopes,
  instead of silently retargeting another org's group.
- Load and Apply both verify here, so neither path can drift off the
  catalog original between Load and Apply; `bindApplyIdentity` keeps
  guarding across awaits within Apply. Entries without a recorded
  server/scope predate the binding and fall through to the unchanged
  disk-vs-session checks (stated bound).
- Explicit re-verification path: remove + re-add (or relink of a moved
  folder) rebinds the original; proven by
  `scopeEditThenReAddReverifiesGroupApply`, which then PUTs to
  `orgs/other-org/` only.

### R2-F2 — session ownership carried through completion (Apply + Load)
- `Runners.Flow.applyGroupAccess`: after the PUT, a logout/account/server
  switch refuses the confirmation read and any `groupAccessLoaded`
  publication (the already-issued PUT is not pretended undoable).
- `Runners.Flow.loadGroupAccess` (sibling completion): the same ownership
  guards sit before the repository fetch and before publication.
- Error completions in both paths publish only when the starting session
  still holds; mid-operation session loss stops silently, matching the
  existing pre-PUT and `refreshRemote` shape. Never-authenticated
  callers still get their `notAuthenticated` failure (started=nil,
  current=nil still owns).

### R2-F3 — unregister bound to the initiating session, state always released
- `Runners.Flow.runUnregister` (new, split from `unregister`): captures
  the initiating session once; a logout/account/server switch after
  token acquisition — and again at the side-effect boundary — invalidates
  the unstarted `config.sh remove` (minted token expires unused) while
  the stopped and local-identity gates stay intact.
- Local bookkeeping after a *completed* side effect still runs: a remote
  removal that already happened is real even if the session changed
  under the installer lease, and no cancellation undoes it.
- The split guarantees the epilogue: every early return still clears
  `unregisterWorking` and publishes `unregistering(id, false)`, so an
  invalidated attempt never wedges the UI and a retry proceeds (this
  also repairs the latent wedge on the pre-existing catalog-stale early
  returns). Proven by `unregisterReleasesOperationStateAfterSessionLoss`.

## Production call sites

| Fix | Call site |
|---|---|
| R2-F1 | `Runners.Flow.apply(.applyGroupAccess/.loadGroupAccess)` → `verifiedOrgRunner` catalog-original check → `GitHubRunnerAPIClient.setGroupRepositories` |
| R2-F2 | `Runners.Flow.apply(.applyGroupAccess)` → `sessionStill` post-PUT + pre-publish → `fetchGroupRepositories` / `groupAccessLoaded`; same in `loadGroupAccess` |
| R2-F3 | `Runners.Flow.apply(.unregister)` → `runUnregister` post-token + boundary `sessionStill` → `RunnerInstallerService.unregister` |

## Tests: 6 new, 216 total green

Adopted probes (failed exit 1 with 5 assertion failures on rev2, pass now):
`reviewR2ScopeEditAfterLoadMustNotRetargetApply`,
`reviewR2LogoutDuringPutMustNotPublishAccess`,
`reviewR2LogoutDuringRemoveTokenMustRefuseSideEffect`.

New bounds: `loadGroupAccessStopsPublishingAfterMidLoadLogout` (sibling
Load completion), `unregisterReleasesOperationStateAfterSessionLoss`
(retry after invalidation), `scopeEditThenReAddReverifiesGroupApply`
(refusal names drift + explicit re-verification PUTs to the new org only).

AC coverage: 18 of 19 named rows driven through production entry points
(row 18, full UI paths, remains the stated manual-UI bound; no UI tests
per task). Findings touched rows 11/16 and the async/session contract.

## Mutant evidence: 4 narrowing, 0 survivors

Tree reverted after each run (grep-verified clean); full suite re-run
green afterwards. Each mutant keeps the gate present and weakens it to
admit exactly one rejected subclass; a retained-gate control still passes.

| Mutant | Narrows the gate to | Named failing test | Exit |
|---|---|---|---|
| `verify-admits-scope-drift` | Catalog binding keeps host + agent checks, drops scope-vs-original | `reviewR2ScopeEditAfterLoadMustNotRetargetApply` (PUT emitted); `reviewCrossServerGroupApplyMustRefuse` still passes | 1 |
| `apply-completion-admits-logout` | Session ownership keeps pre-PUT checks, admits post-PUT logout at confirmation + publication | `reviewR2LogoutDuringPutMustNotPublishAccess` (2 issues: published + 4th request); `applyGroupAccessStopsWhenSessionChangesMidApply` still passes | 1 |
| `unregister-admits-post-token-logout` | Unregister keeps stopped + local-identity gates, admits post-token logout at both session points | `reviewR2LogoutDuringRemoveTokenMustRefuseSideEffect` (2 issues: installer ran + ID cleared); `unregisterRefusesRunningService` + `unregisterRevalidatesStoppedAtSideEffectBoundary` still pass | 1 |
| `load-completion-admits-logout` | Load keeps membership verification, admits mid-Load logout at repos fetch + publication | `loadGroupAccessStopsPublishingAfterMidLoadLogout` (2 issues); `groupAccessUsesFreshAPIMembershipNotStalePool` still passes | 1 |

No survivors. No delete-only rows claimed as narrowing.

## Validation (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` → exit 0, 216
  tests passed (210 R2 + 6 R3), re-run green after mutant reverts.
- `python3 -m unittest discover -s Scripts/tests` → exit 0, 62 tests OK
  (release machinery untouched).
- `./Scripts/build.sh` → exit 0, `BUILD SUCCEEDED`;
  `codesign --verify --deep --strict` → exit 0 (inside build.sh);
  `1.2.0`, `works.relux.runnercontrol`, team `262RZ595FP`, fresh
  candidate in `.temp/products/`.
- No configured linter (no SwiftLint config); build shows only the
  pre-existing Sendable-closure warnings pattern, none in changed files.
- Production (read-only): `macbook-iv` service `state = running`,
  exactly one `runsvc.sh` + one `Runner.Listener` per runner
  (macbook-iv, cocoaskills); no `actions.runner.*` in
  `~/Library/LaunchAgents` (manual external login OFF preserved).

## Stated bounds

- UI confirmation paths are manual (root CUA on the fresh candidate; no
  UI tests per task). The production Flow gates behind them are covered.
- An in-flight membership page loop may finish its current read after a
  mid-loop logout; no write, confirmation read, or publication follows
  (in production the next read 401s and the error completion is
  suppressed by the same ownership check).
- Catalog entries without a recorded server/scope predate the R2-F1
  binding and rely on the disk-vs-session checks.
- Concurrent wizard + catalog edits to the same group remain
  last-write-wins (rev1 bound, unchanged).
- A remove token minted just before a session invalidation expires
  unused; the refused side effect is `config.sh remove` (proven
  installer-idle).
