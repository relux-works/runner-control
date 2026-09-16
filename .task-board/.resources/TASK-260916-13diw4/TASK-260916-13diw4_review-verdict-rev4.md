# Verdict: changes_requested

Task: TASK-260916-13diw4
Change Request: CR-TASK-260916-13diw4-4, revision 4
Candidate tree: 9ee081a9cc638e8e744f4a5f0ff090c7249cfdd7
Route: to-dev
repeat-of: revision 3 / R3-F1 (both findings below)

## Evidence and scope

Checked the submitted AC matrix before code: **8 of 8 AC rows driven** by named production-entry tests. Driving coverage is not satisfaction: the recovery/interleaving attacks below defeat the repeated-operation and identity requirements. Producer reports M21–M27 killed; I did not independently rerun that campaign. Prior narrowing evidence does not cover these interleavings.

Archived the immutable candidate into /tmp/TASK-260916-13diw4-review4. Appended reviewer tests only in that disposable copy; no production source edits. All 19 changed paths in the Story workspace byte-match the candidate. Candidate diff whitespace check passes.

Independent bounded executions:
- `swift test --package-path /tmp/TASK-260916-13diw4-review4/Packages/RunnerControlCore --filter 'reviewerRetryCannotRunTwoConfigs|reviewerStaleFailureCannotUnlock'`: **exit 1; 2 tests failed, 3 assertions**. Exact appended source and complete terminal log attached.
- Same package, filter `reviewerInFlightInstallCannotRepopulateChangedDraft|reviewerForeignServerIdentityCannotAuthorizeLabels|reviewerChangedWorkFolderCannotReuseConfiguredSuccess|inFlightRegistrationCannotAttributeOldConfigToNewDraft|inFlightGroupCannotResolveForEditedDraft|inFlightLabelsCannotWriteForEditedDraft|serverChangeBetweenStepsInvalidatesGroupAndRunner|groupChangeRefusesOldConfiguredSuccess|inFlightLabelsAbandonedWhenLabelsEdited|inFlightAccessAbandonedWhenRepositoriesEdited|remoteDuplicateWithoutReplaceIsRefusedBeforeToken|resolvePatchesDeniedPublicReposOnOwnedGroup|downloadRefusesMissingChecksum|orgWizardEndToEndDeletesTokenAndLeaksNothing`: **exit 0; 14 tests passed**.

Materialized producer rev4 validation log; its completed tail reports 147 Core tests and four metadata tests, both exit 0, with final required=2 green=2 failed=0 missing=0. Those are accepted as attached producer evidence, not an independent full replay. Native build success is reported in outcome_v4; I did not replay or independently establish that build. Live registration, actual remote orphan creation and production runner behavior were not exercised. Tests use production Flow/installer with controlled transport/executor and temporary filesystem; no UI tests, live GitHub writes, production runner operations or commits occurred. Runtime and Container dispatch reach the reviewed Flow, and reducer processing is included in the registration attack. Run is not goal-bound per `task-board spawn goal`.

## R4-F1 — P1: abandoning completion also releases a still-running directory mutation

repeat-of: revision 3 / R3-F1
Shape: bypass path around the check through retry/recovery; stale side effect outlives completion ownership.

`Flow.updateDraft` (RunnerRegistration+Flow.swift:155–160) bumps generation and immediately sets working=false. `beginDraft`, cancel and reset similarly release the guard. The already-started installer/config command is not stopped or retained as a resource owner. `RunnerInstallerService.runConfig` (RunnerInstallerService.swift:235–293) has no in-flight directory exclusion; its actor is reentrant at executor.run.

`reviewerRetryCannotRunTwoConfigsInSameDirectory` starts the real registration effect, suspends the injected config executor before it writes .runner, edits only runnerName through Flow.apply, and invokes registerRunner again before releasing the first command. The production flow mints another token and invokes config.sh a second time in the SAME directory. The second operation completes for renamed-runner; releasing the old command then writes macbook-test over the same .runner. Reducer state retains registerRunner completion for renamed-runner, contradicting the actual local registration. Both assertions fail: **2 config calls while the first remains live**, and **completed registration disagrees with .runner**.

The executor models controlled command completion; this proves duplicate command admission and stale filesystem overwrite in the orchestration, not that two real GitHub registrations were created. Real command outcomes must not be the concurrency guard.

Required: retain exclusive ownership of affected installation/registration resources until the started side effect settles, independently of whether its UI generation was abandoned. Refuse or safely serialize conflicting follow-up work; prevent an older operation from modifying a directory already attested for a newer operation. Cover begin/update/cancel/reset and recovery through the same lifecycle model. Adopt this named production-entry regression and a narrowing mutant admitting exactly one same-directory overlapping operation class. Preserve nonconflicting work and existing green controls; no separate harness/research leaf is needed.

## R4-F2 — P1: stale failure clears the current operation's busy guard

repeat-of: revision 3 / R3-F1
Shape: bypass path around the check through the failure continuation.

All step catch blocks set `working = false` before calling the generation-checked fail helper (for example RunnerRegistration+Flow.swift:503–505, also :415–417, :443–445, :636–638, :707–709, :770–772, :852–854). Suppressing the stale failure action does not undo that mutation of the shared operation guard.

`reviewerStaleFailureCannotUnlockNewOperation` suspends download A, edits installDirName, starts and suspends download B, then fails A while B is still running. Calling prepareDownload is incorrectly admitted: transport requests increase **1 → 2**. An old generation has unlocked current work; later identity edits can also skip abandonment because shouldAbandonInFlight is gated by the now-false working flag.

Required: make busy/step ownership and cleanup generation-bound on every success, failure and cancellation exit. An old generation must not change the newer operation's lock, pending state or completion ownership. Adopt this named regression and a narrowing mutant allowing stale failure cleanup for exactly one operation class. Integrate this with R4-F1 resource lifetime handling rather than adding independent per-path flags.

## Disposition

R3 foreign-server and work-folder regressions now pass, as do the 12 other focused controls above. The remaining findings are ordinary lifecycle rework, not an external blocker or a human-only decision. Revision 4 is not accepted.

No logbook executable, callable tool or repository logbook was found. This task-scoped verdict, attached reproductions/logs and board notes durably record the findings without modifying product code.
