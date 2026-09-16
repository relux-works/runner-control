# Verdict: changes_requested

Task: TASK-260916-13diw4 — register-mac-and-repository-access
Change Request: CR-TASK-260916-13diw4-3 revision 3
Candidate tree: bd21d37da20fe43ac80d9ed87a6b1cd027b397e3
Route: to-dev
repeat-of: revision 2 / R2-F3 and revision 2 / R2-F2 (per-finding mapping below)

## Evidence

Checked the submitted AC matrix before code: **8 of 8 AC rows driven** by named tests. This is driving coverage, not satisfaction: the counterexamples below defeat identity/retry behavior. Producer narrowing evidence M13–M20 addresses selected cases; it does not cover these variants. M9 survivor is explicitly bounded by its unused default and M9b call-site test.

Exported the immutable candidate with git archive into /tmp/TASK-260916-13diw4-review3. Added only reviewer tests to that disposable copy. No production source changed. All 19 task paths in the Story workspace byte-match the candidate.

Independent bounded executions:
- `swift test --package-path /tmp/TASK-260916-13diw4-review3/Packages/RunnerControlCore --filter 'reviewerInFlightInstall|reviewerForeignServer|reviewerChangedWorkFolder'`: exit 1, **3 tests failed / 6 assertions**. Full terminal log and appended test source attached.
- Same package, filter `orgListRequestsUseQueryNotEncodedPath|labelsWithMismatchedRemoteIdentityAreRefused|changedScopeMustNotReuseRegistrationOrRemoteID|repositoryConfirmationFollowsPagination|serviceCannotClaimDoneBeforeRegistration|downloadRefusesMissingChecksum|remoteDuplicateWithoutReplaceIsRefusedBeforeToken|resolvePatchesDeniedPublicReposOnOwnedGroup`: exit 0, **8 tests passed**. Full log attached.

The attached producer validation log was materialized and its completion inspected: it reports 132 Core tests, four metadata tests, both exit 0 and final 2/2 shard summary. This review did not independently replay the complete suite, metadata checks, build or mutants, and does not substitute that log for behavioral proof. No live GitHub calls, production runner operations, UI tests, commits or product edits occurred. `task-board spawn goal` reports this run is not goal-bound.

## Findings

### R3-F1 — P1: in-flight completion restores stale progress after draft edit

At RunnerRegistration+Flow.swift:117–128, updateDraft invalidates caches but neither changes generation nor rejects/serializes edits while working. downloadAndInstall captures the previous draft, awaits the downloader, then writes installPath and emits installed/stepFinished with the unchanged generation. The form remains editable during work; Container.pushDraft dispatches these edits.

`reviewerInFlightInstallCannotRepopulateChangedDraft` suspends the real installer at its injected download boundary, edits org acme/macbook-test to repo octo/app/new-install through Flow.apply, releases download, then drives the actual State.reduce over emitted actions. The new draft receives the old macbook-test path and completed downloadAndInstall. Both refusal assertions fail.

Shape: bypass path around the check through asynchronous completion; stale evidence reused under changed identity.
repeat-of: revision 2 / R2-F3. That finding explicitly required edits during work; only sequential edit cases were added.

Required: make operation identity and completion ownership coherent across begin/update/cancel/reset and each await boundary. Prevent stale successes and writes from being attributed to a new draft; preserve safe recovery for an already-started side effect. Add this named regression and a narrowing mutant allowing exactly one in-flight identity-edit class. Exercise in-flight registration/group/access/label boundaries as applicable, not only completed-then-edited state. Keep this work within this leaf.

### R3-F2 — P1: server identity is absent from local-to-remote authorization

RunnerRegistration+Gates.swift scopeMatches compares HTTPS and URL path only; verifiedLocalAgentID does not bind the host to the authenticated API server. Flow.applyLabels then authorizes a PUT by agent ID/name on the current session server. Agent IDs belong to their server and cannot establish cross-server identity.

`reviewerForeignServerIdentityCannotAuthorizeLabels` first completes a controlled registration, changes .runner gitHubUrl to https://enterprise.example/acme (same scope/name/ID), then drives Flow.apply(.applyLabels). The candidate sends PUT to github.com's runner 4242 and reports success. Both assertions fail. The test models local registration drift; it does not contact either server.

Shape: absent identity evidence treated as satisfied / bypass around foreign-runner non-disruption.
repeat-of: revision 2 / R2-F2, which explicitly requested server + scope + agentId binding (itself repeat-of revision 1 / F5).

Required: carry the authenticated server as part of immutable operation identity, compare the full normalized server/scope against .runner before remote writes and resume, and scope group ownership records to server as well (currently org/name only). Add the named production regression plus a narrowing mutant admitting a same-path foreign host. Preserve same-server valid controls and test session/server changes across retries. No separate harness/research task is needed.

### R3-F3 — P2: changed work folder is acknowledged without reconfiguration

Flow.invalidateProgress drops runnerID for a workFolder change, but registerRunner's configured-marker resume calls verifiedLocalAgentID, which never checks LocalRegistration.workFolder. It skips config.sh and emits registered success for the old _work configuration. The field is read from .runner but is not used by the gate. Service setup can likewise regard this stale configuration as ready.

`reviewerChangedWorkFolderCannotReuseConfiguredSuccess` registers with _work, changes the draft to new_work, and calls the real registration effect again. It emits registered without a failure while the fixture .runner still says _work. Both assertions fail.

Shape: bypass path through resume; proxy marker substituted for requested configuration evidence.
repeat-of: revision 2 / R2-F3 (changed draft/progress identity class).

Required: refuse or explicitly implement a safe reconfiguration path for changed configuration; never claim current-draft success from an old configured marker. Add the named regression and a narrowing mutant for the work-folder mismatch. Check group/configuration edits against the same principle. Do not re-register or interrupt existing production runners as part of verification.

## Disposition and bounds

The earlier URL, pagination, foreign numeric ID, public-group flag, checksum refusal, duplicate-name and service prerequisite controls remain green in the independent focused run. Container → Flow → actors → reducer architecture is preserved. The demonstrated remaining defects require ordinary implementation rework, not a human decision or external blocker.

Live authenticated download checksum availability and actual registration smoke remain unverified here; fail-closed missing-checksum behavior passes. No claim is made that a release landed or that real API registration succeeds.

Logbook: no logbook executable, tool or repository logbook was found; this durable task-scoped verdict and board notes preserve the findings without changing product files.
