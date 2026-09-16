# TASK-260916-304bw2 — R5 final boundary and cleanup (developer outcome)

Status: ready for review (board `to-review`).

Revision 5 repairs the two concrete residual defects from rev4 and nothing
else. It adopts both exact rev4 reviewer probes as maintained
production-entry regressions, enforces the initiating-session authority
after the final stopped inspection AND at the actual installer mutation
boundary, and gives Load/Apply owner/generation-bound cleanup that
releases the busy state on invalidation without letting an old operation
clear a newer one. Accepted R4 incarnation/editor-identity fixes,
installer-wide lease, stopped-only unregister, distinct service
identities, fail-closed persistence, corrected real login policy, and the
repository editor are preserved. No production runner was stopped,
re-registered, or interrupted; the candidate is left UNCOMMITTED in the
Story worktree.

## Fixes by finding

### R4-F1 — initiating-session authority through the final inspection
- `Runners.Flow.runUnregister`: after the final `requireConfirmedStopped`
  (which awaits production launchctl), re-checks catalog generation and
  `sessionStill(startedIdentity)` before invoking the installer.
- `RunnerInstallerService.unregister(directory:removeToken:sessionAuthority:)`:
  new optional authority closure, enforced after the installer-wide lease
  is held and immediately before `config.sh remove` begins. On failure it
  throws the new `RegistrationError.sessionInvalidated`; the lease
  releases via `defer`, the Flow catch suppresses publication (session
  changed), and the unregister epilogue releases the operation state so an
  explicit retry stays possible.
- `Runners.Flow.sessionMatches` (new, nonisolated): pure incarnation
  comparison shared by `sessionStill` and the installer-boundary closure,
  so both enforce identical authority without capturing the Flow actor.

### R4-F2 — owner/generation-bound Load/Apply cleanup
- `Runners.Flow.groupAccessGeneration` (new): every Load/Apply takes the
  next per-editor operation number before publishing its loading state.
- `publishGroupAccessIfCurrent`: success/error/invalidation publications
  land only when the operation still owns the editor; a superseded
  completion publishes nothing — no cleared busy state, no stale data.
- `releaseGroupAccessAfterSessionChange`: session invalidation publishes
  an explicit retry message ("GitHub session changed during group
  access. Reload group access to retry in the current session.") instead
  of wedging on a spinner. Applied at every session guard and in the
  error path's session-changed branch, in both Load and Apply.
- `abandonGroupAccessAfterCatalogChange`: catalog-stale completions
  release only when the entry still exists and no explicit invalidation
  already released it (removal prunes; relink invalidates).
- `removeFromApp`/`relink` drop the editor's operation ownership, so an
  in-flight op can neither publish into nor release the editor after the
  entry is removed or relinked (covers the remove-then-re-add edge).
- `consumeStoredEditorAuthority` takes the operation and gates its
  mismatch invalidation on ownership.

## Production call sites

| Fix | Call site |
|---|---|
| R4-F1 | `Runners.Flow.apply(.unregister)` → `runUnregister` post-final-inspection `sessionStill` → `RunnerInstallerService.unregister(sessionAuthority:)` before `config.sh remove` |
| R4-F2 | `Runners.Flow.apply(.loadGroupAccess/.applyGroupAccess)` → `beginGroupAccessOperation` → `release/abandon/publish…IfCurrent` → `Runners.Action.groupAccessFailed/Loaded` |

## Tests: 5 new + 2 adopted probes (6 scenarios), 229 total green

Adopted probes (failed exit 1 with 4 issues on rev4, pass now):
`reviewR4LogoutDuringFinalStoppedInspectionMustRefuseRemoval`,
`reviewR4SessionInvalidationMustReleaseEditorLoading(apply:)` (both cases).

New bounds:
`unregisterRefusesLogoutBetweenFinalInspectionAndConfigRemove`
(installer-boundary refusal via deterministic flip order + same-Flow
retry succeeds), `editorOverlappingLoadSuppressesStaleCompletion`
(latched same-Flow overlap, stale completion suppressed, newer data
intact, through the production reducer + refresh),
`editorRetryAfterSessionInvalidationSucceedsOnSameFlow` (released editor
retried in the new session on the same Flow, through the reducer).

Updated contract (4 tests): session-invalidated Load/Apply now publishes
the named cleanup message instead of staying silent —
`applyGroupAccessStopsWhenSessionChangesMidApply`,
`applyGroupAccessStopsWhenServerSwitchesMidApply`,
`loadGroupAccessStopsPublishingAfterMidLoadLogout`,
`reviewR3SiblingLoadDuringReloginMustNotPublishAccess`. Safety assertions
(no PUT, no Loaded, exact request counts) are unchanged; only the
wedging `error == nil` expectation became the explicit-cleanup assertion.

Existing positive/new-session controls reused and green:
`unregisterRemovesRemoteKeepsFilesAndEntry`,
`unregisterRetryInNewIncarnationSucceeds`,
`unregisterReleasesOperationStateAfterSessionLoss`,
`applySucceedsAfterTokenRefreshWithinSameLogin`.

AC coverage: 18 of 19 named rows driven through production entry points
(unchanged from R4; row 18, full UI paths, remains the stated manual-UI
bound — no UI tests per task). R5 findings touched rows 11/16 and the
async ownership/retry contract.

## Mutant evidence: 3 narrowing, 0 survivors

Tree reverted after each run (diff-verified byte-identical to the
pre-mutant backup); focused suite re-run green afterwards. Each mutant
keeps the gate present and weakens it to admit exactly one rejected
subclass; a retained-gate control still passes in the same run.

| Mutant | Narrows the gate to | Named failing test | Exit |
|---|---|---|---|
| `unregister-admits-final-inspection-invalidation` | Unregister keeps pre-inspection/token/stopped gates, admits session invalidation between final stopped inspection and config.sh remove (Flow post-inspection check + installer enforcement omitted) | `reviewR4LogoutDuringFinalStoppedInspectionMustRefuseRemoval` (2 issues: installer ran + ID cleared); `unregisterRefusesLogoutBetweenFinalInspectionAndConfigRemove` (3 issues); `unregisterRefusesRunningService`, `unregisterRevalidatesStoppedAtSideEffectBoundary`, `unregisterRemovesRemoteKeepsFilesAndEntry` still pass | 1 |
| `load-omits-invalidation-cleanup` | Load keeps success/error publication + ownership gating + Apply cleanup, omits session-invalidation cleanup on Load (3 guards + error branch) | `reviewR4SessionInvalidationMustReleaseEditorLoading(apply:false)` (loading stuck); `loadGroupAccessStopsPublishingAfterMidLoadLogout` (no cleanup); F2(apply:true) + `reviewR3SameAccountReloginDuringPut` still pass | 1 |
| `apply-omits-invalidation-cleanup` | Apply keeps success/error publication + ownership gating + Load cleanup, omits session-invalidation cleanup on Apply (4 guards + error branch) | `reviewR4SessionInvalidationMustReleaseEditorLoading(apply:true)` (loading stuck); `applyGroupAccessStopsWhenSessionChangesMidApply` (no cleanup); F2(apply:false) + `reviewR3SiblingLoad` still pass | 1 |

No survivors. No delete-only rows claimed as narrowing.

## Validation (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` → exit 0, 229
  tests passed (224 R4 + 5 R5), re-run green after mutant reverts. One
  earlier full run showed a single non-reproducing issue; three
  consecutive full runs since are green, and the three new tests pass 3/3
  in isolation.
- `python3 -m unittest discover -s Scripts/tests` → exit 0, 62 tests OK
  (release machinery untouched).
- `./Scripts/build.sh` → exit 0, `BUILD SUCCEEDED`;
  `codesign --verify --deep --strict` → exit 0;
  `1.2.0`, `works.relux.runnercontrol`, TeamIdentifier `262RZ595FP`,
  fresh candidate in `.temp/products/` (signed 2026-09-16 15:37 UTC).
- No configured linter (no SwiftLint config); build shows no new
  warnings in changed files.
- Production (read-only): both runners live (exactly one `runsvc.sh` +
  one `Runner.Listener` each for macbook-iv and cocoaskills); no
  `actions.runner.*` in `~/Library/LaunchAgents` (manual external login
  OFF preserved). No production state changed.

## Stated bounds

- UI confirmation paths are manual (root CUA on the fresh candidate; no
  UI tests per task). The production Flow gates behind them are covered.
- Overlap ownership is per Flow instance; production composes exactly one
  `Runners.Flow` per runtime, so cross-Flow overlap cannot arise outside
  tests that deliberately build two Flows.
- An in-flight membership page loop may finish its current read after a
  mid-loop login replacement; no write, confirmation read, or publication
  follows (R4 bound, unchanged).
- A remove token minted just before a session invalidation expires
  unused; the refused side effect is `config.sh remove` (proven
  installer-idle, now at two boundary points).
- Catalog entries without a recorded server/scope predate the original
  binding and rely on disk-vs-session checks for relink (R4 bound,
  unchanged).
