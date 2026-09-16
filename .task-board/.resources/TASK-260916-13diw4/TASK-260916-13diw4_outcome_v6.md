# TASK-260916-13diw4: register-mac-and-repository-access — developer outcome v6

Status: ready for review (board `to-review`, uncommitted candidate in story worktree).

Focused R6 delivery per `revision6-canonical-lease.md` and `revision6-recovery-FIRST.md`:
fixes R5-F1 (`changes_requested`, `repeat-of: revision 4 / R4-F1`) — the directory
lease could be bypassed through a symlink alias — and recovers the cancelled
RUN-260916-0e9d43 validation, whose preserved source edits are completed here.
Prior M1–M29 regions were not rerun per contract (unchanged code); the M9
survivor bound is restated from v3/v5.

## Fixes (code)

Preserved from the cancelled run (verified, not rewritten): canonical `leaseKey`
via nearest-existing-ancestor symlink resolution, original-key hold across
awaits with exact-key release, `ensureNoAlias` refusal before side effects, and
the three R6 tests. This run adds two surgical corrections:

1. **`ensureNoAlias` no longer conflates symlinks with Finder aliases.**
   `URLResourceValues.isAliasFileKey` is also true for symlinks such as the
   system `/var` and `/tmp` links that every temporary path resolves through,
   so the preserved check refused ALL installs under temp roots with
   `invalidDraft("... resolves through a Finder alias at '/var'")`. Fix:
   skip components where `destinationOfSymbolicLink` succeeds (symlinks are
   canonicalized by `leaseKey`, not refused); only non-symlink aliases throw.
   This was also the root cause of the validation hang: the refused download
   left `installPath` nil, the register step failed with "Install the runner
   package first", `config.sh` never started, and `waitStarted()` suspended
   forever while the testing helper outlived its parent.
2. **Bounded latch wait in `reviewerSymlinkAliasCannotBypassDirectoryLease`.**
   New `waitForConfigStart(_:timeoutSeconds:)` (30 s poll of the latch flag,
   no leaked continuations) plus a pre-latch gate check that fails fast with
   the recorded Flow failure. A config that never starts is now a reported
   failure with diagnostics, never a hang. Regression steps, transport queue,
   and both `#expect` assertions are otherwise identical to the attached rev5
   attack source; semantics preserved, not weakened.

## AC coverage — 8 of 8 rows driven through production entry points

| # | AC row | Named committed test(s) | Production call site |
|---|--------|-------------------------|----------------------|
| 1 | Org registration without terminal | `orgWizardEndToEndDeletesTokenAndLeaksNothing`, `reviewerInFlightInstallCannotRepopulateChangedDraft`, `reviewerRetryCannotRunTwoConfigsInSameDirectory`, `cancelDuringConfigKeepsLeaseAndRecoversAfterSettle`, `reviewerSymlinkAliasCannotBypassDirectoryLease` | `Flow.apply` (.beginDraft/.resolveGroup/.downloadAndInstall/.registerRunner/.setupService/.retry/.cancel) |
| 2 | Repo registration without terminal | `repoWizardOmitsRunnerGroup`, `repoRunnerListRequestUsesQueryNotEncodedPath` | same Flow effects; no `runner-groups` traffic, no `--runnergroup` argv |
| 3 | Selected repos are applied | `orgResolveGroupCreatesWithSelectedRepos`, `repoAccessAppliesAndConfirmsRealIDs`, `repositoryConfirmationFollowsPagination`, `inFlightAccessAbandonedWhenRepositoriesEdited` | `createGroup` / `setGroupRepositories` + paginated `fetchGroupRepositories` confirm |
| 4 | Repo access and labels changeable | `repoAccessAppliesAndConfirmsRealIDs`, `labelsApplyRequiresRealRunnerIDThenPuts`, `inFlightLabelsAbandonedWhenLabelsEdited` | `Flow.apply(.applyRepositoryAccess/.applyLabels)` with verified IDs |
| 5 | Failed ops avoid orphans | `failedConfigDeletesTokenAndReportsScrubbedError`, `registerIsIdempotentAcrossRetries`, `registerRefusesMismatchedRemoteIdentity`, `cancelDuringConfigKeepsLeaseAndRecoversAfterSettle` (both tokens deleted) | `Flow.registerRunner` (token deleted on every failure path; single mint/config) |
| 6 | Repeated ops avoid duplicates | `registerIsIdempotentAcrossRetries`, `retryResumesFailedDownloadWithoutDuplicates`, `remoteDuplicateWithoutReplaceIsRefusedBeforeToken`, `runnerListFollowsPaginationForDuplicateGuard`, `existingRegistrationBlocksFreshInstall`, `reviewerRetryCannotRunTwoConfigsInSameDirectory` (1 config call), `beginDraftDuringDownloadKeepsDirectoryLease`, `resetDuringDownloadKeepsDirectoryLeaseUntilSettled`, `nonconflictingInstallProceedsWhileOtherDirectoryRuns` (scope control), `reviewerSymlinkAliasCannotBypassDirectoryLease` (alias spelling, 1 config call) | complete-list `rejectRemoteDuplicate` gate + installer markers + canonical directory lease + owner lock |
| 7 | No secret leakage | `orgWizardEndToEndDeletesTokenAndLeaksNothing`, `runConfigScrubsTokenFromFailure`, `failedConfigDeletesTokenAndReportsScrubbedError`, `cancelDuringConfigKeepsLeaseAndRecoversAfterSettle` | token only in config.sh argv in memory; absent from actions/URLs/headers/bodies; deleted after use |
| 8 | Tests exercise actual entry points | all Flow tests + `setupServiceWritesManualPlistFoundByDiscovery`, `runConfigExecutesRealScript`, `staleRegisterFailureDoesNotUnlockOrPlantFailure`, `scopeChangeClearsCompletedStepsInState`, `leaseKeyCanonicalizesSymlinkAncestorsForMissingLeaf`, `finderAliasInstallFolderIsRefusedBeforeDownload` | `Flow.apply`, `RunnerInstallerService.*`, `State.reduce`, cross-checked by `RunnerDiscovery.installed` and a real shell `config.sh` |

Negative/refusal coverage: all v3/v4/v5 negatives retained and green, plus the
adopted rev5 alias attack and the R6 ancestor/alias controls.

## Narrowing-mutant evidence

Changed gate only (M1–M29 unchanged regions not rerun per contract):

| Mutant | Admits exactly | Named failing test(s) | Result |
|--------|----------------|-----------------------|--------|
| M30: `leaseKey` reduced to spelling-only `standardizedFileURL.path` (no symlink resolution), fixed `ensureNoAlias` kept | symlink-alias spellings only | `reviewerSymlinkAliasCannotBypassDirectoryLease` (2 issues: 2 config calls; attested-complete vs .runner mismatch — the exact R5-F1 signature) | KILLED, exit 1; control `reviewerRetryCannotRunTwoConfigsInSameDirectory` (same-spelling class) passes exit 0 under the mutant |
| M30 revert | — | pristine sha256 `ecc84edc…59cc4a` verified after revert; alias test re-run green | REVERTED |

No survivors in M30. Prior M9 (`createGroup` default true→false) survivor bound
restated from v3 (unchanged code, not rerun): the default is not load-bearing,
Flow passes `true` explicitly, M9b kills the call site.

The source-text-token mutant rule does not apply: no gate inspects source text.

## Verification commands (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` (CI gate):
  **exit 0, 157 tests passed** (154 + 3 R6), full log at `/tmp/r6_full.log`.
- Focused lifecycle filter (R6 trio + 7 R5 controls + `downloadRefusesMissingChecksum`):
  **exit 0, 11 tests passed**.
- M30 mutant runs: alias test **exit 1** (2 issues, killed); same-spelling
  control **exit 0**; revert sha256 match confirmed.
- `python3 -m unittest discover -s Scripts/tests` (CI gate): **exit 0, 4 tests OK**.
- `xcodebuild -workspace RunnerControl.xcworkspace -scheme RunnerControl
  -destination 'platform=macOS' build`: **BUILD SUCCEEDED** (exit 0, 7.8 s).
- No repo-configured lint gate (CI `ci.yml` runs only the two test jobs above;
  no `.swiftlint.yml`/`.swiftformat`).
- Hang bisection evidence: pure `leaseKey` control and Finder-alias control
  passed while fixture tests failed naming `/var` as an alias; trivial-filter
  run green — isolating the hang to the test's unbounded latch wait behind a
  gate error, fixed as described above.
- Generator inputs untouched: `ios-app-manager.json`, `Project.swift`,
  `Workspace.swift`, `Package.swift` unmodified (this run edited only the two
  existing candidate files); existing production runners untouched (all test IO
  under temp roots; services never bootstrapped); candidate left UNCOMMITTED,
  no producer commit (branch tip still `6b4a21d`).

## Files changed (all UNCOMMITTED in story worktree, as required)

- `Packages/RunnerControlCore/Sources/RunnerInstallerService.swift` —
  canonical `leaseKey` (nearest-existing-ancestor resolution, original-key
  hold/release), `ensureNoAlias` with symlink exclusion.
- `Packages/RunnerControlCore/Tests/RunnerRegistrationTests.swift` —
  adopted `reviewerSymlinkAliasCannotBypassDirectoryLease` with bounded
  `waitForConfigStart` + pre-latch gate check,
  `leaseKeyCanonicalizesSymlinkAncestorsForMissingLeaf`,
  `finderAliasInstallFolderIsRefusedBeforeDownload`, `DownloadCounter`.

## Stated bounds (unknowns, not guesses)

- Live registration smoke remains a separate delivery task; transport covered
  by fakes, filesystem by temp-root fixtures with real `tar`/`shasum`/`config.sh`.
- Authenticated download `sha256_checksum` availability was confirmed
  nonempty for osx x64/arm64 by root read-only live API (per revision-4
  contract); this run made no live GitHub calls.
- Pagination cap is 100 pages per list (fail-closed throw, never silent partial).
- Mid-step session change is bound by single-auth reuse (no mixing); an
  inter-step change invalidates via `syncServerBinding` plus `.runner`/marker
  verification.
- Ownership table stays per-Mac (`~/Library/GitHubActions/
  .runnercontrol-groups.json`); two local users do not share it.
- A same-directory retry refused with `directoryBusy` mints and deletes a
  short-lived registration token for the register step before reaching the
  lease; the token is never used for a second config and never retained.
- Alias refusal covers alias components in the given installation spelling;
  a symlink that resolves to a target containing an alias elsewhere is
  canonicalized by `leaseKey`, not refused as an alias.
