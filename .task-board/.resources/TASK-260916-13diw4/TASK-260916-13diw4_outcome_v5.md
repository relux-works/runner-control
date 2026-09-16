# TASK-260916-13diw4: register-mac-and-repository-access — developer outcome v5

Status: ready for review (board `to-review`, uncommitted candidate in story worktree).

This run implements BOTH revision-4 findings (R4-F1 + R4-F2,
`changes_requested`, `repeat-of: revision 3 / R3-F1` for both) as one coherent
operation-owner + directory-lease lifecycle change per the revision-5 contract,
adopting the reviewer's exact attack source as committed named regressions.
Prior M1–M27 regions were not rerun per contract (unchanged code); the M9
survivor bound is restated from v3.

## Fixes (code)

1. **R4-F1 — abandoned completion released a still-running directory mutation
   (repeat-of R3-F1).** New per-directory lease in `RunnerInstallerService`:
   `activeDirectories` set acquired synchronously before the first await in
   `downloadAndInstall` and `runConfig` (resume/reuse checks included) and
   released via `defer` only when the owning side effect settles. `setupService`
   and `recoverPartialInstall` refuse via `requireIdleDirectory` while a live
   async side effect owns the directory. Conflicts throw the new retryable
   `RegistrationError.directoryBusy`; different directories never conflict.
   Abandoning a UI generation does not release the lease.
2. **R4-F2 — stale failure cleared the current operation's busy guard
   (repeat-of R3-F1).** `Flow.working: Bool` replaced with
   `workingOwner: Int?` (owning generation, nil when idle). Every step sets the
   owner before its first await; `fail` and `finishStep` are now
   generation-owned (`guard workingOwner == gen`), and all seven catch blocks
   lost their unconditional `working = false`. A stale success/failure/cancel
   exit mutates nothing: no lock release, no step clear, no planted failedStep.
   `beginDraft`/`updateDraft`/`cancel`/`reset` hand the UI lock to the new
   generation at once while live side effects keep their leases.

## AC coverage — 8 of 8 rows driven through production entry points

| # | AC row | Named committed test(s) | Production call site |
|---|--------|-------------------------|----------------------|
| 1 | Org registration without terminal | `orgWizardEndToEndDeletesTokenAndLeaksNothing`, `reviewerInFlightInstallCannotRepopulateChangedDraft`, `reviewerRetryCannotRunTwoConfigsInSameDirectory`, `cancelDuringConfigKeepsLeaseAndRecoversAfterSettle` | `Flow.apply` (.beginDraft/.resolveGroup/.downloadAndInstall/.registerRunner/.setupService/.retry/.cancel) |
| 2 | Repo registration without terminal | `repoWizardOmitsRunnerGroup`, `repoRunnerListRequestUsesQueryNotEncodedPath` | same Flow effects; no `runner-groups` traffic, no `--runnergroup` argv |
| 3 | Selected repos are applied | `orgResolveGroupCreatesWithSelectedRepos`, `repoAccessAppliesAndConfirmsRealIDs`, `repositoryConfirmationFollowsPagination`, `inFlightAccessAbandonedWhenRepositoriesEdited` | `createGroup` / `setGroupRepositories` + paginated `fetchGroupRepositories` confirm |
| 4 | Repo access and labels changeable | `repoAccessAppliesAndConfirmsRealIDs`, `labelsApplyRequiresRealRunnerIDThenPuts`, `inFlightLabelsAbandonedWhenLabelsEdited` | `Flow.apply(.applyRepositoryAccess/.applyLabels)` with verified IDs |
| 5 | Failed ops avoid orphans | `failedConfigDeletesTokenAndReportsScrubbedError`, `registerIsIdempotentAcrossRetries`, `registerRefusesMismatchedRemoteIdentity`, `cancelDuringConfigKeepsLeaseAndRecoversAfterSettle` (both tokens deleted) | `Flow.registerRunner` (token deleted on every failure path; single mint/config) |
| 6 | Repeated ops avoid duplicates | `registerIsIdempotentAcrossRetries`, `retryResumesFailedDownloadWithoutDuplicates`, `remoteDuplicateWithoutReplaceIsRefusedBeforeToken`, `runnerListFollowsPaginationForDuplicateGuard`, `existingRegistrationBlocksFreshInstall`, `reviewerRetryCannotRunTwoConfigsInSameDirectory` (1 config call), `beginDraftDuringDownloadKeepsDirectoryLease`, `resetDuringDownloadKeepsDirectoryLeaseUntilSettled`, `nonconflictingInstallProceedsWhileOtherDirectoryRuns` (scope control) | complete-list `rejectRemoteDuplicate` gate + installer markers + directory lease + owner lock |
| 7 | No secret leakage | `orgWizardEndToEndDeletesTokenAndLeaksNothing`, `runConfigScrubsTokenFromFailure`, `failedConfigDeletesTokenAndReportsScrubbedError`, `cancelDuringConfigKeepsLeaseAndRecoversAfterSettle` | token only in config.sh argv in memory; absent from actions/URLs/headers/bodies; deleted after use |
| 8 | Tests exercise actual entry points | all Flow tests + `setupServiceWritesManualPlistFoundByDiscovery`, `runConfigExecutesRealScript`, `staleRegisterFailureDoesNotUnlockOrPlantFailure`, `scopeChangeClearsCompletedStepsInState` | `Flow.apply`, `RunnerInstallerService.*`, `State.reduce`, cross-checked by `RunnerDiscovery.installed` and a real shell `config.sh` |

Negative/refusal coverage (each fails when the gate admits what it must
reject): all v3/v4 negatives retained and green, plus the two adopted reviewer
attacks and five new R5 lifecycle tests (`beginDraft…`, `reset…`, `cancel…`,
`nonconflicting…` scope control, `staleRegisterFailure…` cross-step control).

## Narrowing-mutant evidence (this run, each reverted pristine via sha256)

New/changed gates only (M1–M27 unchanged regions not rerun per contract):

| Mutant | Admits exactly | Named failing test(s) | Result |
|--------|----------------|-----------------------|--------|
| M28: `fail` guard `workingOwner == gen \|\| step == "downloadAndInstall"` | stale download-failure unlocks only | `reviewerStaleFailureCannotUnlockNewOperation` (1 issue: after 2 vs before 1) | KILLED, exit 1; control `staleRegisterFailureDoesNotUnlockOrPlantFailure` (register stale class) passes |
| M29: `runConfig` lease acquire/release skipped | same-directory overlapping config only | `reviewerRetryCannotRunTwoConfigsInSameDirectory` (2 issues: 2 config calls; attested-complete vs .runner mismatch) | KILLED, exit 1; control `beginDraftDuringDownloadKeepsDirectoryLease` (download lease class) passes |

No survivors in M28–M29. Prior M9 (`createGroup` default true→false)
survivor bound restated from v3 (unchanged code, not rerun): the default is
not load-bearing, Flow passes `true` explicitly, M9b kills the call site.

The source-text-token mutant rule does not apply: no gate inspects source
text.

## Verification commands (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` (CI gate):
  **exit 0, 154 tests passed** (147 + 2 adopted + 5 new R5), re-run green after
  mutant revert with pristine sha256 match on both touched sources.
- `python3 -m unittest discover -s Scripts/tests` (CI gate): **exit 0,
  4 tests OK**.
- `xcodebuild -workspace RunnerControl.xcworkspace -scheme RunnerControl
  -destination 'platform=macOS' build`: **BUILD SUCCEEDED** (exit 0).
- No repo-configured lint gate (CI runs only the two test jobs above;
  no `.swiftlint.yml`).
- Generator inputs untouched: `ios-app-manager.json`, `Project.swift`,
  `Workspace.swift`, `Package.swift` unmodified (no new source files added);
  existing production runners untouched (all test IO under temp roots;
  services never bootstrapped); candidate left UNCOMMITTED, no producer commit.

## Files changed (all UNCOMMITTED in story worktree, as required)

- `Packages/RunnerControlCore/Sources/RunnerRegistration+Models.swift` —
  retryable `directoryBusy(path:)` error.
- `…/RunnerInstallerService.swift` — `activeDirectories` lease registry,
  `leaseKey`/`acquireLease`/`releaseLease`/`requireIdleDirectory`, integrated
  into `downloadAndInstall`, `runConfig`, `setupService`,
  `recoverPartialInstall`.
- `…/RunnerRegistration+Flow.swift` — `workingOwner` operation lock,
  generation-owned `fail`/`finishStep`, owner set/guard in all seven steps,
  `retry` guard, `beginDraft`/`updateDraft`/`cancel`/`reset` handoff; all seven
  unconditional catch clears removed.
- `Packages/RunnerControlCore/Tests/RunnerRegistrationTests.swift` — 2
  verbatim reviewer regressions + `ReviewTwoDownloads` + 5 R5 lifecycle tests,
  `CountingLatchDownloader`, `ConfigLatchExecutor` failure injection.

## Stated bounds (unknowns, not guesses)

- Live registration smoke remains a separate delivery task; transport covered
  by fakes, filesystem by temp-root fixtures with real `tar`/`shasum`/`config.sh`.
- Authenticated download `sha256_checksum` availability was confirmed
  nonempty for osx x64/arm64 by root read-only live API (per revision-4
  contract); this run made no live GitHub calls.
- Pagination cap is 100 pages per list (fail-closed throw, never silent
  partial).
- Mid-step session change is bound by single-auth reuse (no mixing); an
  inter-step change invalidates via `syncServerBinding` plus `.runner`/marker
  verification.
- Ownership table stays per-Mac (`~/Library/GitHubActions/
  .runnercontrol-groups.json`); two local users do not share it. Pre-revision-4
  ownership entries (no server) and configured markers (no group) fail closed
  toward explicit takeover/reconfiguration, never silent adoption.
- A same-directory retry refused with `directoryBusy` mints and deletes a
  short-lived registration token for the register step before reaching the
  lease; the token is never used for a second config and never retained.
