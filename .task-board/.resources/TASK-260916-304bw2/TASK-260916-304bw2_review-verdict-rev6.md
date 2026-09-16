# TASK-260916-304bw2 — revision 6 review

Verdict: accepted
Candidate: 2dd8ae0a008212bb538dd4965a07da635005268c (repository_delta=present).

R5-F1 is repaired. Relative to revision 5, only Runners+Flow.swift and RunnerCatalogLifecycleTests.swift changed. UUID operation ownership cannot restart after remove/relink/re-import. Catalog-change cleanup checks ownership again after its catalog await. The change fits the existing actor Flow/action/reducer architecture.

Coverage checked before code: 18 of 19 named AC rows driven, with row 18 explicitly bounded to manual UI (no UI tests). The focused revision-6 ownership requirement is 1 of 1 driven by the exact adopted reviewR5RemoveReimportMustNotReviveOldEditorOwner probe at Runners.Flow.apply(.loadGroupAccess/.removeFromApp/.importFolder), with emitted actions passed through Runners.State.reduce. Original probe bytes match the maintained test.

Independent verification against an isolated archive of the candidate:
- Initial focused controls: 11 test functions passed, exit 0.
- Narrowing mutant: retain owns/drop gates and fresh UUIDs for ordinary overlap, but allocate a fixed UUID when the owner slot is empty. The exact reimport probe failed with both original assertions (loading cleared and stale error published), exit 1. Ordinary overlap and same-Flow retry controls passed in that same behavioral run. This attacks the recovery/re-import bypass shape, not gate deletion.
- Restore the temporary source byte-for-byte, then run 16 test functions (including the two-case R4 Load/Apply test): all passed, exit 0. Includes exact R2, R3, R4, R5 probes, same-login token-refresh success, new-incarnation unregister retry, final installer-boundary logout refusal, positive unregister, overlap and retry.
- All 49 Core package files in the working candidate matched the frozen tree byte-for-byte. Repository source was not modified; the mutant ran only in /tmp/TASK-260916-304bw2-review-r6. Commands used owned process groups with 240-second bounds; no timeout or remaining process.
- Independently verified the signed app with codesign --verify --deep --strict (exit 0): universal macOS, version 1.2.0, works.relux.runnercontrol, team 262RZ595FP, signed 2026-09-16 15:56:31.

Accepted existing revision-6 evidence, not claimed as independent full reruns: the complete handoff validation log terminates both commands with exit 0 (230 Core tests, 62 Python release tests). Producer build output records BUILD SUCCEEDED and BUILD_EXIT:0; its signed product was independently checked above. No configured linter; the build retains a nonblocking app-category warning. Prior root manual UI evidence corroborates real login OFF and fresh group/repository editor wiring. Downstream disposable lifecycle smoke, hosted integration and release remain downstream work; acceptance does not claim landing or release.

No new findings. No production runner/service/registration was changed, no UI tests were run, no commits were made. Existing explicitly documented bounds are unchanged by this focused revision. spawn goal queried: run is not goal-bound. Accept revision 6 and route to integrating through accept_cr; no commit_ack.
