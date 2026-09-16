# TASK-260916-304bw2 — R6 non-reusable editor operation ownership (developer outcome)

Status: ready for review (board `to-review`).

Revision 6 repairs the single bounded finding R5-F1 and nothing else.
It replaces the reusable per-ID integer operation counter with a unique
operation identity (UUID) that cannot reset on remove/relink/re-import,
and re-checks ownership after the cleanup catalog read before any
publication. Accepted R4 incarnation/editor-identity fixes, R5 final
session-authority boundary and owner-bound cleanup, installer-wide lease,
stopped-only unregister, corrected real login policy, and the repository
editor are preserved. No production runner was stopped, re-registered,
or interrupted; the candidate is left UNCOMMITTED in the Story worktree.

## Fix

- `Runners.Flow.groupAccessOwner: [String: UUID]` replaces
  `groupAccessGeneration: [String: Int]`. Every Load/Apply mints a fresh
  `UUID()` in `beginGroupAccessOperation`; `ownsGroupAccess` compares
  UUID equality.
- `dropGroupAccessOwnership` deletes the entry without resetting any
  counter; the next operation after re-import mints a new UUID the
  in-flight predecessor cannot equal. No wrap, no cross-editor alias.
- `abandonGroupAccessAfterCatalogChange` re-checks `ownsGroupAccess`
  after `await catalog.load()` before publishing, so a newer Load/Apply
  that took ownership during the read is never cleared by a stale
  catalog-change error.
- Signatures updated consistently: `begin/owns/publish/release/abandon/
  consumeStoredEditorAuthority` all carry `UUID`; no other behavior
  changed.

## Production call site

`Runners.Flow.apply(.loadGroupAccess/.applyGroupAccess)` →
`beginGroupAccessOperation` → `ownsGroupAccess` /
`release/abandon/publish…IfCurrent` → `Runners.Action.groupAccess*`;
remove/relink → `dropGroupAccessOwnership`.

## Tests: 1 adopted probe, 230 total green

Adopted exact rev5 probe (failed exit 1 with 2 issues on rev5, passes
now): `reviewR5RemoveReimportMustNotReviveOldEditorOwner` — holds first
Load at HTTP, `removeFromApp` + `importFolder` same runner, starts and
holds second Load, releases only first, feeds actions through the actual
`Runners.State` reducer; asserts newer Load keeps `loading=true` with
`error=nil`.

Retained ordinary-overlap and same-Flow retry controls, all green on
the fixed candidate:
`editorOverlappingLoadSuppressesStaleCompletion`,
`editorRetryAfterSessionInvalidationSucceedsOnSameFlow`,
`reviewR4SessionInvalidationMustReleaseEditorLoading(apply:)` both
cases, `reviewR4LogoutDuringFinalStoppedInspectionMustRefuseRemoval`.

AC coverage: 18 of 19 named rows driven through production entry points
(unchanged from R5; row 18, full UI paths, remains the stated manual-UI
bound — no UI tests per task). R6 touched the async ownership contract
only.

## Mutant evidence: 1 narrowing, 0 survivors

Tree reverted after the run (shasum-verified byte-identical to the
pre-mutant backup); focused suite re-run green afterwards. The mutant
keeps the gate present and weakens it to admit exactly one rejected
subclass; retained-gate controls still pass in the same run.

| Mutant | Narrows the gate to | Named failing test | Exit |
|---|---|---|---|
| `reimport-reuses-fixed-owner` | Keeps `owns/drop` gating and fresh UUIDs for ordinary overlap; reuses one fixed UUID whenever the editor has no current owner (first Load and any Load after remove/relink dropped ownership), admitting owner reuse across re-import only | `reviewR5RemoveReimportMustNotReviveOldEditorOwner` (2 issues: loading cleared + catalog-change error published); `editorOverlappingLoadSuppressesStaleCompletion` + `editorRetryAfterSessionInvalidationSucceedsOnSameFlow` still pass | 1 |

No survivors. No delete-only row claimed as narrowing.

## Validation (real exit codes)

- `swift test --package-path Packages/RunnerControlCore --filter reviewR5` → exit 0, 1 passed.
- Overlap/retry/R4 controls filter → exit 0, 4 tests (5 cases) passed.
- `swift test --package-path Packages/RunnerControlCore` → exit 0, 230 tests passed (229 R5 + 1 adopted R6), re-run green after mutant revert.
- Mutant: R5 probe → exit 1 with 2 issues; overlap+retry controls → exit 0.
- `python3 -m unittest discover -s Scripts/tests` → exit 0, 62 tests OK (release machinery untouched).
- `./Scripts/build.sh` → exit 0, `BUILD SUCCEEDED`; `codesign --verify --deep --strict` → exit 0; `1.2.0`, `works.relux.runnercontrol`, TeamIdentifier `262RZ595FP`, fresh candidate in `.temp/products/` (signed 2026-09-16 15:56 UTC).
- No configured linter (no SwiftLint config); build shows no new warnings in changed files.
- Production (read-only): 2 `runsvc.sh` + 2 `Runner.Listener` (macbook-iv, cocoaskills) live; no `actions.runner.*` in `~/Library/LaunchAgents` (manual external login OFF preserved). No production state changed.

## Stated bounds

- UI confirmation paths are manual (root CUA on the fresh candidate; no UI tests per task). The production Flow gates behind them are covered.
- Overlap ownership is per Flow instance; production composes exactly one `Runners.Flow` per runtime, so cross-Flow overlap cannot arise outside tests that deliberately build two Flows.
- Prior R5 bounds unchanged (in-flight membership read, unused remove token, legacy entries without recorded server/scope).
