# TASK-260916-304bw2 — R2 focused catalog/lifecycle rework (developer outcome)

Status: ready for review (board `to-review`).

Revision 2 adopts the four exact rev1 reviewer probes as maintained
production-entry regressions and fixes F1–F4 at the root cause, preserving
accepted registration/global installer lease, corrected real login policy,
and the existing repository editor. No production runner was stopped,
re-registered, or interrupted; the candidate is left UNCOMMITTED in the
Story worktree for handoff snapshot.

## Fixes by finding

### F1 — stopped-only unregister with boundary revalidation
- `Runners+Flow.requireConfirmedStopped` (new): only a positive confirmed
  `.stopped` snapshot authorizes removal. `.running` keeps the stop-first
  refusal; missing observation and every other state (unknown, failed,
  missing, transitional) refuse as unconfirmed. A launchctl permission
  error (`.unknown`) can no longer mint a remove token or reach
  `config.sh remove`.
- Enforced twice: before the remove-token mint and revalidated at the
  `installer.unregister` side-effect boundary (a service started after the
  mint is refused; the unused token simply expires).
- `ManagementWindowContainer.confirmUnregister`: the typed confirmation is
  now reachable only from `.stopped`; other states get an explicit
  "state unconfirmed" alert. The flow re-checks regardless (no UI tests).

### F2 — write-path server/scope/agentID/service binding on Apply
- `Runners+Flow.bindApplyIdentity` (new): re-reads the mutable local
  registration at Apply time and requires server host, org scope, agent ID
  and name to still match, plus the catalog entry to still point at the
  verified canonical directory. A same-path foreign host, scope edit, or
  relink fails instead of writing another server's group.
- `Runners+Flow.sessionStill` (new): the started session (user + server)
  is re-checked after authentication and again at the PUT boundary; a
  logout/account/server switch mid-operation stops silently with no write
  into the changed session (same shape as `refreshRemote`).

### F3 — collision-safe persistent service identities
- `RunnerCatalogStore.importedServiceLabel` (new): folder imports get
  `actions.runner.imported.<name>-<8 hex canonical-path hash>` —
  deterministic per directory, distinct per path.
- Conflicting labels refuse: `importCandidate` refuses a manifest label
  already owned by another entry, and `catalog.add/update` refuse
  duplicate labels (directory dedupe keeps priority, so the symlink-alias
  error is unchanged).
- Supporting refinement found by the new per-runner-control regression:
  `RunnerControllers.validateManifestMatches` and `references` now compare
  WorkingDirectory/ProgramArguments by canonical identity. The stored path
  and the bookmark-resolved directory can differ in spelling (`/var` vs
  `/private/var`) for the same installation; string comparison broke
  control of imported runners on such paths. Wrong-directory manifests
  still refuse (carryover mutant re-verified).

### F4 — migration completion independent of count, fail-closed persistence
- `RunnerCatalogStore.File.migrated`: one-time migration seals the catalog
  — including an empty result — and an initialized (even explicitly
  emptied) catalog is authoritative. Removing the last entry never
  resurrects it at restart. Legacy files without the flag seal in place
  without touching entries.
- Checked reads: missing file is first-run absence; malformed/unreadable/
  unsupported-version stores throw (`persistenceUnreadable`,
  `unsupportedVersion`) instead of masquerading as empty. Migration never
  runs on them, and `add/remove/update` never overwrite them. `load()`
  stays a fail-soft display read and is documented as such.

## Production call sites

| Fix | Call site |
|---|---|
| F1 | `Runners.Flow.apply(.unregister)` → `requireConfirmedStopped` (×2) → `RunnerInstallerService.unregister` |
| F2 | `Runners.Flow.apply(.applyGroupAccess)` → `bindApplyIdentity` (×2) + `sessionStill` (×2) → `GitHubRunnerAPIClient.setGroupRepositories` |
| F3 | `Runners.Flow.apply(.importFolder)` → `importedServiceLabel` → `RunnerCatalogStore.add`; control via `LaunchAgentService.setEnabled` |
| F4 | `Runners.Flow.apply(.loadCatalog)` → `RunnerCatalogStore.migrateIfNeeded`; mutations via `add/remove/update` |
| F1 UI | `ManagementWindowContainer.confirmUnregister` (manual bound, no UI tests) |

## Tests: 13 new, 210 total green

Adopted probes (failed exit 1 on rev1, pass now):
`reviewUnknownServiceMustRefuseUnregister`,
`reviewRemovedLastEntryMustStayRemovedOnMigration`,
`reviewSameNameFolderImportsMustHaveDistinctServiceIDs`,
`reviewCrossServerGroupApplyMustRefuse`.

New bounds: `unregisterRevalidatesStoppedAtSideEffectBoundary` (F1),
`applyGroupAccessStopsWhenSessionChangesMidApply` and
`applyGroupAccessStopsWhenServerSwitchesMidApply` (F2),
`sameNameFolderImportsControlIndependently`,
`importRefusesConflictingManifestLabel`,
`catalogRefusesDuplicateServiceLabel` (F3),
`migrationFailsClosedOnMalformedPersistence`,
`migrationFailsClosedOnUnsupportedVersion`,
`migrationSealsLegacyStoreWithoutTouchingEntries` (F4).

Updated: `unregisterRemovesRemoteKeepsFilesAndEntry` gains the third
launchd observation (pre-check, boundary revalidation, refresh).

AC coverage: still 18 of 19 rows driven through production entry points
(row 18 remains the stated manual-UI bound); rows 3/11/12/16 now carry the
negative boundaries the verdict required.

## Mutant evidence: 8 narrowing + 1 delete-only + 1 carryover, 0 survivors

Tree reverted after each run; full suite re-run green afterwards.

| Mutant | Narrows the gate to | Named failing test | Exit |
|---|---|---|---|
| `unregister-admits-unknown` | Stopped gate admits `.unknown` (running refusal retained) | `reviewUnknownServiceMustRefuseUnregister` (2 issues); `unregisterRefusesRunningService` still passes | 1 |
| `apply-admits-cross-server` | Bind keeps agent/scope/canonical, drops host check | `reviewCrossServerGroupApplyMustRefuse` (PUT emitted) | 1 |
| `import-uses-name-only-label` | Label drops path hash (sanitization kept) | `reviewSameNameFolderImportsMustHaveDistinctServiceIDs` (count 1) | 1 |
| `migration-admits-initialized-empty` | Migration ignores `migrated`, keys on empty | `reviewRemovedLastEntryMustStayRemovedOnMigration` (entry returns) | 1 |
| `persistence-treats-malformed-as-absent` | Decode failure returns nil (read-failure throw kept) | `migrationFailsClosedOnMalformedPersistence` (4 issues: migrated + clobbered) | 1 |
| `session-admits-server-switch` | Session check keeps userID, drops server | `applyGroupAccessStopsWhenServerSwitchesMidApply` (PUT fired); logout variant still passes | 1 |
| `catalog-admits-duplicate-label` | `add` keeps dir dedupe, drops label check | `catalogRefusesDuplicateServiceLabel`; symlink-dedupe test still passes | 1 |
| `boundary-skips-revalidation` (delete-only, labeled) | Removes second enforcement point | `unregisterRevalidatesStoppedAtSideEffectBoundary` (3 issues) | 1 |
| `manifest-admits-wrong-directory` (carryover) | Canonical gate drops WorkingDirectory | `stopWorksDespiteMissingRunnerStartBlockedOnBadManifest` | 1 |

No survivors. The delete-only row is existence evidence for the second
enforcement point, not narrowing evidence (narrowing for that gate is M1).

## Validation (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` → exit 0, 210
  tests passed (197 rev1 + 13 R2).
- `python3 -m unittest discover -s Scripts/tests` → exit 0, 62 tests OK
  (release machinery untouched).
- `./Scripts/build.sh` → exit 0, `BUILD SUCCEEDED`;
  `codesign --verify --deep --strict` → exit 0; `1.2.0`,
  `works.relux.runnercontrol`, fresh candidate in `.temp/products/`.
- No configured linter (no SwiftLint config); build shows only
  pre-existing Sendable-closure warnings in untouched view patterns, none
  in changed files.
- Production (read-only): `macbook-iv` service `state = running`, exactly
  one `runsvc.sh` + one `Runner.Listener` per runner (macbook-iv,
  cocoaskills); no `actions.runner.*` in `~/Library/LaunchAgents` (manual
  external login OFF preserved).

## Stated bounds

- UI confirmation paths are manual (root CUA on the fresh candidate; no UI
  tests per task). The production Flow gates behind them are covered.
- Concurrent wizard + catalog edits to the same group remain
  last-write-wins (rev1 bound, unchanged).
- `update()`'s duplicate-label check is defense in depth (relink never
  changes labels); narrowing evidence targets `add()` on the import path.
- A remove token minted just before a boundary refusal expires unused;
  the refused side effect is `config.sh remove` (proven installer-idle).
