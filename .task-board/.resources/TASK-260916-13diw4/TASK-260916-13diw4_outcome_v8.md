# TASK-260916-13diw4: register-mac-and-repository-access — developer outcome v8

Status: ready for review (board `to-review`, uncommitted candidate in story worktree).

Focused R8 delivery per `revision8-single-installer-operation.md`, which
supersedes revision7-case-equivalence and all earlier
preserve-independent-directory-concurrency language: instead of another
Unicode path-equivalence patch for R7-F1 (`changes_requested`,
`repeat-of: revision 6 / R6-F1`), the wizard now runs ONE active
installer mutation per app instance. Prior M1–M31 regions were not rerun
per contract (unchanged code); the M9 survivor bound is restated from v3.

## Change (code)

Settled product tradeoff: a second installer mutation for ANY directory
is refused as installer-busy until the first settles. Deliberate
serialization; multiple installed/running CI runners and ordinary
start/stop are unaffected (they never take this lease).

`Packages/RunnerControlCore/Sources/RunnerInstallerService.swift`:

- Removed the per-path lease identity entirely: `activeDirectories`,
  `leaseKey(for:caseSensitiveOverride:)`, `isCaseSensitiveVolume(at:)`,
  `caseSensitivityOverride` seam. No path comparison means no
  filesystem-alias bypass class (symlink, case-fold, Unicode
  equivalence) can exist.
- New single installer-wide lease: `activeOperation: UUID?` (+
  diagnostic-only `activePath`, never compared). `acquireMutationLease`
  runs synchronously before any side effect/await and throws retryable
  `installerBusy` whenever ANY mutation is live; `releaseMutationLease`
  releases only the exact owner token; `requireIdleInstaller` guards the
  synchronous service-setup/recovery paths. Draft cancel/reset still
  abandon UI only — a live mutation keeps the lease until it settles.
- Kept Finder-alias refusal (`ensureNoAlias`): aliases are invalid
  install targets, not a lease-identity question.
- All unrelated behavior preserved: no-space validation, checksum gate,
  exact config invocation, `.runner` server/scope/agent/work-folder
  verification, group verification, token mint/delete hygiene,
  idempotent markers and recovery guards.

`RunnerRegistration+Models.swift`: `directoryBusy` renamed to
`installerBusy(path:)`; message reads "Installer is busy with another
registration operation… Retry after it settles; no second operation was
started." (still contains `busy`, so all retained busy assertions hold).

`RunnerRegistration+Flow.swift`: comment-only updates (UI lock vs
installer-wide lease); no behavior change.

## Tests

Adopted verbatim: `reviewerUnicodeCaseAliasCannotBypassDirectoryLease`
(exact rev7 attack source, production `Flow.apply` entry). Passes with
`calls=1`, busy refusal, identical post-settle inodes, retry reuses.

Converted to explicit global-serialization proofs (+ retry success after
settle), through production `Flow.apply`:

| Test | R8 shape |
|------|----------|
| `secondInstallForAnyDirectoryRefusedWhileInstallerBusy` (was `nonconflictingInstall…`) | different dir refused busy (calls==1), retry installs it (calls==2) |
| `reviewerStaleFailureCannotUnlockNewOperation` (kept reviewer name) | busy stands through stale old failure (exactly 1 failure), retry installs new dir |
| `staleRegisterFailureDoesNotOverwriteBusyFailure` (was `…DoesNotUnlockOrPlantFailure`) | stale config failure plants/clears nothing, retry installs new dir |

Removed with the deleted API (3): `leaseKeyCanonicalizes…`,
`leaseKeyCaseFolding…`, `caseSensitiveVolumeKeeps…`; removal noted
in-file at each site. Retained unchanged and green: symlink alias,
ASCII case alias, Finder alias, same-dir draft/reset/cancel, and both
R4 config-lifecycle regressions.

## AC coverage — 8 of 8 rows driven through production entry points

| # | AC row | Named committed test(s) | Production call site |
|---|--------|-------------------------|----------------------|
| 1 | Org registration without terminal | `orgWizardEndToEndDeletesTokenAndLeaksNothing`, `reviewerInFlightInstallCannotRepopulateChangedDraft`, `reviewerRetryCannotRunTwoConfigsInSameDirectory`, `cancelDuringConfigKeepsLeaseAndRecoversAfterSettle`, `reviewerSymlinkAliasCannotBypassDirectoryLease`, `reviewerCaseAliasMissingLeafCannotBypassDirectoryLease`, `reviewerUnicodeCaseAliasCannotBypassDirectoryLease` | `Flow.apply` (.beginDraft/.resolveGroup/.downloadAndInstall/.registerRunner/.setupService/.retry/.cancel) |
| 2 | Repo registration without terminal | `repoWizardOmitsRunnerGroup`, `repoRunnerListRequestUsesQueryNotEncodedPath` | same Flow effects; no `runner-groups` traffic, no `--runnergroup` argv |
| 3 | Selected repos are applied | `orgResolveGroupCreatesWithSelectedRepos`, `repoAccessAppliesAndConfirmsRealIDs`, `repositoryConfirmationFollowsPagination`, `inFlightAccessAbandonedWhenRepositoriesEdited` | `createGroup` / `setGroupRepositories` + paginated `fetchGroupRepositories` confirm |
| 4 | Repo access and labels changeable | `repoAccessAppliesAndConfirmsRealIDs`, `labelsApplyRequiresRealRunnerIDThenPuts`, `inFlightLabelsAbandonedWhenLabelsEdited` | `Flow.apply(.applyRepositoryAccess/.applyLabels)` with verified IDs |
| 5 | Failed ops avoid orphans | `failedConfigDeletesTokenAndReportsScrubbedError`, `registerIsIdempotentAcrossRetries`, `registerRefusesMismatchedRemoteIdentity`, `cancelDuringConfigKeepsLeaseAndRecoversAfterSettle` (both tokens deleted) | `Flow.registerRunner` (token deleted on every failure path; single mint/config) |
| 6 | Repeated ops avoid duplicates | `registerIsIdempotentAcrossRetries`, `retryResumesFailedDownloadWithoutDuplicates`, `remoteDuplicateWithoutReplaceIsRefusedBeforeToken`, `runnerListFollowsPaginationForDuplicateGuard`, `existingRegistrationBlocksFreshInstall`, `reviewerRetryCannotRunTwoConfigsInSameDirectory` (1 config call), `beginDraftDuringDownloadKeepsDirectoryLease`, `resetDuringDownloadKeepsDirectoryLeaseUntilSettled`, `secondInstallForAnyDirectoryRefusedWhileInstallerBusy` (global serialization + retry), `reviewerSymlinkAliasCannotBypassDirectoryLease` (alias spelling, 1 config call), `reviewerCaseAliasMissingLeafCannotBypassDirectoryLease` (case-alias spelling, 1 download call), `reviewerUnicodeCaseAliasCannotBypassDirectoryLease` (Unicode spelling, 1 download call) | complete-list `rejectRemoteDuplicate` gate + installer markers + installer-wide lease + owner lock |
| 7 | No secret leakage | `orgWizardEndToEndDeletesTokenAndLeaksNothing`, `runConfigScrubsTokenFromFailure`, `failedConfigDeletesTokenAndReportsScrubbedError`, `cancelDuringConfigKeepsLeaseAndRecoversAfterSettle` | token only in config.sh argv in memory; absent from actions/URLs/headers/bodies; deleted after use |
| 8 | Tests exercise actual entry points | all Flow tests + `setupServiceWritesManualPlistFoundByDiscovery`, `runConfigExecutesRealScript`, `staleRegisterFailureDoesNotOverwriteBusyFailure`, `scopeChangeClearsCompletedStepsInState`, `finderAliasInstallFolderIsRefusedBeforeDownload`, `reviewerStaleFailureCannotUnlockNewOperation` | `Flow.apply`, `RunnerInstallerService.*`, `State.reduce`, cross-checked by `RunnerDiscovery.installed` and a real shell `config.sh` |

Negative/refusal coverage: all retained v3–v7 negatives green, plus the
adopted rev7 Unicode attack and the R8 serialization/stale-busy controls.

## Narrowing-mutant evidence

Changed gate only (M1–M31 unchanged regions not rerun per contract):

| Mutant | Admits exactly | Named failing test(s) | Result |
|--------|----------------|-----------------------|--------|
| M32: `acquireMutationLease` weakened to same-path-only refusal (`activeOperation == nil \|\| activePath != directory.path`); gate present elsewhere, `requireIdleInstaller` untouched | concurrent different-directory mutations only | `secondInstallForAnyDirectoryRefusedWhileInstallerBusy` (exit 1, 3 issues: 2 download calls, no busy failure) | KILLED |
| M32 narrowing controls under mutant | — | `beginDraftDuringDownloadKeepsDirectoryLease`, `reviewerRetryCannotRunTwoConfigsInSameDirectory` (same-path class) exit 0 | RETAINED GREEN |
| M32 revert | — | pristine sha256 `7d3b98e9…cf7d5` verified after revert | REVERTED |

No survivors in M32. Prior M9 (`createGroup` default true→false)
survivor bound restated from v3 (unchanged code, not rerun).

The source-text-token mutant rule does not apply: no gate inspects
source text.

## Verification commands (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` (CI gate):
  **exit 0, 158 tests passed** (160 − 3 removed + 1 adopted), 0 issues,
  full log at `/tmp/r8_full.log`.
- Focused R8 quartet (serialization + Unicode + 2 stale-busy):
  **exit 0, 4 passed**; Unicode prints `calls=1` with identical inodes.
- Retained 7 lifecycle controls: **exit 0, 7 passed**.
- M32 mutant: serialization test **exit 1** (3 issues, killed);
  same-path controls **exit 0** under mutant; revert sha256 match.
- `python3 -m unittest discover -s Scripts/tests` (CI gate):
  **exit 0, 4 tests OK**.
- `xcodebuild -workspace RunnerControl.xcworkspace -scheme RunnerControl
  -destination 'platform=macOS' build`: **BUILD SUCCEEDED** (exit 0).
- No repo-configured lint gate (CI `ci.yml` runs only the two test jobs
  above; no `.swiftlint.yml`/`.swiftformat`). `git diff --check` clean.
- Bounded validation: every gate ran under a hard subprocess timeout in
  its own process group (`start_new_session` + `os.killpg` on timeout,
  fixed mid-run per supervisor nudge — the first harness killed only the
  parent). One intermediate focused run timed out (exit 124) on a test
  bug of mine (retry's second latch download never released); no green
  is claimed from it — the bug was fixed (`release(2)` choreography)
  and every green above is a completed exit-0 run. No `pgrep` waits;
  no leftover helpers (`ps` clean). Latched tests use bounded start
  polls that fail fast with diagnostics.
- Generator inputs untouched (`Project.swift`, `Workspace.swift`,
  `Package.swift`, `ios-app-manager.json` unmodified); existing
  production runners untouched (all test IO under temp roots; services
  never bootstrapped); candidate left UNCOMMITTED, no producer commit
  (branch tip still `6b4a21d`).

## Files changed (all UNCOMMITTED in story worktree, as required)

- `Packages/RunnerControlCore/Sources/RunnerInstallerService.swift` —
  installer-wide lease replaces per-path identity; alias refusal kept.
- `Packages/RunnerControlCore/Sources/RunnerRegistration+Models.swift` —
  `directoryBusy` → `installerBusy` with installer-busy wording.
- `Packages/RunnerControlCore/Sources/RunnerRegistration+Flow.swift` —
  comment-only (lease terminology).
- `Packages/RunnerControlCore/Tests/RunnerRegistrationTests.swift` —
  adopted Unicode regression, 3 serialization conversions, 3 obsolete
  removals, harness seam removal.
