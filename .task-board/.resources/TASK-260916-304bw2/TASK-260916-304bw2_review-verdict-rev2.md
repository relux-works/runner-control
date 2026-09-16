# TASK-260916-304bw2 review — CR revision 2

Verdict: changes_requested
Route: to-dev
repeat-of: revision 1 / F2
Candidate: b3003bd2ef6e40c1dbb3a3dad8d0cfcf01196454 (repository_delta=present).

## R2-F1 — P1: Apply can retarget a different organization after Load
repeat-of: revision 1 / F2
Shape: bypass path around the check; evidence rebound to mutable input.

Runners+Flow.swift:816-842, 932-965, 974-1015: verifiedOrgRunner reads a new scope at Apply and compares only the stored agent ID; bindApplyIdentity then checks that new scope against itself. Neither binds the submitted edit to the catalog's original scope or the identity loaded for the editor. Probe reviewR2ScopeEditAfterLoadMustNotRetargetApply loads group 4 for github.com/acme, changes only .runner gitHubUrl to github.com/other-org, then applies the old editor's group 4/repository selection. With matching numeric runner/group IDs and name in other-org, production emits PUT to other-org. Fresh membership is read, but for the wrong organization.

Bind editor/write authority to the original server + scope + agentID + canonical service identity, and require explicit re-verification when it changes between Load and Apply or across awaits. Adopt the attached named production-entry regression. This repeats F2: next revision must include a narrowing mutant retaining host/agent checks while admitting a same-host changed scope. Repair this leaf; no separate research/harness task.

## R2-F2 — P2: Apply completion repopulates access after logout
repeat-of: revision 1 / F2
Shape: bypass path around the check (completion path).

Runners+Flow.swift:1011-1034: sessionStill runs before PUT, but after PUT and confirmation only catalogGeneration is checked. Logout deletes identity without changing catalogGeneration. Probe reviewR2LogoutDuringPutMustNotPublishAccess deletes session identity as the PUT response arrives. Production issues an additional authenticated GET and publishes groupAccessLoaded(owned: true) into the logged-out session. Two assertions fail. This is not a demand to undo an already issued PUT: refuse subsequent authenticated work and stale state publication.

Carry session/operation ownership through confirmation, success and error completion (and the sibling Load completion). Keep a maintained regression plus narrowing mutant that preserves pre-PUT checks while allowing completion from an invalidated session. Existing pre-PUT logout/server-switch tests pass and do not cover this boundary.

## R2-F3 — P1: Logout during remove-token acquisition still unregisters
repeat-of: none
Shape: bypass path around the check (unregister lifecycle).

Runners+Flow.swift:390-434: unregister never checks session continuity after token acquisition. Probe reviewR2LogoutDuringRemoveTokenMustRefuseSideEffect deletes identity as the POST remove-token response arrives. Production still calls the installer executor for config.sh remove and clears catalog remoteAgentID. Both safety assertions fail. The stopped-state checks do run; they do not supply current session authority.

Bind unregister to the initiating session and invalidate unstarted side effects after logout/account/server changes. Preserve installer lease until any already-started process settles; do not pretend cancellation can undo a completed remote removal. Add the attached named regression and a narrowing mutant admitting post-token logout while retaining stopped and local-identity gates. Ensure invalidation releases UI operation state for retry.

## Evidence and bounds

AC map read before source: 18 of 19 named rows driven; full UI is the explicit manual bound. Findings affect rows 11/16 and the asynchronous/session integration contract. Existing F1 stopped-only, F3 distinct identity, F4 persistence fixes and the original cross-server F2 probe pass their focused regressions.

Reviewer independently ran:
- 13 maintained R2 regressions through production entries: 13 passed, exit 0 (attached controls log).
- 3 new adversarial scenarios against exact candidate production sources: 3 failed, 5 assertion failures, exit 1 (attached probes source/log).
- Compared all 40 extracted Core source files byte-for-byte to candidate tree; no production modifications. Only appended tests in /tmp/TASK-260916-304bw2-review-r2.

Reproduction: git archive the candidate's Packages/RunnerControlCore to an isolated directory; append TASK-260916-304bw2_review-probes-rev2.swift to Tests/RunnerCatalogLifecycleTests.swift; run swift test with --filter reviewR2 as logged. Tests use temporary directories, in-memory credentials, fake HTTP and command executors. No real GitHub mutation, runner process, LaunchAgent registration, or repository source was changed. Processes were bounded and finished before verdict.

Read the attached rev2 validation log and command terminators: 210 Swift tests exit 0; 62 Python release tests exit 0. These are producer/handoff results, not independent reruns. Native signed build and mutant results remain producer-reported evidence; not independently rerun because reproduced failures already require rework. Root manual CUA preconditions acknowledged; no UI tests or repeated production smoke.

No external blocker or human decision needed. Focused implementation rework and another independent review required.
