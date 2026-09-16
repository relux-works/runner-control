# TASK-260916-13diw4: register-mac-and-repository-access — developer outcome v3

Status: ready for review (board `to-review`, uncommitted candidate in story worktree).

This run fixes ALL FIVE revision-2 review findings (R2-F1…R2-F5,
`changes_requested`, `repeat-of: revision 1 / F5` for R2-F2) with the
reviewer's production-entry attacks adopted as committed named regressions,
plus narrowing mutants for every new gate. Prior M1–M12 evidence was
re-executed against the reworked code (M9 still survives with the same
stated bound).

## Fixes (code)

1. **R2-F1 — list URLs used encoded `%3F` paths.** `GitHubRunnerAPIClient`
   now builds list URLs via `URLComponents` with real `per_page=100` query
   items (`listURL`); the `?`-in-`appendingPathComponent` shape is gone from
   all three list methods (runners, groups, group repositories).
2. **R2-F2 — remote name match authorized foreign writes (repeat-of rev1/F5).**
   New `LocalRegistration` read (`RunnerInstallerService.readLocalRegistration`)
   plus gates `verifiedLocalAgentID` (configured marker + agent ID + name +
   scope match) and `boundRemoteRunnerID` (bind by verified agent ID; same-name
   foreign or renamed entries throw; absent-without-name returns nil for
   convergence). `registerRunner` verifies after config and on resume;
   `applyLabels` verifies before any network and re-binds on every write —
   the stored ID is never trusted across edits/retries/drift. The old
   name-match `resolveRemoteRunnerID` is deleted.
3. **R2-F3 — scope/path edits reused old evidence.** `Flow.updateDraft` and
   the reducer invalidate progress on scope/install-dir/name/group/workFolder
   changes (selective matrices, mirrored): install/runner/group/asset state
   and `completedSteps` drop, `.done` demotes to `.drafting`, stale
   `failedStep`s clear, editable selections re-target pending retries to the
   visible values. Retry-after-scope-change is a safe no-op.
4. **R2-F4 — first-page reads reported as complete.** All three list methods
   follow `Link: rel="next"` to completion (`getAllPages`, same-host HTTPS
   only, 100-page fail-closed cap); any failed page throws.
   `applyRepositoryAccess` compares the complete confirm against the request
   (`confirmRepositoryIDs`, both directions) and keeps the requested
   selection on mismatch instead of claiming partial success.
5. **R2-F5 — service setup claimed done before registration.**
   `setupService` requires the verified configured local identity; the Page
   disables Setup Service until `registerRunner` completes and names the
   prerequisite.

## AC coverage — 8 of 8 rows driven through production entry points

| # | AC row | Named committed test(s) | Production call site |
|---|--------|-------------------------|----------------------|
| 1 | Org registration without terminal | `orgWizardEndToEndDeletesTokenAndLeaksNothing` (now ID-bound 4242/4242) | `Flow.apply` (.beginDraft/.resolveGroup/.downloadAndInstall/.registerRunner/.setupService) |
| 2 | Repo registration without terminal | `repoWizardOmitsRunnerGroup`, `repoRunnerListRequestUsesQueryNotEncodedPath` | same Flow effects; no `runner-groups` traffic, no `--runnergroup` argv |
| 3 | Selected repos are applied | `orgResolveGroupCreatesWithSelectedRepos`, `repoAccessAppliesAndConfirmsRealIDs`, `repositoryConfirmationFollowsPagination` | `createGroup` / `setGroupRepositories` + paginated `fetchGroupRepositories` confirm |
| 4 | Repo access and labels changeable | `repoAccessAppliesAndConfirmsRealIDs`, `labelsApplyRequiresRealRunnerIDThenPuts` (rewritten: not-found then bound PUT 4242) | `Flow.apply(.applyRepositoryAccess/.applyLabels)` with verified IDs |
| 5 | Failed ops avoid orphans | `failedConfigDeletesTokenAndReportsScrubbedError`, `registerIsIdempotentAcrossRetries`, `registerRefusesMismatchedRemoteIdentity` | `Flow.registerRunner` (token deleted on every failure path; single mint/config) |
| 6 | Repeated ops avoid duplicates | `registerIsIdempotentAcrossRetries`, `retryResumesFailedDownloadWithoutDuplicates`, `remoteDuplicateWithoutReplaceIsRefusedBeforeToken`, `runnerListFollowsPaginationForDuplicateGuard`, `existingRegistrationBlocksFreshInstall` | complete-list `rejectRemoteDuplicate` gate + installer markers |
| 7 | No secret leakage | `orgWizardEndToEndDeletesTokenAndLeaksNothing`, `runConfigScrubsTokenFromFailure`, `failedConfigDeletesTokenAndReportsScrubbedError` | token only in config.sh argv in memory; absent from actions/URLs/headers/bodies; deleted after use |
| 8 | Tests exercise actual entry points | all Flow tests + `setupServiceWritesManualPlistFoundByDiscovery`, `runConfigExecutesRealScript`, `scopeChangeClearsCompletedStepsInState` | `Flow.apply`, `RunnerInstallerService.*`, `State.reduce`, cross-checked by `RunnerDiscovery.installed` and a real shell `config.sh` |

Negative/refusal coverage (each fails when the gate admits what it must
reject): all v2 negatives retained, plus `labelsWithoutLocalRegistrationAreRefused`
(zero network), `labelsWithMismatchedRemoteIdentityAreRefused`,
`registerRefusesMismatchedRemoteIdentity`, `labelsRefusePlantedUnconfiguredRegistration`,
`changedScopeMustNotReuseRegistrationOrRemoteID`,
`installDirChangeKeepsGroupButRequiresFreshInstall`,
`groupNameChangeInvalidatesResolvedGroup`, `retryAfterScopeChangeIsNoop`,
`repositoryConfirmationMismatchIsRefused` (both directions),
`repositorySecondPageFailurePreservesUnknown`,
`serviceCannotClaimDoneBeforeRegistration`,
`serviceRefusesMismatchedLocalRegistration`, and the pure-gate pins
`verifiedLocalAgentIDRefusesEachMismatchClass` /
`boundRemoteRunnerIDBindsByID` / `scopeChangeRefreshesDownloadAsset` /
`registerReportsNilWhenAgentNotYetListed`.

## Narrowing-mutant evidence (this run, each reverted pristine via `cmp`)

New gates:

| Mutant | Admits exactly | Named failing test(s) | Result |
|--------|----------------|-----------------------|--------|
| M13: runners path carries `?per_page=100` | encoded runners URL only | `orgListRequestsUseQueryNotEncodedPath` | KILLED, 2 issues; groups control passes |
| M14: name check admits `"someone-else"` | one wrong-name member | `serviceRefusesMismatchedLocalRegistration`, `verifiedLocalAgentIDRefusesEachMismatchClass` | KILLED, 3 + 1 issues (mutant wrote the plist) |
| M15: same-name returns `foreign.id` | one foreign-ID member (R2-F2 class) | `labelsWithMismatchedRemoteIdentityAreRefused`, `registerRefusesMismatchedRemoteIdentity` | KILLED, 7 issues (mutant PUT to `/runners/77/labels`); nil-absence control passes |
| M16: scope branch skipped | scope-change reuse only | `scopeChangeRefreshesDownloadAsset` | KILLED, 2 issues (stale asset reused); dir-branch control passes |
| M17: `nextPageURL` skips `/repositories` | repo-second-page skip only | `repositoryConfirmationFollowsPagination` | KILLED, 2 issues; runners/groups pagination controls pass |
| M18: setupService skips verification | unverified-service member only | `serviceCannotClaimDoneBeforeRegistration` | KILLED, 3 issues (mutant emitted serviceReady + plist); labels gate intact |
| M19: confirm admits subsets | subset member only | `repositoryConfirmationMismatchIsRefused` | KILLED, 3 issues on missing-direction only; extras-direction passes |
| M20: unconfigured admitted when name present | one planted member | `labelsRefusePlantedUnconfiguredRegistration`, `verifiedLocalAgentIDRefusesEachMismatchClass` | KILLED, 3 + 1 issues (mutant PUT); other 4 pin cases pass |

Re-executed prior mutants (adjacent/touched regions included):
M1, M2, M3, M4, M5, M6, M7, M8, M9b, M10, M11, M12 — all KILLED by their
v2-named tests. M9 (`createGroup` default true→false) still SURVIVES
(exit 0) with the same bound: the default is not load-bearing, Flow passes
`true` explicitly, M9b kills the call site. Bound stated, not hidden.

The source-text-token mutant rule does not apply: no gate inspects source
text.

## Verification commands (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` (CI gate):
  **exit 0, 132 tests passed** (110 + 22 new R2 regressions/pins).
- `python3 -m unittest discover -s Scripts/tests` (CI gate): **exit 0,
  4 tests OK**.
- `xcodebuild -workspace RunnerControl.xcworkspace -scheme RunnerControl
  -destination 'platform=macOS' build`: **BUILD SUCCEEDED** (exit 0);
  warnings are the pre-existing Swift 6 Sendable class on untouched lines
  (Page 157/216/242/248/288 etc.); the `stepRow(enabled:)` change adds none.
- No repo-configured lint gate (CI runs only the two test jobs above).
- Generator inputs untouched: `ios-app-manager.json`, `Project.swift`,
  `Workspace.swift`, `Package.swift` files unmodified (no new source files
  added, so no `tuist generate` needed); existing production runners
  untouched (all test IO under temp roots; services never bootstrapped).

## Files changed (all UNCOMMITTED in story worktree, as required)

- `Packages/RunnerControlCore/Sources/GitHubRunnerAPIClient.swift` —
  `listURL`/`perform`/`getAllPages`/`nextPageURL`; paginated runners/groups/
  group-repositories.
- `…/RunnerRegistration+Models.swift` — `LocalRegistration`,
  `unverifiedRegistration`/`remoteIdentityMismatch`/`remoteRunnerNotFound`/
  `confirmationMismatch` errors.
- `…/RunnerRegistration+Gates.swift` — `verifiedLocalAgentID`,
  `scopeMatches`, `boundRemoteRunnerID`, `confirmRepositoryIDs`.
- `…/RunnerInstallerService.swift` — `readLocalRegistration`
  (`readAgentID` delegates, behavior-identical).
- `…/RunnerRegistration+Flow.swift` — verified identity for
  register/labels/service, confirm-compare, `invalidateProgress` matrix.
- `…/RunnerRegistration+State+Reducer.swift` — mirrored invalidation +
  `.done` demotion on identity edits.
- `Targets/RunnerControl/Sources/RunnerRegistrationPage.swift` — Setup
  Service gated on `registerRunner` completion with prerequisite copy.
- `Packages/RunnerControlCore/Tests/RunnerRegistrationTests.swift` — 5
  fixtures re-bound to verified IDs (77/78/99→4242), labels test rewritten,
  22 new R2 regression/pin tests, scope-aware `SplitExecutor`.

## Stated bounds (unknowns, not guesses)

- Live checksum availability on the authenticated downloads endpoint is
  still unverified (separate smoke task); the client decodes optional
  `sha256_checksum` per the official OpenAPI schema and fails closed when
  absent.
- Pagination cap is 100 pages per list (fail-closed throw, never a silent
  partial list).
- Retry runs the *current* draft, not a snapshot — now safe because caches
  invalidate on identity edits and every write re-binds to verified local
  identity.
- Ownership table stays per-Mac (`~/Library/GitHubActions/
  .runnercontrol-groups.json`); two local users do not share it.
- No live-GitHub verification in this run; transport covered by fakes, the
  filesystem by temp-root fixtures with real `tar`/`shasum`/`config.sh`.
