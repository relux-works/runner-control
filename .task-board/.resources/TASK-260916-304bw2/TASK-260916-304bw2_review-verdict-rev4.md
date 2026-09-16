# TASK-260916-304bw2 review — CR revision 4

Verdict: changes_requested
Route: to-dev
repeat-of: revision 3 / R3-F3, R3-F2
Candidate: f2df463be1443005d9d12bbfa7b27faae64bb5a2 (repository_delta=present).

## R4-F1 — P1: unregister starts after logout during final service inspection
repeat-of: revision 3 / R3-F3
Shape: bypass path around the check (await between authorization and protected side effect).

Runners+Flow.swift:447-450 checks sessionStill BEFORE awaiting requireConfirmedStopped. That routine awaits production LaunchAgentService.snapshots and its launchctl executor. Logout can finish during that inspection. The stopped result then proceeds directly to RunnerInstallerService.unregister, which has no session authority check.

Concrete probe: reviewR4LogoutDuringFinalStoppedInspectionMustRefuseRemoval drives Runners.Flow.apply(.unregister), the actual LaunchAgentService and actual GitHubAuth.Flow.apply(.logout). Only launchctl execution, HTTP, and Keychain IO are fake. The second launchctl inspection triggers completed logout before returning its stopped result. Identity is nil, but the installer executor is invoked for config.sh remove and catalog.remoteAgentID is cleared. Both safety assertions fail. The remove-token request was already issued; the removal process had NOT started when logout completed. This is not a request to undo a completed side effect.

Carry operation/session authority through the final inspection and enforce it at the actual installer side-effect boundary, preserving the exclusive installer lease and retry epilogue. Adopt this exact regression and add a narrowing mutant that retains token-await/session and stopped-state gates but admits invalidation during the final inspection. Include a positive authorized unregister and explicit new-session retry. Same existing leaf; no separate research or architecture task.

## R4-F2 — P2: invalidated Load and Apply permanently retain loading state
repeat-of: revision 3 / R3-F2
Shape: bypass path around the check (invalidation cleanup/retry).

Runners+Flow.swift:970/975 and 1170/1176 correctly suppress stale results by returning when session incarnation changed, but never balance groupAccessLoading. Runners.State.reduce ignores GitHubAuth actions and retains groupAccess on ordinary refreshed snapshots (Runners+State+Reducer.swift:4,24,52-65). No composed auth cleanup clears it. ManagementWindowPage.swift:334-359 disables Apply/Refresh for loaded editors and replaces the initial Load button with a spinner while loading is true.

Concrete parameterized probe: reviewR4SessionInvalidationMustReleaseEditorLoading(apply:) runs both Load and Apply with the existing real-auth same-account logout/Device Flow re-login hook, then feeds the emitted Runners actions through the production reducer and performs normal local refresh. Both cases end with groupAccess[label].loading == true despite the operation having returned and the new login being established. Stale success publication remains correctly suppressed; UI retry is nevertheless unavailable. The maintained unregisterRetryInNewIncarnationSucceeds test does not cover this editor cleanup, and uses another Flow for its explicit retry.

Provide owner/generation-bound cleanup of the invalidated editor operation without allowing an older completion to clear a newer request's busy state or publish stale data. Adopt both cases, test retry through the released state, and test overlapping old/new operations. Add a narrowing mutant that leaves successful completion cleanup intact but omits invalidation cleanup for one sibling path.

## Verified progress and evidence

Read AC coverage before source: producer reports 18 of 19 named rows driven, with full UI paths explicitly manual (no UI tests). These findings affect rows 11/16 and the existing async ownership/retry requirements.

Independently executed in /tmp/TASK-260916-304bw2-review-r4, archived from the exact candidate:
- Eight maintained R4 regressions/controls passed, exit 0, including all three exact revision-3 reviewer probes, sibling Load rejection, refresh control, unregister retry, and both relocation recovery controls.
- Two new test functions / three scenarios failed with four assertion failures, exit 1: one unregister-boundary scenario and Load/Apply cleanup cases.
- All 40 Core production source files compared byte-for-byte with the candidate tree: zero mismatches. Only test probes were appended in the isolated copy; repository code was not modified.
- Initial control compilation was invalidated because the copied test source was appended during compilation; it is NOT counted as a test result. Source was then frozen and both the adversarial and control commands completed with the exit codes above.

Reproduce: archive candidate Packages/RunnerControlCore; append TASK-260916-304bw2_review-probes-rev4.swift to Tests/RunnerCatalogLifecycleTests.swift; run swift test --package-path <copy>/Packages/RunnerControlCore --filter reviewR4. The probes reuse maintained CatalogHarness/reviewR3ReloginFlow helpers. All processes were bounded by owned process groups and settled before verdict. Temporary directories only; no production runner, service, or GitHub registration changed. No UI tests.

The attached revision-4 handoff validation log reports 224 Swift tests and 62 Python tests, both with exit 0 terminators. Accepted as producer/handoff evidence, not independent reruns. Signed native 1.2.0 build and four narrowing mutants remain producer-reported; not independently rerun because reproduced failures already require rework. Root manual UI smoke remains acknowledged and was not repeated.

The incarnation and immutable editor fixes resolve the exact previous probes. They do not yet close the final side-effect boundary and cleanup/retry class. No external blocker or human decision is needed. Run is not goal-bound (spawn goal queried before verdict).
