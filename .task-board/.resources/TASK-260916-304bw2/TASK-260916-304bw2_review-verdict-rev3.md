# TASK-260916-304bw2 review — CR revision 3

Verdict: changes_requested
Route: to-dev
repeat-of: revision 2 / R2-F1, R2-F2, R2-F3
Candidate: debeb04099cfb7e7cd7374ed1e993d092c943bf3 (repository_delta=present).

## R3-F1 — P1: relocation rebinds the old editor to another organization
repeat-of: revision 2 / R2-F1
Shape: bypass path around the check; evidence rebound to mutable input.

Runners+Flow.swift:731-782, 847-884, 1025-1067. The new catalog-original check refuses an isolated disk edit, but relinkDirectory accepts a folder with the same numeric agent ID in another organization and rewrites catalog.scope. Apply reconstructs authority from that new catalog/disk pair; it does not bind the submitted edit to the identity that Load verified. GroupAccess carries no such identity (Runners+Models.swift:150). The reducer retains access for the same live service ID after relink (Runners+State+Reducer.swift:24); catalogCleared clears only the error. ManagementWindowContainer.swift:252-270 submits the retained group ID.

Production-entry probe reviewR3RelinkMustNotRebindLoadedEditorToOtherOrg loads acme/group4, relinks to another temporary directory registered as other-org/agent42, then applies the previously loaded group4 edit. It emits PUT https://api.github.com/orgs/other-org/actions/runner-groups/4/repositories. The original editor was never reloaded for other-org. This is a concrete remaining original-binding defect, not inference from code shape.

Keep relocation bound to the full original registration identity, and bind loaded editor/write authority to immutable server/scope/agentID/canonical service identity. An intentional identity replacement must invalidate the old editor and require a new Load/confirmation. Adopt the attached probe and add a true narrowing mutant that keeps host/agent checks but admits same-host changed-scope relink or stale-editor application. No separate harness/research task.

## R3-F2 — P2: same-account re-login revives stale Apply completion
repeat-of: revision 2 / R2-F2
Shape: bypass path around the check (session renewal/completion).

Runners+Flow.swift:968-975 compares only userID/serverHost. GitHubAuth.Flow.logout increments its private generation and deletes identity/tokens; successful Device Flow then saves the same public account identity again. No logout generation reaches Runners.Flow. Runtime wiring does not subscribe Runners to an auth invalidation effect; its reducer ignores GitHubAuth actions.

Production-entry probe reviewR3SameAccountReloginDuringPutMustNotPublishAccess runs GitHubAuth.Flow.apply(.logout), then .beginLogin, and waits with a 3-second bound for the actual .connected action while the old PUT response is suspended. HTTP and Keychain are fake; the auth flow is production. New tokens and the same account are established. The old Apply then issues its confirmation GET using its captured old token and publishes groupAccessLoaded(owned:true) into the new session. Both assertions fail. Original logout-without-relogin regression passes.

Use an actual login/session incarnation, shared through production composition, across Apply and sibling Load success/error/read boundaries. Logout followed by same-account login must invalidate the old operation; ordinary token refresh within one login must remain valid. Adopt this named regression, add sibling Load coverage and a positive refresh control, and prove a narrowing mutant which retains account/server checks while admitting a renewed same-account session.

## R3-F3 — P1: same-account re-login revives unregister authority
repeat-of: revision 2 / R2-F3
Shape: bypass path around the check (unregister session renewal).

Runners+Flow.swift:364, 424, 444-446 uses the same account comparison after remove-token acquisition. Production-entry probe reviewR3SameAccountReloginDuringRemoveTokenMustRefuseSideEffect performs real auth logout + completed Device Flow login during the POST response. Despite the old session ending, the old unregister invokes the installer executor for config.sh remove and clears catalog.remoteAgentID. Both safety assertions fail. This is an unstarted side effect after invalidation, not a demand to undo a completed mutation.

Apply the same coherent session-incarnation ownership to unregister through the actual side-effect boundary, retain the installer-wide lease until settlement, and preserve operation-state release/retry. Adopt this regression and a narrowing mutant allowing only same-account renewed-session unregister while retaining stopped/local-identity gates. Keep a positive explicit retry initiated in the new session.

## Evidence and bounds

Read AC map before source: 18 of 19 named rows driven, with full UI explicitly manual. Findings affect rows 11/16 and the existing session/editor integration contract. Revision 3 changes only Runners+Flow.swift and RunnerCatalogLifecycleTests.swift relative to revision 2.

Independently executed against an isolated archive of the exact candidate:
- Six maintained R3 regressions, including all three exact prior probes: 6 passed, exit 0. Attached controls log.
- Three new adversarial probes: 3 failed, 5 assertion failures, exit 1. Attached source/log. Actual auth logout and Device Flow login are exercised, not just a delete/save fake identity transition.
- All 40 archived Core production Swift files compared byte-for-byte with candidate tree: zero mismatches. Repository product/test code was not modified. Only appended tests in /tmp/TASK-260916-304bw2-review-r3.

Reproduce: archive candidate Packages/RunnerControlCore; append TASK-260916-304bw2_review-probes-rev3.swift to Tests/RunnerCatalogLifecycleTests.swift; run swift test --package-path <copy>/Packages/RunnerControlCore --filter reviewR3. Processes were bounded with owned process groups and finished before verdict. Tests use temporary runner directories, in-memory Keychain, fake HTTP/executors. No production runner/service/GitHub registration was changed. No UI tests.

Read complete attached rev3 handoff validation log: 216 Swift tests and 62 Python release tests, each exit 0 with terminators. These are accepted as producer/handoff evidence, not claimed as independent reruns. Signed native 1.2.0 build and four narrowing mutant results are producer-reported; not independently rerun because the concrete failures already require rework. Root's manual CUA evidence remains acknowledged, not repeated.

No external blocker or human decision is needed. Repair these existing ownership classes in this leaf, retain named regressions and narrowing mutants, then request another independent review. Run is not goal-bound (spawn goal queried before verdict).
