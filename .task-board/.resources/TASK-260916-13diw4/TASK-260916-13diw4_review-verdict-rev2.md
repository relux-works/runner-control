# Verdict: changes_requested

Task: TASK-260916-13diw4
Change Request: CR-TASK-260916-13diw4-2, revision 2
Candidate: 0973915f402f3e526683c3bb12d8d908b714d7c4
Route: to-dev
repeat-of: revision 1 / F5 (foreign-runner non-disruption class; see R2-F2). Other per-finding values below.

## Evidence and scope

AC evidence checked before code: producer maps **8 of 8 AC rows driven** to named production-entry tests. This is a driving-test ratio, not satisfaction. Counterexamples below invalidate claimed registration/access behavior (rows 1–4 and 6); safe failure and no-secret evidence is bounded by exercised paths. The mutant table includes narrowing mutants, not only deletions. M9 is explicitly reported as a survivor with M9b exercising the load-bearing call site.

Read complete attached rev2 validation log: 110 Core tests and four metadata tests exit 0, with final command and shard summary present. Accepted as producer baseline evidence, not independently replayed wholesale. Build/lint prose was not independently rerun or accepted as proof of these behaviors.

Exported the exact candidate with git archive to `/tmp/rc-review-13diw4-r2`. Appended only review test code to the disposable copy. Production files were unchanged. Independently ran:

- `swift test --package-path /tmp/rc-review-13diw4-r2/Packages/RunnerControlCore --filter reviewR2`: **exit 1; six tests, all six failed, 12 assertions**. Full log and appended test source attached.
- Seven focused regression controls covering rev1 checksum, HTTP 204, public-group create/patch, name-only group takeover refusal, implicit runner replacement refusal, and post-config token deletion: **exit 0; seven passed**. Full log attached.

All 19 reviewed workspace paths still byte-match the immutable candidate. No production runner, live GitHub mutation, UI test, or product-code edit occurred. `task-board spawn goal` reports this run is not goal-bound.

## Required changes

### R2-F1 — P1: list requests encode the query into the path

`GitHubRunnerAPIClient.swift:34,191,216` passes `...?per_page=100` to `appendingPathComponent`. Actual outbound artifacts are `.../runners%3Fper_page=100` and `.../runner-groups%3Fper_page=100`, with nil URL query. These do not address GitHub's documented list routes. This breaks group resolution and the pre-registration list read. The queue transport accepts arbitrary URLs and hides it.

Production test: `reviewR2ListURLsUseQueryNotEncodedPath` drives Flow.resolveGroup and Flow.applyLabels, asserting the emitted request URL components; four assertions fail. Shape: capability claim that does not reproduce / green suite around a permissive fake. Build paths and query items separately; make controlled transports assert method/path/query and test both org/repo list paths. repeat-of: none.

### R2-F2 — P1: a remote name match authorizes writes to another runner

`RunnerRegistration+Flow.swift:430–435,540–561` resolves identity by name and treats it as authority for label PUTs. `reviewR2NameOnlyMustNotAuthorizeLabelMutation` drives beginDraft then applyLabels with no local installation or registration: a same-name remote runner 77 is mutated. `reviewR2MismatchedLocalAgentMustNotBecomeRemoteIdentity` registers fixture local agent 4242, returns remote same-name 77, then proves labels are written to 77. The producer end-to-end test explicitly accepts this mismatch. The UI's button disablement does not repair the registered mismatch path.

Shape: absent ownership evidence treated as satisfied; bypass around the non-disruption boundary. Bind remote identity to verified local .runner server/scope/agentId, not name; refuse missing, malformed, mismatched, or ambiguous identity before writes. Commit these regressions and a narrowing mutant admitting exactly one mismatched agent ID, including retry/resume. This is rework in this leaf, not a separate harness task.

repeat-of: revision 1 / F5, same foreign-runner non-disruption class; the old unconditional --replace mechanism is fixed, but the same protected boundary is bypassed through labels. Also explicitly anticipated by rev1's unnumbered identity bound.

### R2-F3 — P1: editing scope retains the old installation and runner ID

`RunnerRegistration+Flow.swift:124–130` clears only group/asset on scope change. `installPath`, runnerID and step progress remain. Container field callbacks dispatch updateDraft and Apply Labels remains enabled while the old runnerID is present. `reviewR2ChangedScopeMustNotReuseRegistrationOrRemoteID` registers org acme agent 4242, edits to repo octo/app and a different install directory, then observes PUT `/repos/octo/app/actions/runners/4242/labels` without registering that installation. Other later steps likewise retain the old path.

Shape: bypass path through edit/retry; stale evidence reused under a changed identity. Bind operation progress and consent to immutable server/scope/path/name/group identity, or safely invalidate dependent progress on changes. Do not describe this as acceptable 'current draft' behavior: it directs writes using a different registration's evidence. Add scope/path/group edits during and after work plus retry tests and a narrowing mutant. repeat-of: none (explicitly flagged in rev1 as an unnumbered rework bound).

### R2-F4 — P1: partial repository lists are reported as complete confirmation

`GitHubRunnerAPIClient.swift:321–322` ignores pagination; Flow.applyRepositoryAccess replaces the draft's selected IDs with the returned first page and emits success. `reviewR2RepositoryConfirmationMustFollowPagination` returns a valid first page with total_count and a next Link, then a second page: the flow emits `[9]` instead of `[9,10]` and never requests page 2. A later apply can consequently delete access omitted from the first page. Adding per_page=100 to other endpoints does not implement complete listing.

Shape: partial read presented as complete evidence. Follow pagination for repository, runner and group lists; preserve failure/unknown on any failed page and compare complete confirmed IDs to requested IDs. Add multipage/second-page-failure production tests and a narrowing mutant skipping only later pages. repeat-of: none (explicitly flagged in rev1 as an unnumbered rework bound).

### R2-F5 — P2: service setup declares registration complete without registration

`RunnerRegistration+Flow.swift:443–456` requires only draft/installPath. WizardSteps exposes Setup Service even when registration was skipped/failed. `reviewR2ServiceCannotClaimDoneBeforeRegistration` downloads the package, skips registration, then receives serviceReady and a written manual-service.plist. The reducer maps serviceReady to phase done and the page says the runner is registered.

Shape: absent evidence treated as satisfied. Require verified configured local identity for this operation before service creation/completion; reflect prerequisite state in UI. Add skipped/failed/corrupt-registration tests and a narrowing mutant. repeat-of: none.

## API contract correction and remaining bounds

GitHub's rendered download examples omit checksum, but its official OpenAPI runner-application schema DOES define optional `sha256_checksum`. Inspected the actual schema via a read-only download; required fields are os, architecture, download_url and filename. Therefore the producer is correct that the field exists in the schema. Fail-closed missing-checksum behavior is now tested and passes; no claim is made here about actual checksum availability for a live authenticated response. That remains the separate smoke task's bound, not an inferred absence.

Sources: https://github.com/github/rest-api-description/blob/main/descriptions/api.github.com/api.github.com.json ; https://docs.github.com/en/rest/actions/self-hosted-runners ; https://docs.github.com/en/rest/actions/self-hosted-runner-groups

Container → Flow → actor services → reducer wiring fits the existing architecture. The five demonstrated defects require implementation rework, not a human decision or external blocker. Preserve the seven now-green controls while adding regressions above.

Logbook: no logbook executable, connector, or repository logbook was available. Findings are persisted in this artifact and task notes rather than creating product files.
