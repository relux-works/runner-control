# TASK-260916-13diw4: register-mac-and-repository-access — developer outcome

Status: ready for review (board `to-review`, uncommitted candidate in story worktree).

## What was delivered

New-runner wizard through the GitHub API, wired through the existing Relux
stack (Page → Container → Effect/Flow → actor services → Action/Reducer →
State). The worktree already contained a staged wizard implementation (99
green tests); this run kept that architecture and closed the four review-focus
gaps from `review-focus-live-and-scope.md` plus all six demonstrated failures
(F1–F6) from the prior Astra review rev1 (`changes_requested`,
`repeat-of: none`):

1. **`allows_public_repositories`** — dedicated groups now opt in on create
   (`POST …/runner-groups` sends `allows_public_repositories: true`) and an
   adopted owned group that denies public repos is patched
   (`PATCH …/runner-groups/{id}`). Without this GitHub's default (`false`)
   silently drops every selected public repo even though `visibility:
   selected` lists it. `RunnerGroup` now carries the flag and the UI shows it.
2. **Unconditional `config --replace`** — removed. `ConfigInvocation` omits
   `--replace` unless `Draft.allowReplace` (explicit UI toggle) is set, and
   `Flow.registerRunner` refuses a remote name match *before minting any
   registration token* (`remoteNameTaken`), so a duplicate name can never
   silently steal another Mac's registration. New errors, gates, tests.
3. **Group-name reuse ownership** — a name match alone no longer authorizes
   adoption. `RunnerInstallerService` keeps an ownership table at
   `<installRoot>/.runnercontrol-groups.json` (`org ␀ name → groupID`);
   `Flow.resolveGroup` requires either a matching ownership entry or explicit
   `Draft.allowGroupTakeover` (UI toggle), else `groupNameTaken`. Creation and
   takeover record ownership so retries on this Mac reuse without re-confirming.
4. **Checksum availability (F1)** — GitHub's downloads endpoint documents
   `sha256_checksum`, so the installer now fails closed: a missing/empty
   checksum throws `integrityMismatch` instead of skipping verification.
5. **HTTP 204 rejected (F2)** — `PUT …/runner-groups/{id}/repositories`
   answers `204 No Content` in production, but the client accepted only
   200/201, failing every production repo-access update. `send()` now accepts
   204; only the two body-ignoring PUTs can legally return it.
6. **Post-config token retention (F6)** — when the follow-up runner-ID lookup
   failed after a successful `config.sh`, the single-use registration token
   stayed in Keychain. The token is now deleted immediately after config
   succeeds (it is consumed at that point), before any follow-up API call.

Supporting changes: `fetchRunners`/`fetchGroups` use `per_page=100`; new
`updateGroupAllowsPublic` client call; `runConfig` threads the explicit
`replace` flag; Container/Page wire the two new consent toggles.

## AC coverage — 8 of 8 rows driven through production entry points

| # | AC row | Named committed test(s) | Production call site |
|---|--------|-------------------------|----------------------|
| 1 | Org registration without terminal | `orgWizardEndToEndDeletesTokenAndLeaksNothing` | `RunnerRegistration.Flow.apply` (.beginDraft/.resolveGroup/.downloadAndInstall/.registerRunner/.setupService) |
| 2 | Repo registration without terminal | `repoWizardOmitsRunnerGroup` | same Flow effects; asserts no `runner-groups` traffic, no `--runnergroup` argv |
| 3 | Selected repos are applied | `orgResolveGroupCreatesWithSelectedRepos`, `repoAccessAppliesAndConfirmsRealIDs` | `GitHubRunnerAPIClient.createGroup` / `setGroupRepositories` + `fetchGroupRepositories` confirm |
| 4 | Repo access and labels changeable | `repoAccessAppliesAndConfirmsRealIDs` ([9]→[9,10]), `labelsApplyRequiresRealRunnerIDThenPuts` | `Flow.apply(.applyRepositoryAccess/.applyLabels)` → `setGroupRepositories` / `setRunnerLabels` with real IDs |
| 5 | Failed ops avoid orphans | `failedConfigDeletesTokenAndReportsScrubbedError`, `registerIsIdempotentAcrossRetries` | `Flow.registerRunner` (token deleted on config failure; single mint + single config across retries) |
| 6 | Repeated ops avoid duplicates | `registerIsIdempotentAcrossRetries`, `retryResumesFailedDownloadWithoutDuplicates`, `remoteDuplicateWithoutReplaceIsRefusedBeforeToken`, `existingRegistrationBlocksFreshInstall` | `Flow.registerRunner` resume path + `rejectRemoteDuplicate` gate; installer markers |
| 7 | No secret leakage | `orgWizardEndToEndDeletesTokenAndLeaksNothing`, `runConfigScrubsTokenFromFailure`, `failedConfigDeletesTokenAndReportsScrubbedError` | token reaches only config.sh argv in memory; absent from actions/URLs/headers/bodies; scrubbed from errors; deleted after use |
| 8 | Tests exercise actual entry points | all Flow tests above + `setupServiceWritesManualPlistFoundByDiscovery`, `runConfigExecutesRealScript` | `Flow.apply`, `RunnerInstallerService.downloadAndInstall/runConfig/setupService`, cross-checked by `RunnerDiscovery.installed` and a real shell `config.sh` |

Negative/refusal coverage (all fail when the gate admits what it must reject):
`beginDraftRefusesSpacesBeforeAnyNetwork`, `installerRefusesSpacesWithoutDownloading`,
`beginDraftRequiresNameAndLabels`, `unauthenticatedWizardFailsClosedWithoutNetwork`,
`prepareDownloadRefusesSubstituteArch`, `downloadRefusesTamperedBytes`,
`downloadRefusesMalformedChecksum`, `downloadRefusesMissingChecksum`,
`existingRegistrationBlocksFreshInstall`, `existingGroupNameWithoutTakeoverIsRefused`,
`repoScopeRefusesGroupResolution`, `repoAccessWithoutExplicitScopeIsRefused`,
`repoAccessToForeignGroupIsRefused`, `remoteDuplicateWithoutReplaceIsRefusedBeforeToken`,
`recoverPartialInstallRefusesWorkingRunner`, `runConfigScrubsTokenFromFailure`,
`permissionErrorRetainedAcrossEditsUntilRetrySucceeds`,
`forbiddenGroupCreateNamesRequiredPermission`, plus the refusal half of
`labelsApplyRequiresRealRunnerIDThenPuts`.

## Narrowing-mutant evidence

Each mutant keeps the gate present and weakens it to admit exactly one member
of the rejected class. All runs are `swift test --package-path
Packages/RunnerControlCore --filter <test>`; files verified pristine (`cmp`)
after each revert.

| Mutant | Narrows the gate to admit | Named failing test | Result |
|--------|---------------------------|--------------------|--------|
| M1: `contains(" ")` → `contains("  ")` on install dir | single-space `"bad dir"` | `beginDraftRefusesSpacesBeforeAnyNetwork` | KILLED, exit 1 (2 issues; the `workFolder` case still passes) |
| M2: `selectDownload` matches OS only | osx/x64 asset for an arm64 Mac | `prepareDownloadRefusesSubstituteArch` | KILLED, exit 1 |
| M3: `authorizeGroupMutation` skips consent when IDs match | unconfirmed write to resolved group 5 | `repoAccessWithoutExplicitScopeIsRefused` | KILLED, exit 1 (mutant reached network: request count grew) |
| M4: `authorizeGroupMutation` additionally admits `targetGroupID == 1` | write to foreign group 1 | `repoAccessToForeignGroupIsRefused` | KILLED, exit 1 (mutant reached network) |
| M5: `requireOrganizationScope` admits `repository(owner: "octo", …)` | `octo/app` repo scope | `repoScopeRefusesGroupResolution` | KILLED, exit 1 |
| M6: `authorizeGroupTakeover` admits `existingID == 5` | name-alone adoption of group 5 | `existingGroupNameWithoutTakeoverIsRefused` | KILLED, exit 1 (3 issues incl. ownership file written) |
| M7: `rejectRemoteDuplicate` admits name `"macbook-test"` | duplicate `macbook-test` | `remoteDuplicateWithoutReplaceIsRefusedBeforeToken` | KILLED, exit 1 (mutant minted a `registration-token` POST) |
| M8: checksum guard restored to skip-when-missing | nil-checksum package | `downloadRefusesMissingChecksum` | KILLED, exit 1 (mutant installed `run.sh`) |
| M9: `createGroup` default `allowsPublicRepositories` true→false | — | `orgResolveGroupCreatesWithSelectedRepos` | SURVIVED, exit 0 — bound: the default is not load-bearing; Flow passes `true` explicitly (see M9b) |
| M9b: Flow call site passes `allowsPublicRepositories: false` | group created denying public repos | `orgResolveGroupCreatesWithSelectedRepos` | KILLED, exit 1 (body `false`, expected `true`) |
| M10: `ConfigInvocation` adds `--replace` when `runnerGroup != nil` | unconsented `--replace` on org runs | `runConfigOmitsReplaceByDefault` | KILLED, exit 1 (argv ended in `--replace`) |
| M11 (F2): `send()` accepts only 200/201 | production 204 repos-PUT fails | `repoAccessAppliesAndConfirmsRealIDs` (204 fixture) | KILLED, exit 1 (no IDs applied) |
| M12 (F6): token deleted only after follow-up succeeds | token retained on post-config API failure | `postConfigAPIFailureDeletesTokenAndReportsError` | KILLED, exit 1 (token still stored) |

The source-text-token mutant rule does not apply: none of these gates inspect
source text (no searched-for token to preserve while changing behavior).

## Verification commands (real exit codes)

- `swift test --package-path Packages/RunnerControlCore` (CI gate): **exit 0,
  110 tests passed** (99 baseline + 11 new: 10 gap tests + F6 regression; F2
  reuses `repoAccessAppliesAndConfirmsRealIDs` with a production-faithful 204
  fixture).
- `xcodebuild -workspace RunnerControl.xcworkspace -scheme RunnerControlCore
  -destination 'platform=macOS' test`: **exit 0, 109 passed** (same suite via
  Xcode, run before the F2/F6 additions; final 110-count proven by the CI
  gate above).
- `xcodebuild -workspace RunnerControl.xcworkspace -scheme RunnerControl
  -destination 'platform=macOS' build`: **BUILD SUCCEEDED** (exit 0) with one
  pre-existing Swift 6 Sendable warning at
  `RunnerRegistrationPage.swift:157` (scope Picker binding, untouched line
  from staged code).
- No repo-configured lint gate (no SwiftLint config in repo; CI runs only the
  two test jobs above). No new compiler warnings introduced.
- Generator inputs untouched: `ios-app-manager.json`, `Project.swift`,
  `Workspace.swift` unmodified (verified via `git status`).

## Files changed (all UNCOMMITTED in story worktree, as required)

- `Packages/RunnerControlCore/Sources/RunnerRegistration+Models.swift` —
  `Draft.allowGroupTakeover/allowReplace`, `RunnerGroup.allowsPublicRepositories`,
  `groupNameTaken`/`remoteNameTaken` errors.
- `…/RunnerRegistration+Gates.swift` — `authorizeGroupTakeover`,
  `rejectRemoteDuplicate`, `ConfigSpec.replace`, conditional `--replace`.
- `…/GitHubRunnerAPIClient.swift` — `allows_public_repositories` decode/encode,
  `updateGroupAllowsPublic`, `per_page=100` on runners/groups lists.
- `…/RunnerInstallerService.swift` — fail-closed checksum, `runConfig`
  replace threading, group-ownership store.
- `…/RunnerRegistration+Flow.swift` — ownership-checked resolve,
  allows-public ensure, pre-token duplicate guard.
- `Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift`,
  `RunnerRegistrationPage.swift` — two consent toggles, public-repos display.
- `Packages/RunnerControlCore/Tests/RunnerRegistrationTests.swift` — 10 new
  tests + updated transports/fixtures for the stricter behavior.

## Stated bounds (unknowns, not guesses)

- Duplicate-name pre-check reads the first runners page (`per_page=100`); a
  duplicate beyond it is still safe because `config.sh` omits `--replace`
  without consent and fails instead of stealing.
- Remote runner IDs are resolved by name match (`resolveRemoteRunnerID`):
  inherent to the classic registration-token flow, which returns no ID;
  the pre-check + fail-closed config bound the collision window but a
  same-name runner created concurrently on another Mac resolves ambiguously.
- Retry runs the *current* draft, not a snapshot: a draft edit between
  failure and retry changes what the retried step executes (review's
  "mutable draft/progress identity" bound, kept as designed behavior).
- Ownership table is per-Mac (`~/Library/GitHubActions/.runnercontrol-groups.json`):
  it distinguishes this Mac's groups from same-name groups on other Macs, but
  two local users on one Mac do not share it (same as installs themselves).
- No live-GitHub verification in this run: real OAuth/registration smoke is a
  separate delivery task per the brief; transport is covered by fakes and the
  filesystem by temp-root fixtures with a real `tar`/`shasum`/`config.sh`.
- The wizard never touches existing production runners: all filesystem writes
  stay under the chosen new install dir + ownership file; no stop, re-register,
  or service bootstrap of existing runners (setup writes the plist only and
  never bootstraps it).
