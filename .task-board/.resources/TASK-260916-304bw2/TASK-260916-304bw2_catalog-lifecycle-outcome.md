# TASK-260916-304bw2 — catalog lifecycle and polished UI (developer outcome)

Status: ready for review (board `to-review`).

## Follow-up fix (checklist item 15): manual autostart defect

Manual CUA smoke found the detail toggle showing login ON for the manual org
runner while `~/Library/LaunchAgents/actions.runner.*` does not exist:
external `manual-service.plist` RunAtLoad=true controls bootstrap startup
only, never login persistence. Fixed model: effective login (`loginEnabled`)
is ON for external manual services only with a matching
`~/Library/LaunchAgents/<label>.plist` registration (RunAtLoad true, same
label/directory/runsvc); standard manifests use their own RunAtLoad. The
toggle now really registers/unregisters login (copy in/out of LaunchAgents),
never edits the external service file, never bootstraps/bootouts (live state
preserved), refuses foreign same-label plists in both directions, and relink
carries a managed registration to the new directory. Detail shows the toggle
bound to effective login plus the preserved external RunAtLoad as info.
Production fixture untouched (verified: no `actions.runner.*` in
`~/Library/LaunchAgents`, both runners still `running`). Candidate left UNCOMMITTED in the
Story worktree for handoff snapshot; no producer commits on the Story branch.

## What shipped

Universal persistent catalog (`catalog.json`, versioned, no secrets), manual +
standard LaunchAgent discovery/import with unsupported read-only kinds,
user-folder import, canonical dedupe, no-space relocation (no auto-move),
Local/Remote/Operation separation with truthful busy/stale/offline UI,
individual + bulk power with confirmed stop, manifest/stdout/stderr + `_diag`
log access with redaction, independent app/runner login policies, explicit
unregister (typed, stopped-only, server/scope/ID+path bound, shared installer
lease) distinct from entry-only catalog removal, fresh API group membership
(not stale `.runner` pool) with an in-app post-registration repository editor
(owned apply + shared takeover, stale refusal, exact confirmation), full menu +
management-window UI, README universal onboarding, 1.2.0 signed candidate.

No SSH fleet controls. No stop-after-job. No new delegates. Release machinery
(`Scripts/release*`, workflows, `RELEASING.md`) untouched.

## UI entry points (manual verification, no UI tests per task)

- Menu (400pt): per-row Enable / Disable… buttons, per-row lock, GitHub
  signature line, bottom Enable all / Disable all… / Add runner… / Runners and
  settings…. Updates + Quit live only in Settings. Icon: outline/filled/error
  with textual accessibility label.
- Management window → Runners → select org runner → Repository access →
  Load current access → checkboxes → Apply (owned) or Take over and apply
  (shared/imported). Repo runners show per-repo note (no groups).
- Detail: directory, work folder, controller kind, service label, agent ID,
  labels, RunAtLoad toggle (preserved policy), log tail, rename, relink moved
  folder, Remove from app (entry only, warns when running), Unregister from
  GitHub (typed, stopped-only).

## AC coverage: 18 of 19 rows driven (row 18 is the stated manual-UI bound)

| # | AC row | Production call site | Named test(s) |
|---|--------|----------------------|---------------|
| 1 | Persistent catalog, rename-safe identity | `RunnerCatalogStore.add/load` | `catalogPersistsAndDedupesCanonicalViaSymlink`, `aliasDoesNotChangeIdentity` |
| 2 | Manual + standard discovery, unsupported read-only, no auto-launch | `RunnerDiscovery.discoverCandidates`, `Runners.Flow.apply(.importCandidate)` | `discoveryFindsManualAndStandardWithoutLaunching`, `importPreservesServiceAndRunAtLoad`, `importRefusesUnsupportedWithoutSecondProcess`, `unsupportedShowsStateButRefusesControl` |
| 3 | User folders + dedupe (symlink collapse; same name ≠ same runner) | `RunnerDiscovery.validateFolder`, `RunnerCatalogStore.add` | `catalogPersistsAndDedupesCanonicalViaSymlink`, `catalogKeepsSameNameDifferentScopesAsTwoRunners` |
| 4 | No-space validation, relocation, no auto-move | `RunnersCatalogGates.validateImportable` | `importRefusesSpacedPathWithoutMoving`, `importGateRefusesSpacedPathDirectly` |
| 5 | Local/remote/operation separation | `LaunchAgentService.snapshots`, `Runners.State.reduce(.refreshed)` | `snapshotsPreserveRunningDespiteMissingRunner`, `refreshRemoteKeepsLocalOnOffline` |
| 6 | Truthful busy/stale/offline | `GitHubRunnerObserver.match/isStale/withFreshness`, `Runners.StopConfirmation` | `observerMatchesByIDNeverByName`, `observerRefusesContradictionAndForeignName`, `staleBusyFalseIsNotIdleProof` |
| 7 | Individual/bulk power, per-row errors, no duplicates | `Runners.Flow.apply(.setEnabled/.setEnabledMany)`, `LaunchAgentService.setEnabled` | `bulkPowerReportsPartialFailuresPerRow`, `offlineLocalControlWithoutToken` (+ existing `startIsIdempotent…`) |
| 8 | Stop despite missing `.runner`; bad manifest blocks start | `LaunchAgentService.setEnabled` | `stopWorksDespiteMissingRunnerStartBlockedOnBadManifest`, `snapshotsPreserveRunningDespiteMissingRunner` |
| 9 | Log access from manifest + `_diag`, redacted, bounded | `RunnerDiagnostics.logFiles/tail` | `diagnosticsResolvesManifestPathsAndRedacts` |
| 10 | Independent login policies, preserved, separate change | `RunnerCatalogStore` (`runAtLoad`), `Runners.Flow.apply(.setRunAtLoad)` | `importPreservesServiceAndRunAtLoad`, `standardPolicyChangePreservesManifestAndSkipsLaunchctl` |
| 10b | Effective manual login: external RunAtLoad=true ⇒ OFF; toggle really registers/unregisters; live state preserved; foreign refused | `RunnerControllers.effectiveLogin`, `Runners.Flow.apply(.setRunAtLoad)` + `setManualLogin`, `LaunchAgentService.snapshots` | `manualExternalRunAtLoadTrueDisplaysLoginOff`, `standardManifestShowsActualPolicy`, `manualToggleOnRegistersLoginWithoutChangingLiveState`, `manualToggleOffUnregistersLoginWithoutStopping`, `manualToggleRefusesForeignPlist` |
| 11 | Unregister vs remove, shared lease, busy + retry | `Runners.Flow.apply(.removeFromApp/.unregister)`, `RunnerInstallerService.unregister` | `removeDeletesOnlyEntryAndWarnsWhenRunning`, `unregisterRefuses*` (4), `unregisterRemovesRemoteKeepsFilesAndEntry`, `installerLeaseSerializesUnregisterAndInstall` |
| 12 | Preserve policies + existing runners; restart ≠ enable | `RunnerCatalogStore.migrateIfNeeded`, import path (no bootstrap) | `migrationPreservesPoliciesWithoutTouchingServices`, `importPreservesServiceAndRunAtLoad` |
| 13 | Production installs unaffected, no duplicate process | migration + idempotent start + live `launchctl print` | `migrationPreservesPoliciesWithoutTouchingServices` + live check (both `state = running`, one process each) |
| 14 | Local works offline; API failures don't change/hide local | `Runners.Flow.apply(.refreshRemote/.setEnabled)` | `refreshRemoteKeepsLocalOnOffline`, `offlineLocalControlWithoutToken` |
| 15 | Fresh API group membership, never stale pool, no same-name adoption | `Runners.Flow.resolveFreshGroup`, `GitHubRunnerAPIClient.fetchGroupRunners` | `groupAccessUsesFreshAPIMembershipNotStalePool` |
| 16 | In-app repo editor: owned apply, shared takeover, stale refusal, exact confirm, repo refused | `Runners.Flow.apply(.loadGroupAccess/.applyGroupAccess)` | `applyGroupAccessRequiresTakeoverForShared`, `applyGroupAccessRefusesStaleGroup`, `applyGroupAccessConfirmsExactRepos`, `groupAccessRefusesRepoScope` |
| 18 | Full UI integrated (menu, detail, editor, login toggle, no fleet/stop-after-job) | — (bound) | BOUND: manual via signed candidate (no UI tests per task) |
| 19 | Tests pass + native app builds (1.2.0) | `swift test`, `Scripts/build.sh` | exit 0 (197 tests) + exit 0 `BUILD SUCCEEDED` + `codesign --verify` exit 0 |

## Mutant evidence: 17 narrowing, 0 survivors

Each mutant keeps its gate and admits exactly one rejected member; the named
test fails (exit 1). Tree reverted after each run; final suite green.

| Mutant | Narrows the gate to | Named failing test |
|--------|---------------------|--------------------|
| `catalog-dedupe-admits-alias-label` | Dedupe on dir+label (admits same dir, other label) | `catalogPersistsAndDedupesCanonicalViaSymlink` |
| `import-admits-spaced-path` | No-space on work only (admits spaced install path) | `importGateRefusesSpacedPathDirectly` |
| `manifest-admits-wrong-directory` | Manifest on label+args (admits wrong WorkingDirectory) | `stopWorksDespiteMissingRunnerStartBlockedOnBadManifest` |
| `unsupported-admits-stop` | Unsupported refuses start only (admits stop) | `unsupportedShowsStateButRefusesControl` |
| `observer-adopts-foreign-name` | Observer falls back to same-name foreign ID | `observerRefusesContradictionAndForeignName` |
| `stale-admits-idle` | Stale treats busy=false as fresh | `staleBusyFalseIsNotIdleProof` |
| `unregister-admits-wrong-confirmation` | Confirmation accepts the wrong literal | `unregisterRefusesWrongConfirmationWithoutAPICall` |
| `installer-admits-cross-dir-overlap` | Lease refuses same path only (admits other dir) | `installerLeaseSerializesUnregisterAndInstall` |
| `redaction-preserves-token-breaks-scrub` | Keeps `access_token` token, misses shape (trailing space); behavioral `swift test` harness | `diagnosticsResolvesManifestPathsAndRedacts` |
| `group-adopts-same-name-foreign` | Membership falls back to same-name foreign | `groupAccessUsesFreshAPIMembershipNotStalePool` |
| `apply-admits-stale-group` | Apply skips fresh-group equality | `applyGroupAccessRefusesStaleGroup` |
| `apply-admits-shared-without-takeover` | Apply skips takeover authorization | `applyGroupAccessRequiresTakeoverForShared` |
| `apply-admits-partial-confirm` | Apply skips exact repo confirmation | `applyGroupAccessConfirmsExactRepos` |
| `login-admits-external-runatload` | Effective login falls back to external RunAtLoad (the original defect) | `manualExternalRunAtLoadTrueDisplaysLoginOff` |
| `toggle-on-skips-registration-write` | Toggle ON succeeds without writing the registration | `manualToggleOnRegistersLoginWithoutChangingLiveState` |
| `toggle-admits-foreign-overwrite` | Toggle ON skips the foreign-plist reference check | `manualToggleRefusesForeignPlist` |
| `toggle-stops-live-service` | Toggle also bootouts the live service | `manualToggleOnRegistersLoginWithoutChangingLiveState` |

## Validation (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` → exit 0, 197 tests passed (34 catalog + 5 group + 6 login policy, replacing 1 superseded).
- `RUN_LAUNCH_AGENT_INTEGRATION=1 swift test … --filter realLaunchAgentLifecycle` → exit 0, passed (temp sleep service only).
- `./Scripts/build.sh` → exit 0, `BUILD SUCCEEDED`; `codesign --verify --deep --strict` → exit 0; `1.2.0 (101.99)`, `works.relux.runnercontrol`, team `262RZ595FP`, universal.
- Production: both runners `state = running`, one `runsvc.sh` + one `Runner.Listener` each (no duplicates, never stopped).
- Lint: no configured linter; build shows only pre-existing Sendable-closure warnings in untouched patterns.

## Stated bounds

- UI row is manual (root CUA on the fresh candidate in `.temp/products/`).
- Concurrent wizard + catalog edits to the same group are last-write-wins; the
  post-registration flow assumes the wizard is closed.
- Local poll is uniform 3s (menu and background); wake + post-command refresh included.
- Group resolution lists each group's runners sequentially (fine for small G).
- Editor candidates come from the selected GitHub installation; cross-org
  mismatch disables Apply with guidance.
