# Review verdict: changes_requested

Task: TASK-260916-13diw4
CR: CR-TASK-260916-13diw4-1 revision 1
Candidate: fdebfc9f4be87678d577004d28788368389c95e4
repeat-of: none (all findings below are first-cycle findings)
Route: to-dev

## Coverage and validation

Checked AC mapping before reading implementation: producer supplies 21 of 21 rows with named tests. This is a nominal driving-test ratio, not demonstrated satisfaction: rows 3/4/6/9/11/16/20 have material counterexamples below. Eight claimed mutants include narrowing shapes, not a delete-only table; those claims do not cover absent checksum, same-name ownership, HTTP 204, or post-config failure cleanup.

Read attached revision validation log to its end: 99 Core tests and 4 Python metadata tests, both exit 0. Accepted as attached baseline evidence, not rerun by reviewer. Build/lint claims in producer prose were not independently rerun and are not the basis of this verdict.

Reviewer exported the EXACT candidate via git archive to /tmp/rc-review-13diw4 and appended five review tests to the existing registration test file in that disposable copy. Production sources in both candidate and workspace were unchanged. Ran:
`swift test --package-path /tmp/rc-review-13diw4/Packages/RunnerControlCore --filter '^RunnerControlCoreTests.review'`
Exit 1, 9 tests executed: all five new adversarial tests failed (7 assertions), four existing reviewer auth lifecycle tests passed. Attached complete final log and appended test source. No UI tests, live registration, production runner operations, or real GitHub mutations.

## Required fixes

### F1 — P1: absent integrity evidence is accepted
Shape: absent evidence treated as satisfied.
`RunnerInstallerService.downloadAndInstall`, lines 121-127, only verifies when the optional checksum is nonempty. `reviewMissingChecksumMustRefuse` installed a real temporary archive with nil checksum. FetchDownloads decodes optional `sha256_checksum`; official REST download examples do not establish that field is available. Obtain verified integrity metadata from an authoritative source and fail closed if unavailable; do not silently install. Add missing/empty checksum entry-point regressions and narrowing mutant; exercise the actual official metadata shape.
repeat-of: none

### F2 — P1: successful repository updates reported as failures
Shape: capability claim that does not reproduce; green suite around an inaccurate transport fixture.
`GitHubRunnerAPIClient.send`, lines 46-48, accepts only 200/201. GitHub's repository-access PUT returns 204. `reviewReal204RepositoryUpdateMustSucceed` emits `GitHub request failed (HTTP 204)` and never emits repositoryAccessApplied; the producer test supplies 200 instead. Handle endpoint success correctly and confirm repository IDs through the follow-up GET; commit the real-204 regression.
repeat-of: none

### F3 — P1: public repositories cannot use created groups
`CreateGroupDTO` / `createGroup` omit `allows_public_repositories`; GitHub defaults it to false. `reviewPublicRepositoriesMustBeEnabled` confirms the emitted creation payload lacks the field. The requested public relux-works/runner-control repository therefore is not enabled by selecting its ID. Model and apply public access intentionally for selected repositories, verify returned policy, and cover creation/edit paths with realistic transport responses.
repeat-of: none

### F4 — P1: a matching group name is treated as ownership
Shape: forged/self-minted evidence and bypass path around ownership check.
`Flow.resolveGroup` adopts any same-name group; `authorizeGroupMutation` then compares against that adopted ID, making the identity check circular. `reviewUnownedMatchingGroupMustNotBeMutated` supplies a pre-existing group with the default-looking name and no ownership record; production sends PUT replacing its repository list. The generic allowGroupMutation flag does not prove the group belongs to this Mac. Establish durable scope/server/Mac ownership or present an explicit shared-group adoption/impact scope before allowing this destructive change. Preserve unrelated groups; test same-name/shared/default/inherited cases and a narrowing mutant.
repeat-of: none

### F5 — P1: new registration unconditionally replaces a remote name collision
Shape: bypass path around non-disruption boundary.
`ConfigInvocation.arguments`, line 112, always adds --replace. `Flow.registerRunner` never checks for a foreign remote name before running config. `reviewPostConfigFailureMustDeleteTokenAndNeverReplace` drives Flow through install/register and records --replace in executed argv. This can replace another machine's same-name registration; the local .runner existence guard does not protect remote machines. Remove implicit replacement, use non-destructive collision handling and ownership-bound recovery, and add collision/race/retry tests through Flow + installer.
repeat-of: none

### F6 — P2: post-config failure retains registration token
Shape: bypass path around cleanup on recovery/failure.
After runConfig succeeds, Flow resolves remote runner ID before deleting the token. An HTTP 500 from that read jumps to outer catch without deletion. The same combined review test proves the token remains loadable. Cleanup must cover every exit after save, including stale/cancel/retry paths, and occur immediately after config use. Add the failed-read regression and a cleanup-narrowing mutant.
repeat-of: none

## Further rework bounds

Identity is matched by name, not local agent ID: the existing end-to-end test accepts remote ID 77 with local agent ID 4242. Resolve by confirmed server/scope/agent ID before labels mutate remote state. Lists do not paginate, so current results cannot establish absence or complete access. Draft scope/path/name changes retain installPath/runnerID and completed state; bind progress to immutable operation identity or invalidate it safely. These source-observed risks need regression coverage during rework; no live impact is claimed.

The Container dispatches the production Flow and follows Container+Page; actor services and reducers fit the architecture. That wiring does not repair the API/ownership/verification failures above. No external blocker or human decision is needed: this is implementation rework in this leaf, followed by independent review.

## Sources

GitHub REST group contract (204 success and public default false):
https://docs.github.com/en/rest/actions/self-hosted-runner-groups
GitHub runner download contract inspected:
https://docs.github.com/en/rest/actions/self-hosted-runners

Logbook note: important findings are persisted in this verdict and task notes. No logbook CLI/tool or repository logbook was found in the available environment; no product file was created for it.
