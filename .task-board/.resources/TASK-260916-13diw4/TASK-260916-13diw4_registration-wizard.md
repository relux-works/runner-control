# TASK-260916-13diw4 — new-runner registration wizard (developer outcome)

Status: ready for review. Candidate left UNCOMMITTED in the Story worktree for handoff snapshot.

## What was built

A Relux `RunnerRegistration` module (actor services, State/Reducer/Flow, Module) plus a
Container+Page wizard sheet in the management window. The wizard registers this Mac as a
GitHub Actions runner without the terminal:

- Architecture-matched official download (`osx` + `arm64`/`x64`) picked from the GitHub
  downloads endpoint; SHA-256 verified against the asset checksum before extraction.
- No-space install (`~/Library/GitHubActions/<dir>`) and work-folder gates enforced before
  any network or filesystem mutation.
- Scoped short-lived registration token: Keychain-only
  (`works.relux.runnercontrol.runner-registration-token`), single use, deleted after
  `config.sh` succeeds or fails; never in Relux state, actions, logs, or diagnostics.
- Exact `config.sh` invocation (`--url/--token/--name/--work/--labels [--runnergroup]
  --unattended --replace`); org scope passes the dedicated per-Mac group, repo scope omits it.
- `bin/runsvc.sh` copied to the install root and chmodded `0o755` (official `svc.sh` behavior);
  manual `manual-service.plist` written with `RunAtLoad=false`, never bootstrapped at install.
- Org scope resolves a dedicated per-Mac group (find by name or create with
  `visibility=selected` + selected repo IDs); repo scope never touches groups.
- Repository access and labels editable after registration via
  `PUT .../runner-groups/{id}/repositories` and `PUT .../runners/{id}/labels`.
- Idempotent retries: install/config/service markers skip completed steps; a configured
  directory never mints a second token; partial dirs recover without touching registrations.
- Real IDs fetched (group id, group repos, runner id matched by name, local agent id from
  `.runner`); 403s mapped to concrete missing permissions and RETAINED in state across
  draft edits until explicit retry success/reset/dismiss.
- Group guard: mutations require explicit UI scope (`allowGroupMutation`) AND target ==
  resolved dedicated group id; anything else is refused with zero network calls.

## Files

New Core (Packages/RunnerControlCore/Sources): `RunnerRegistration.swift`,
`RunnerRegistration+Models.swift`, `RunnerRegistration+Gates.swift`,
`RunnerRegistration+State.swift`, `RunnerRegistration+State+Reducer.swift`,
`RunnerRegistration+Flow.swift`, `RunnerRegistration+Module.swift`,
`RunnerRegistrationTokenStore.swift`, `RunnerInstallerService.swift`,
`GitHubRunnerAPIClient.swift`. Modified: `RunnerRuntime.swift` (registers the module).
New tests: `Packages/RunnerControlCore/Tests/RunnerRegistrationTests.swift` (35 tests).
New UI: `Targets/RunnerControl/Sources/RunnerRegistrationPage.swift`,
`RunnerRegistrationContainer.swift`. Modified UI wiring: `App.swift`, `AppRegistry.swift`,
`ManagementWindowContainer.swift`, `ManagementWindowPage.swift`,
`ManagementWindowPage+Props.swift` ("Добавить раннер…" button + sheet).
No generator inputs changed (pure source files under existing globs); `Project.swift` /
`Package.swift` untouched; `tuist generate --no-open` re-ran to pick up new files.

## AC coverage: 21 of 21 rows driven through production entry points

| # | AC row | Named test | Production call site |
|---|--------|------------|----------------------|
| 1 | Org registration without terminal | orgWizardEndToEndDeletesTokenAndLeaksNothing | `RunnerRegistration.Flow.apply(.beginDraft/.resolveGroup/.downloadAndInstall/.registerRunner/.setupService)` |
| 2 | Repo registration without terminal | repoWizardOmitsRunnerGroup | same Flow effects, repo scope |
| 3 | Selected repos applied | orgResolveGroupCreatesWithSelectedRepos | `Flow.apply(.resolveGroup)` → `GitHubRunnerAPIClient.createGroup` |
| 4 | Repo access changeable | repoAccessAppliesAndConfirmsRealIDs | `Flow.apply(.applyRepositoryAccess)` → `setGroupRepositories` + confirm fetch |
| 5 | Labels editable | labelsApplyRequiresRealRunnerIDThenPuts | `Flow.apply(.applyLabels)` → `setRunnerLabels` |
| 6 | Retries avoid orphan/duplicate registrations | registerIsIdempotentAcrossRetries; existingRegistrationBlocksFreshInstall; retryResumesFailedDownloadWithoutDuplicates | `Flow.apply(.registerRunner/.retry)`; `RunnerInstallerService.downloadAndInstall` |
| 7 | No secret leakage | orgWizardEndToEnd…; runConfigScrubsTokenFromFailure; failedConfigDeletesTokenAndReportsScrubbedError | `Flow.apply(.registerRunner)`; `RunnerInstallerService.runConfig` + `GitHubAuth.Redaction.sanitize` |
| 8 | Arch-matched official download | prepareDownloadSelectsArchMatchedAsset; prepareDownloadRefusesSubstituteArch | `Flow.apply(.prepareDownload)` → `Gates.selectDownload` |
| 9 | Integrity verification | downloadVerifiesIntegrityAgainstSystemShasum; downloadRefusesTamperedBytes; downloadRefusesMalformedChecksum | `RunnerInstallerService.downloadAndInstall` (pinned vs `/usr/bin/shasum`) |
| 10 | No-space install/work paths | beginDraftRefusesSpacesBeforeAnyNetwork (2 cases); installerRefusesSpacesWithoutDownloading | `Flow.apply(.beginDraft)` → `Gates.validateNoSpace`; installer pre-download gate |
| 11 | Scoped short-lived token | orgWizardEndToEnd…; registrationTokenStoreExpiresShortLivedToken; failedConfig… | `GitHubRunnerAPIClient.createRegistrationToken`; `RunnerRegistrationTokenStore` |
| 12 | Exact config invocation | configInvocationIsExactAndOrdered; runConfigUsesExactInvocation | `ConfigInvocation.arguments`; `RunnerInstallerService.runConfig` |
| 13 | runsvc.sh setup | downloadVerifiesIntegrityAgainstSystemShasum | `RunnerInstallerService.installRunsvc` (copy + 0o755) |
| 14 | Manual LaunchAgent | setupServiceWritesManualPlistFoundByDiscovery | `RunnerInstallerService.setupService` → found by `RunnerDiscovery.installed` |
| 15 | Idempotent retries + recovery | retryResumes…; registerIsIdempotent…; recoverPartialInstallRefusesWorkingRunner | `Flow.apply(.retry)`; markers; `recoverPartialInstall` |
| 16 | Dedicated per-Mac group + repo access | orgResolveGroupFindsExistingWithoutCreating; orgResolveGroupCreatesWithSelectedRepos | `Flow.apply(.resolveGroup)` → `fetchGroups`/`createGroup`/`fetchGroupRepositories` |
| 17 | Personal repos separate | repoScopeRefusesGroupResolution; repoWizardOmitsRunnerGroup | `Gates.requireOrganizationScope`; repo register omits `--runnergroup` |
| 18 | Real IDs fetched | orgWizardEndToEnd… (77/4242); repoAccessApplies…; orgResolveGroup… | `fetchRunners` name match; `readAgentID`; group/repo fetches |
| 19 | Permission errors retained | registrationReducerRetainsPermissionErrorAcrossDraftEdits; permissionErrorRetainedAcrossEditsUntilRetrySucceeds; forbiddenGroupCreateNamesRequiredPermission | `Flow.apply(.resolveGroup/.updateDraft/.retry)`; reducer `permissionDenied` |
| 20 | No unrelated-group mutation | repoAccessWithoutExplicitScopeIsRefused; repoAccessToForeignGroupIsRefused | `Flow.apply(.applyRepositoryAccess)` → `Gates.authorizeGroupMutation` |
| 21 | Entry-point coverage | all above + runConfigExecutesRealScript (real shell script) + registrationModuleRegistersStateAndFlow | Flow `apply`, installer methods, reducer, Module |

## Negative gates (each fails when the gate admits; call sites above)

No-space draft/install, empty name/labels, unauthenticated use, substitute arch, tampered/
malformed bytes, existing `.runner` overwrite, missing group scope, foreign group id,
repo-scope group ops, missing runner id for labels, expired token load, recovery of a
registered dir, token retention after success/failure, token echo in errors.

## Narrowing mutants: 8 killed, 0 survivors

| Mutant | Weakening (gate stays, admits one member) | Named test that fails |
|--------|-------------------------------------------|------------------------|
| M1 | `validateNoSpace` drops the work-folder space check | beginDraftRefusesSpacesBeforeAnyNetwork (`gooddir`/`bad work` case) |
| M2 | `selectDownload` matches OS only, drops arch | prepareDownloadRefusesSubstituteArch |
| M3 | `authorizeGroupMutation` drops id equality (flag only) | repoAccessToForeignGroupIsRefused (re-proven on final tree) |
| M4 | integrity guard admits non-64-char checksums | downloadRefusesMalformedChecksum |
| M5 | success-path registration-token delete skipped | orgWizardEndToEndDeletesTokenAndLeaksNothing |
| M6 | redaction drops exact-secret loop, PRESERVES `"access_token"`-shape scrub | runConfigScrubsTokenFromFailure (behavioral installer path, not the static unit test) |
| M7 | `validateDraft` drops empty-labels check | beginDraftRequiresNameAndLabels |
| M8 | `requireOrganizationScope` admits repo scope `octo/*` | repoScopeRefusesGroupResolution |

M6 satisfies the source-text-gate rule: the searched-for JSON token path is preserved while
behavior changes, and the killing harness is the behavioral `runConfig` failure test.

## Validation (real exit codes)

- `swift test` (Packages/RunnerControlCore): exit 0 — **99/99 pass** (64 pre-existing + 35 new).
- `xcodebuild -workspace RunnerControl.xcworkspace -scheme RunnerControl -configuration Debug
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`: exit 0 — BUILD SUCCEEDED.
- `swiftlint lint` on all 12 new files: **0 errors**. Remaining warnings are confined to
  classes already present at equal/higher severity in the repo baseline (Flow
  complexity/body/file size mirrors `GitHubAuth+Flow.swift`; `String(decoding:)` mirrors
  existing transport code; wizard file holds 4 co-located views).
- Full-repo bare `swiftlint`: exit 2 with 2116 violations, dominated by
  `.temp/DerivedData` third-party checkouts and pre-existing files — pre-existing posture,
  not introduced here; no new violations added outside the classes above.

## Stated bounds / unknowns

- No live GitHub calls were made: no real downloads, tokens, groups, or registrations.
  Endpoint shapes follow GitHub REST docs; a live smoke task must confirm paths/payloads
  against the real API (separate delivery task per brief).
- Existing production runners untouched: every install/config/dir in tests lives under
  unique temp roots; no `launchctl bootstrap`, no re-registration, no shared-group writes.
- Wizard UI verified by build only (no UI tests per instructions); manual walkthrough pending.
- Pre-existing lint violations in touched files (`ManagementWindowPage`,
  `ManagementWindowContainer`, `RunnerRuntime`) left as-is (unrelated churn avoided).
