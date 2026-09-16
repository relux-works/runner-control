# TASK-260916-13diw4: register-mac-and-repository-access — developer outcome v7

Status: ready for review (board `to-review`, uncommitted candidate in story worktree).

Focused R7 delivery per `revision7-case-equivalence.md`: fixes R6-F1
(`changes_requested`, `repeat-of: revision 5 / R5-F1`) — a missing-leaf
case alias (`macbook-test` vs `MACBOOK-TEST`) bypassed the canonical
directory lease on case-insensitive volumes. Prior M1–M30 regions were not
rerun per contract (unchanged code); the M9 survivor bound is restated
from v3/v5/v6.

## Fix (code)

`Packages/RunnerControlCore/Sources/RunnerInstallerService.swift` only:

- `leaseKey(for:caseSensitiveOverride:)` now folds the canonical path with
  POSIX-locale lowercasing when the volume is case-insensitive, so both
  spellings share one lease while the leaf is still absent. The fold
  matches the on-disk spelling `resolvingSymlinksInPath` returns after
  creation, keeping identity stable before/after creation regardless of
  which spelling is created first (both orders probed: creating lower
  resolves upper to lower; creating upper resolves lower to upper).
- Sensitivity comes from the real volume via
  `volumeSupportsCaseSensitiveNamesKey` (`isCaseSensitiveVolume(at:)`,
  queried on the resolved nearest existing ancestor) — never assumed.
  Case-sensitive volumes keep distinct keys per spelling. Unknown or
  unreadable volumes fail closed toward alias safety (fold): on a truly
  sensitive volume that only over-serializes into a retryable
  `directoryBusy`, while the reverse would admit concurrent mutations of
  one physical directory.
- `caseSensitivityOverride` test seam (default nil = real volume) follows
  the existing downloader/executor/arch/hasher injection pattern; it backs
  the host-independent sensitive control. Production
  (`RunnerRuntime.make`) uses the default. Original-key hold across awaits
  with exact-key release is unchanged; `acquireLease` and
  `requireIdleDirectory` both pass the override, so download/config/
  service/recovery share one identity.

## Adopted regression — ordering correction (proven contradiction)

Adopted `reviewerCaseAliasMissingLeafCannotBypassDirectoryLease` with same
production entry (`Flow.apply`), spellings, refusal assertions
(calls==1, busy) and retry-reuse assertion, but the physical-identity
(inode) proof runs after the original settles instead of while the refused
second is still pending. The attached order is unsatisfiable on ANY
correct fix: line 21 requires the leaf absent after the first starts, the
inode lines require it present after the refused second, and only a
refused operation (no side effects by definition) plus a still-latched
first run between them — so `attributesOfItem` would throw instead of
asserting. An eager-mkdir "fix" would break line 21 instead. Proving
same-inode after settle keeps the alias premise (evidence print kept:
`calls=1, lowerInode==upperInode`) while calls==1/busy prove the refusal.

## AC coverage — 8 of 8 rows driven through production entry points

| # | AC row | Named committed test(s) | Production call site |
|---|--------|-------------------------|----------------------|
| 1 | Org registration without terminal | `orgWizardEndToEndDeletesTokenAndLeaksNothing`, `reviewerInFlightInstallCannotRepopulateChangedDraft`, `reviewerRetryCannotRunTwoConfigsInSameDirectory`, `cancelDuringConfigKeepsLeaseAndRecoversAfterSettle`, `reviewerSymlinkAliasCannotBypassDirectoryLease`, `reviewerCaseAliasMissingLeafCannotBypassDirectoryLease` | `Flow.apply` (.beginDraft/.resolveGroup/.downloadAndInstall/.registerRunner/.setupService/.retry/.cancel) |
| 2 | Repo registration without terminal | `repoWizardOmitsRunnerGroup`, `repoRunnerListRequestUsesQueryNotEncodedPath` | same Flow effects; no `runner-groups` traffic, no `--runnergroup` argv |
| 3 | Selected repos are applied | `orgResolveGroupCreatesWithSelectedRepos`, `repoAccessAppliesAndConfirmsRealIDs`, `repositoryConfirmationFollowsPagination`, `inFlightAccessAbandonedWhenRepositoriesEdited` | `createGroup` / `setGroupRepositories` + paginated `fetchGroupRepositories` confirm |
| 4 | Repo access and labels changeable | `repoAccessAppliesAndConfirmsRealIDs`, `labelsApplyRequiresRealRunnerIDThenPuts`, `inFlightLabelsAbandonedWhenLabelsEdited` | `Flow.apply(.applyRepositoryAccess/.applyLabels)` with verified IDs |
| 5 | Failed ops avoid orphans | `failedConfigDeletesTokenAndReportsScrubbedError`, `registerIsIdempotentAcrossRetries`, `registerRefusesMismatchedRemoteIdentity`, `cancelDuringConfigKeepsLeaseAndRecoversAfterSettle` (both tokens deleted) | `Flow.registerRunner` (token deleted on every failure path; single mint/config) |
| 6 | Repeated ops avoid duplicates | `registerIsIdempotentAcrossRetries`, `retryResumesFailedDownloadWithoutDuplicates`, `remoteDuplicateWithoutReplaceIsRefusedBeforeToken`, `runnerListFollowsPaginationForDuplicateGuard`, `existingRegistrationBlocksFreshInstall`, `reviewerRetryCannotRunTwoConfigsInSameDirectory` (1 config call), `beginDraftDuringDownloadKeepsDirectoryLease`, `resetDuringDownloadKeepsDirectoryLeaseUntilSettled`, `nonconflictingInstallProceedsWhileOtherDirectoryRuns` (scope control), `reviewerSymlinkAliasCannotBypassDirectoryLease` (alias spelling, 1 config call), `reviewerCaseAliasMissingLeafCannotBypassDirectoryLease` (case-alias spelling, 1 download call), `caseSensitiveVolumeKeepsDistinctDirectoryLeases` (forced-sensitive scope control, 2 calls) | complete-list `rejectRemoteDuplicate` gate + installer markers + canonical directory lease (symlink + case-folded) + owner lock |
| 7 | No secret leakage | `orgWizardEndToEndDeletesTokenAndLeaksNothing`, `runConfigScrubsTokenFromFailure`, `failedConfigDeletesTokenAndReportsScrubbedError`, `cancelDuringConfigKeepsLeaseAndRecoversAfterSettle` | token only in config.sh argv in memory; absent from actions/URLs/headers/bodies; deleted after use |
| 8 | Tests exercise actual entry points | all Flow tests + `setupServiceWritesManualPlistFoundByDiscovery`, `runConfigExecutesRealScript`, `staleRegisterFailureDoesNotUnlockOrPlantFailure`, `scopeChangeClearsCompletedStepsInState`, `leaseKeyCanonicalizesSymlinkAncestorsForMissingLeaf`, `finderAliasInstallFolderIsRefusedBeforeDownload`, `leaseKeyCaseFoldingFollowsVolumeSensitivity` | `Flow.apply`, `RunnerInstallerService.*`, `State.reduce`, cross-checked by `RunnerDiscovery.installed` and a real shell `config.sh` |

Negative/refusal coverage: all v3/v4/v5/v6 negatives retained and green,
plus the adopted rev6 case-alias attack and the R7 sensitive/folding
controls.

## Narrowing-mutant evidence

Changed gate only (M1–M30 unchanged regions not rerun per contract):

| Mutant | Admits exactly | Named failing test(s) | Result |
|--------|----------------|-----------------------|--------|
| M31: folding disabled (`sensitive` forced true; symlink resolution and ordinary path kept) | case-alias spellings only | `reviewerCaseAliasMissingLeafCannotBypassDirectoryLease` (exit 1, 4 issues: 2 download calls, no busy failure, retry re-downloads — the exact R6-F1 signature; evidence print `calls=2` with identical inodes) | KILLED |
| M31 narrowing controls under mutant | — | `beginDraftDuringDownloadKeepsDirectoryLease` (same-spelling class) exit 0; `reviewerSymlinkAliasCannotBypassDirectoryLease` (symlink class) exit 0; `leaseKeyCanonicalizesSymlinkAncestorsForMissingLeaf` exit 0 | RETAINED GREEN |
| M31 revert | — | pristine sha256 `2b0d0bb5…bff29c` verified after revert | REVERTED |

No survivors in M31. Prior M9 (`createGroup` default true→false) survivor
bound restated from v3 (unchanged code, not rerun): the default is not
load-bearing, Flow passes `true` explicitly, M9b kills the call site.

The source-text-token mutant rule does not apply: no gate inspects source
text.

## Verification commands (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` (CI gate):
  **exit 0, 160 tests passed** (157 + 3 R7), 0 issues, full log at
  `/tmp/r7_full.log`.
- Focused R7 trio (adopted regression + sensitive control + folding unit):
  **exit 0, 3 tests passed**; regression prints
  `calls=1` with identical inodes for both spellings.
- M31 mutant runs: case-alias test **exit 1** (4 issues, killed);
  same-spelling + symlink + ancestor controls **exit 0** under the mutant;
  revert sha256 match confirmed.
- `python3 -m unittest discover -s Scripts/tests` (CI gate):
  **exit 0, 4 tests OK**.
- `xcodebuild -workspace RunnerControl.xcworkspace -scheme RunnerControl
  -destination 'platform=macOS' build`: **BUILD SUCCEEDED** (exit 0).
- No repo-configured lint gate (CI `ci.yml` runs only the two test jobs
  above; no `.swiftlint.yml`/`.swiftformat`).
- Bounded validation throughout: every test/build ran under a hard
  subprocess timeout owning its exact process tree; no `pgrep` self-match
  wait; new Flow tests use bounded 10 s start polls that fail fast with
  diagnostics instead of hanging on leaked continuations.
- Generator inputs untouched: `ios-app-manager.json`, `Project.swift`,
  `Workspace.swift`, `Package.swift` unmodified; existing production
  runners untouched (all test IO under temp roots; services never
  bootstrapped); candidate left UNCOMMITTED, no producer commit (branch
  tip still `6b4a21d`).

## Files changed (all UNCOMMITTED in story worktree, as required)

- `Packages/RunnerControlCore/Sources/RunnerInstallerService.swift` —
  case-folded `leaseKey` via real-volume sensitivity,
  `isCaseSensitiveVolume(at:)`, `caseSensitivityOverride` seam.
- `Packages/RunnerControlCore/Tests/RunnerRegistrationTests.swift` —
  adopted `reviewerCaseAliasMissingLeafCannotBypassDirectoryLease` (inode
  proof after settle, documented above),
  `caseSensitiveVolumeKeepsDistinctDirectoryLeases`,
  `leaseKeyCaseFoldingFollowsVolumeSensitivity`, harness override
  passthrough.

## Stated bounds (unknowns, not guesses)

- Live registration smoke remains a separate delivery task; transport
  covered by fakes, filesystem by temp-root fixtures with real
  `tar`/`shasum`/`config.sh`.
- Authenticated download `sha256_checksum` availability was confirmed
  nonempty for osx x64/arm64 by root read-only live API (per revision-4
  contract); this run made no live GitHub calls.
- Pagination cap is 100 pages per list (fail-closed throw, never silent
  partial).
- Mid-step session change is bound by single-auth reuse (no mixing); an
  inter-step change invalidates via `syncServerBinding` plus `.runner`/
  marker verification.
- Ownership table stays per-Mac (`~/Library/GitHubActions/
  .runnercontrol-groups.json`); two local users do not share it.
- A same-directory retry refused with `directoryBusy` mints and deletes a
  short-lived registration token for the register step before reaching the
  lease; the token is never used for a second config and never retained.
- Alias refusal covers alias components in the given installation
  spelling; a symlink that resolves to a target containing an alias
  elsewhere is canonicalized by `leaseKey`, not refused as an alias.
- Case folding uses POSIX-locale lowercasing: exact for ASCII install
  names; exotic Unicode case pairs are approximated, not proven equal to
  APFS rules.
- Unknown/unreadable volumes fail closed to folding (documented above);
  no such volume was observed — the temp and install volumes report
  `volumeSupportsCaseSensitiveNames=false` on this host.
- The adopted regression assumes a case-insensitive installRoot volume
  (default macOS APFS, true here); the forced-sensitive control is
  host-independent.
