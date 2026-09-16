# TASK-260916-13diw4: register-mac-and-repository-access — developer outcome v4

Status: ready for review (board `to-review`, uncommitted candidate in story worktree).

This run fixes ALL THREE revision-3 findings (R3-F1…R3-F3,
`changes_requested`, `repeat-of: revision 2 / R2-F3` for R3-F1/R3-F3 and
`repeat-of: revision 2 / R2-F2` for R3-F2) as one coherent
operation-identity/lifecycle change, adopting the reviewer's exact attack
source as committed named regressions, plus the mid-run directive class
(selection edits during their own mutation). Prior M1–M20 regions were not
rerun per the revision-4 contract (unchanged code); the M9 survivor bound is
restated from v3.

## Fixes (code)

1. **R3-F1 — in-flight completion restores stale progress (repeat-of R2-F3).**
   New `OperationIdentity` (server + scope + install dir + runner name +
   work folder + group) in Models. `Flow.beginDraft`/`updateDraft` bump
   `generation` and clear `working`/`workingStep` when an identity edit lands
   while working, emitting `draftBegan`/`draftUpdated` + `cancelled` so State
   clears `working`. Every step captures `gen` and checks `isStale` after each
   await; stale completions emit nothing. Already-started filesystem/network
   side effects stay on disk/remote for safe recovery; only completion
   ownership is revoked. Reducer mirrors invalidation (including group→runner
   demotion) and `draftBegan` now clears progress. Page names the cancel rule.
2. **R3-F2 — server absent from authorization (repeat-of R2-F2/rev1-F5).**
   `verifiedLocalAgentID` and `scopeMatches` now require `serverHost` with
   `www.github.com`⇔`github.com` normalization; a same-path foreign host never
   matches. Every step loads one auth, `syncServerBinding` drops
   server-bound caches (group/asset/runnerID/pendings) on session change, and
   the same auth serves the whole step (no mid-step reload mixing servers).
   Group ownership is keyed by server+org+name. Register/labels/service verify
   `.runner` host against the session server before any remote write or resume.
3. **R3-F3 — changed work folder reuses old success (repeat-of R2-F3).**
   `verifiedLocalAgentID` now checks `workFolder`; the configured marker
   records `serverHost`+`groupName` (`.runner` omits group) and
   `verifyConfiguredGroup` refuses cross-group resume including pre-recording
   markers. `runConfig` resume verifies full identity instead of returning a
   stale ID. Group edits invalidate registration evidence in Flow and reducer.
4. **Directive — selection edits during their own mutation (R3-F1 class).**
   `workingStep` tracking; `shouldAbandonInFlight` abandons in-flight
   `applyLabels` on labels edits and `applyRepositoryAccess` on repository
   edits, so an older completion can never overwrite the newer visible
   selection or report it as applied. Labels/repos stay editable without
   cancelling unrelated steps (install/register/group).

## AC coverage — 8 of 8 rows driven through production entry points

| # | AC row | Named committed test(s) | Production call site |
|---|--------|-------------------------|----------------------|
| 1 | Org registration without terminal | `orgWizardEndToEndDeletesTokenAndLeaksNothing`, `reviewerInFlightInstallCannotRepopulateChangedDraft` | `Flow.apply` (.beginDraft/.resolveGroup/.downloadAndInstall/.registerRunner/.setupService) |
| 2 | Repo registration without terminal | `repoWizardOmitsRunnerGroup`, `repoRunnerListRequestUsesQueryNotEncodedPath` | same Flow effects; no `runner-groups` traffic, no `--runnergroup` argv |
| 3 | Selected repos are applied | `orgResolveGroupCreatesWithSelectedRepos`, `repoAccessAppliesAndConfirmsRealIDs`, `repositoryConfirmationFollowsPagination`, `inFlightAccessAbandonedWhenRepositoriesEdited` (recovery) | `createGroup` / `setGroupRepositories` + paginated `fetchGroupRepositories` confirm |
| 4 | Repo access and labels changeable | `repoAccessAppliesAndConfirmsRealIDs`, `labelsApplyRequiresRealRunnerIDThenPuts`, `inFlightLabelsAbandonedWhenLabelsEdited` (recovery) | `Flow.apply(.applyRepositoryAccess/.applyLabels)` with verified IDs |
| 5 | Failed ops avoid orphans | `failedConfigDeletesTokenAndReportsScrubbedError`, `registerIsIdempotentAcrossRetries`, `registerRefusesMismatchedRemoteIdentity` | `Flow.registerRunner` (token deleted on every failure path; single mint/config) |
| 6 | Repeated ops avoid duplicates | `registerIsIdempotentAcrossRetries`, `retryResumesFailedDownloadWithoutDuplicates`, `remoteDuplicateWithoutReplaceIsRefusedBeforeToken`, `runnerListFollowsPaginationForDuplicateGuard`, `existingRegistrationBlocksFreshInstall` | complete-list `rejectRemoteDuplicate` gate + installer markers |
| 7 | No secret leakage | `orgWizardEndToEndDeletesTokenAndLeaksNothing`, `runConfigScrubsTokenFromFailure`, `failedConfigDeletesTokenAndReportsScrubbedError` | token only in config.sh argv in memory; absent from actions/URLs/headers/bodies; deleted after use |
| 8 | Tests exercise actual entry points | all Flow tests + `setupServiceWritesManualPlistFoundByDiscovery`, `runConfigExecutesRealScript`, `runConfigRefusesWorkFolderMismatchOnResume`, `scopeChangeClearsCompletedStepsInState` | `Flow.apply`, `RunnerInstallerService.*`, `State.reduce`, cross-checked by `RunnerDiscovery.installed` and a real shell `config.sh` |

Negative/refusal coverage (each fails when the gate admits what it must
reject): all v3 negatives retained and green, plus the three adopted reviewer
attacks, `inFlightRegistrationCannotAttributeOldConfigToNewDraft`,
`inFlightGroupCannotResolveForEditedDraft`,
`inFlightLabelsCannotWriteForEditedDraft`,
`nonIdentityEditDuringInstallDoesNotCancel` (non-cancellation control),
`serverChangeBetweenStepsInvalidatesGroupAndRunner`,
`groupOwnershipIsScopedToServer`,
`enterpriseGroupDoesNotReuseGithubOwnership`,
`groupChangeRefusesOldConfiguredSuccess`,
`runConfigRefusesWorkFolderMismatchOnResume`,
`inFlightLabelsAbandonedWhenLabelsEdited`,
`inFlightAccessAbandonedWhenRepositoriesEdited`, and the extended
`verifiedLocalAgentIDRefusesEachMismatchClass` (foreign-server + work-folder
members) and `operationIdentityNormalizationAndChangeDetection` pins.

## Narrowing-mutant evidence (this run, each reverted pristine via `cmp`)

New/changed gates only (M1–M20 unchanged regions not rerun per contract):

| Mutant | Admits exactly | Named failing test(s) | Result |
|--------|----------------|-----------------------|--------|
| M21: `identityFieldsChanged` skips name check | renamed-runner in-flight members only | `inFlightRegistrationCannotAttributeOldConfigToNewDraft` (3 issues: stale 4242/registered), `inFlightLabelsCannotWriteForEditedDraft` (2 issues: PUT+applied), `operationIdentityNormalizationAndChangeDetection` (1 issue) | KILLED, exit 1; `inFlightGroup` control passes |
| M22: `scopeMatches` skips host check | same-path foreign-host members only | `reviewerForeignServerIdentityCannotAuthorizeLabels` (2 issues: PUT sent, no failure), `verifiedLocalAgentIDRefusesEachMismatchClass` (2 issues) | KILLED, exit 1; `orgWizardEndToEnd` same-server control passes |
| M23: `verifiedLocalAgentID` skips work check | work-folder mismatch members only | `reviewerChangedWorkFolderCannotReuseConfiguredSuccess` (2 issues: registered emitted), `runConfigRefusesWorkFolderMismatchOnResume` (1 issue), pin (2 issues) | KILLED, exit 1; `serviceRefusesMismatchedLocalRegistration` (name class) passes |
| M24: `verifyConfiguredGroup` always returns | cross-group resume members only | `groupChangeRefusesOldConfiguredSuccess` (3 issues: registered emitted, no failure) | KILLED, exit 1; `reviewerChangedWorkFolder` + `registerIsIdempotent` controls pass |
| M25: `ownershipKey` omits server | cross-server ownership reuse only | `groupOwnershipIsScopedToServer` (1 issue: enterprise load hit), `enterpriseGroupDoesNotReuseGithubOwnership` (1 issue: adopted) | KILLED, exit 1; `ownedGroupResolvesWithoutRetakeover` same-server control passes |
| M26: `syncServerBinding` skips invalidation | cross-server cache reuse only | `serverChangeBetweenStepsInvalidatesGroupAndRunner` (2 issues: PUT sent, no re-resolve failure) | KILLED, exit 1; `repoAccessAppliesAndConfirmsRealIDs` same-server control passes |
| M27: `shouldAbandonInFlight` identity-only | stale selection completions only | `inFlightLabelsAbandonedWhenLabelsEdited` (4 issues: PUT+applied, draft clobbered to old), `inFlightAccessAbandonedWhenRepositoriesEdited` (1 issue) | KILLED, exit 1; `nonIdentityEditDuringInstallDoesNotCancel` control passes |

No survivors in M21–M27. Prior M9 (`createGroup` default true→false)
survivor bound restated from v3 (unchanged code, not rerun): the default is
not load-bearing, Flow passes `true` explicitly, M9b kills the call site.

The source-text-token mutant rule does not apply: no gate inspects source
text.

## Verification commands (real exit codes, `pipefail` where piped)

- `swift test --package-path Packages/RunnerControlCore` (CI gate):
  **exit 0, 147 tests passed** (132 + 3 adopted + 12 new R4/directive).
- `python3 -m unittest discover -s Scripts/tests` (CI gate): **exit 0,
  4 tests OK**.
- `xcodebuild -workspace RunnerControl.xcworkspace -scheme RunnerControl
  -destination 'platform=macOS' build`: **BUILD SUCCEEDED** (exit 0).
- No repo-configured lint gate (CI runs only the two test jobs above;
  no `.swiftlint.yml`; default swiftlint already fails on main per v1 notes).
- Generator inputs untouched: `ios-app-manager.json`, `Project.swift`,
  `Workspace.swift`, `Package.swift` unmodified (no new source files added);
  existing production runners untouched (all test IO under temp roots;
  services never bootstrapped).

## Files changed (all UNCOMMITTED in story worktree, as required)

- `Packages/RunnerControlCore/Sources/RunnerRegistration+Models.swift` —
  `OperationIdentity` + server normalization.
- `…/RunnerRegistration+Gates.swift` — server-bound `verifiedLocalAgentID` /
  `scopeMatches`, work-folder check, `identityFieldsChanged`.
- `…/RunnerInstallerService.swift` — marker `serverHost`/`groupName`,
  server-scoped ownership, verified `runConfig` resume,
  `verifyConfiguredGroup`, server-bound install reuse.
- `…/RunnerRegistration+Flow.swift` — generation abandonment on identity and
  selection edits, `workingStep`, `syncServerBinding`, single-auth steps,
  verified resume/labels/service.
- `…/RunnerRegistration+State+Reducer.swift` — mirrored group→registration
  invalidation, `draftBegan` progress clear.
- `Targets/RunnerControl/Sources/RunnerRegistrationPage.swift` — working-edit
  cancel hint.
- `Packages/RunnerControlCore/Tests/RunnerRegistrationTests.swift` — 3
  verbatim reviewer regressions + 12 R4/directive tests, latch harnesses,
  `SplitExecutor` work-folder fidelity, server-scoped ownership calls.

## Stated bounds (unknowns, not guesses)

- Live registration smoke remains a separate delivery task; transport covered
  by fakes, filesystem by temp-root fixtures with real `tar`/`shasum`/`config.sh`.
- Authenticated download `sha256_checksum` availability was confirmed
  nonempty for osx x64/arm64 by root read-only live API (per revision-4
  contract); this run did not make live GitHub calls.
- Pagination cap is 100 pages per list (fail-closed throw, never silent
  partial).
- Mid-step session change (identity swap between two awaits inside one step)
  is bound by single-auth reuse (no mixing); an inter-step change invalidates
  via `syncServerBinding` plus `.runner`/marker verification.
- Ownership table stays per-Mac (`~/Library/GitHubActions/
  .runnercontrol-groups.json`); two local users do not share it. Pre-revision-4
  ownership entries (no server) and configured markers (no group) fail closed
  toward explicit takeover/reconfiguration, never silent adoption.
