# TASK-260916-304bw2 review — CR revision 5

Verdict: changes_requested
Route: to-dev
repeat-of: revision 4 / R4-F2
Candidate: 53113a3667026a0b52e7bb7ee0cf793f73992cec (repository_delta=present).

## R5-F1 — P2: remove/re-import revives an old editor operation owner
repeat-of: revision 4 / R4-F2
Shape: bypass path around the check (recovery/re-import reuses operation authority).

Runners+Flow.swift:1314-1330 assigns operation numbers from a per-ID dictionary, then removes those dictionary entries on remove/relink. A subsequent Load of the re-imported service label starts again at 1. The original operation 1 now passes ownsGroupAccess for the new editor. Its catalog-stale cleanup at lines 1362-1374 publishes groupAccessFailed, clearing the newer pending Load's busy state and publishing an unrelated old error. This contradicts the R5 owner-bound cleanup contract and the outcome's explicit remove-then-re-add claim.

Concrete production-entry reproduction: reviewR5RemoveReimportMustNotReviveOldEditorOwner holds the first Load at HTTP, invokes Flow.apply(.removeFromApp), invokes Flow.apply(.importFolder) for the same temporary runner, starts and holds a second Load, then releases only the first. The second remains pending. Feeding emitted actions through the actual Runners.State reducer yields loading=false and "Runner catalog changed during group access…", instead of loading=true with no error. Both assertions fail; exit 1. Import succeeded and retained the service label. The UI permits removal during editor loading (ManagementWindowPage.swift:277-280 disables removal only during unregister), so this is a reachable product flow, not cross-Flow overlap. All operations use one Flow.

Use non-reusable operation ownership across removal/relink/re-import (for example a unique operation identity or a monotonic generation whose sequence is not reset when ownership is dropped). Recheck ownership after awaits in cleanup before publication. Adopt the attached exact probe, retain the current ordinary-overlap and same-Flow retry controls, and add a true narrowing mutant that preserves normal overlap protection but permits owner reuse across remove/re-import. This is focused rework of the existing cleanup finding, not a new feature or architecture task.

## Verified progress and evidence

Read producer AC coverage before source: 18 of 19 named rows driven; full UI paths are the declared manual bound (no UI tests). The failure concerns row 16 and the explicit R5 owner/generation cleanup requirement.

Independent commands in /tmp/TASK-260916-304bw2-review-r5, archived from the exact candidate:
- New production-entry probe: 1 test, 2 assertion failures, exit 1. Both latched tasks released and completed before the process exited.
- Focused maintained controls: 12 test functions (including the two-case Load/Apply invalidation probe), all pass, exit 0. Includes the exact R4 final-inspection unregister and both editor-cleanup cases, all R3 actual-auth/editor probes, installer-boundary refusal, authorized unregister, same-session refresh, new-session unregister retry, same-Flow editor retry and ordinary overlapping Load control.
- All 40 Core production source files compared byte-for-byte with the frozen candidate: zero mismatches. Only the attached test was appended to the isolated copy. Repository code was not modified.
- Each swift test invocation ran under a new owned process group with a 240-second timeout and exact-group termination on timeout. Neither timed out. No commands remain running.

Reproduce: archive candidate Packages/RunnerControlCore into a temporary directory; append TASK-260916-304bw2_review-probes-rev5.swift to Tests/RunnerCatalogLifecycleTests.swift; run swift test --package-path <copy>/Packages/RunnerControlCore --filter reviewR5. The probe reuses the maintained CatalogHarness and fixture helpers. Only temporary catalog/files and fake HTTP/launchctl execution were used; no production runner/service/registration was changed. No UI tests.

Revision-5 handoff validation log was fetched and inspected: 229 Swift tests and 62 Python tests with explicit exit-0 terminators. These are producer/handoff evidence, not independent full reruns. Signed native 1.2.0 build and three narrowing mutants remain producer-reported, not independently rerun because the reproduced failure requires rework. Prior root manual UI evidence is acknowledged, not repeated.

R4-F1 and the exact R4-F2 probes are repaired and independently green. The additional re-import path still violates operation ownership. No external blocker or human decision is needed. spawn goal queried before verdict: this run is not goal-bound.
