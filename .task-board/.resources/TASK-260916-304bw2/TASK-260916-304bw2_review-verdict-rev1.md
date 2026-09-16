# TASK-260916-304bw2 review — CR revision 1

Verdict: changes_requested
Route: to-dev
repeat-of: none
Candidate: 4fd6231b0b81c3d9cc52095236490fa35f9e15c3 (repository_delta=present).

## Findings

### F1 — P1: Unknown service state authorizes unregister
repeat-of: none
Shape: absent evidence treated as satisfied; failure-to-read treated as absence.
`Runners+Flow.swift:377-382` refuses only `.running`. The app confirmation (`ManagementWindowContainer.swift:201`) has the same weakness. A launchctl permission error produces `.unknown`, then the production `.unregister` effect mints a remove token and invokes config.sh remove. This violates the stopped-only contract and can unregister a live runner when inspection failed.
Reproduced by `reviewUnknownServiceMustRefuseUnregister`: both no-network and no-installer-call assertions fail. Require positive confirmed stopped evidence, refuse unknown/missing observations, and revalidate at the side-effect boundary. Keep a named production-entry regression and narrowing mutant that admits unknown while retaining the running refusal.

### F2 — P1: Group Apply bypasses server binding
repeat-of: none
Shape: bypass path around the check.
`Runners+Flow.swift:880-915` calls `verifiedOrgRunner` and uses the authenticated host without comparing it to the local registration host. Load has a host check, Apply does not. A local ghe.example.com/acme runner with agent ID 42/name r and a github.com session can PUT repository access for an unrelated github.com group with matching numeric IDs/name. The mutable local registration / session must be revalidated at Apply, not assumed from an earlier Load.
Reproduced by `reviewCrossServerGroupApplyMustRefuse`: a PUT is emitted and success access is published. Bind server+scope+agentID+canonical service identity on the write path; preserve that binding over asynchronous boundaries and session changes. Add the named regression and a host-check narrowing mutant. No real API request was made.

### F3 — P1: Same-name imports share service/control identity
repeat-of: none
Shape: check present but tested below the production import path; capability claim that does not reproduce.
`Runners+Flow.swift:243-246` generates labels solely from agentName. Two manifest-free folders named runner `same`, in scopes acme/a and acme/b, both become `actions.runner.imported.same`. Catalog accepts both because it dedupes only directories. UI/operation state and `LaunchAgentService.setEnabled` identify by label and select the first entry, so the second runner cannot be controlled independently. The existing store-only same-name test misses label generation.
Reproduced by `reviewSameNameFolderImportsMustHaveDistinctServiceIDs`: two entries are stored but only one serviceLabel exists. Generate collision-safe persistent service identities, reject conflicting imported labels appropriately, and drive import plus per-runner controls in the maintained regression. Narrowing mutant should revert to name-only label identity.

### F4 — P2: Removing the final catalog entry is undone at restart
repeat-of: none
Shape: absent evidence treated as satisfied (empty is confused with not migrated).
`RunnerCatalog.swift:190-192` reruns migration whenever load() returns an empty list. Removing the last entry deliberately saves an empty catalog; the next `.loadCatalog` / startup silently reimports the still-existing installation.
Reproduced by `reviewRemovedLastEntryMustStayRemovedOnMigration`: migrate, remove last entry, verify empty, rerun migration -> entry returns. Persist migration completion independently of entry count; keep empty catalog authoritative. Also distinguish malformed/unreadable/unsupported-version persistence from first-run absence (`load` currently returns [] for all). Add a restart/removal regression and a narrowing mutant admitting initialized-empty catalogs to migration.

## Evidence and bounds

AC map inspected before source: producer reports 18 of 19 rows driven, with row 18 explicitly manual. That is nominal coverage, not acceptance: rows 3/11/12/16 lack the negative boundaries above; same-name coverage was only at the store entry. Manual corrected-autostart CUA precondition is acknowledged, not repeated. Producer lists 17 narrowing mutants, zero survivors; reviewer did not replay that campaign.

Exact candidate package extracted with `git archive 4fd6231... Packages/RunnerControlCore` into `/tmp/TASK-260916-304bw2-review`. Production sources unmodified; appended the attached probe fragment only to the temporary copy's existing lifecycle test file, reusing its controlled IO fixtures. Four of four adversarial scenarios driven through production functions/effects failed their required safety assertions (6 assertion failures, swift test exit 1). No production services, login registrations, credentials, or remote APIs were changed. No repository code modified.

Attached CR validation log was materialized and its command terminators inspected: 197 Swift tests pass, then 62 Python release tests pass, both exit 0. These are prior candidate evidence, not reviewer reruns. Reviewer separately reran four existing focused controls (see attached controls log). Native signed build is reported in producer outcome and corrected manual CUA; reviewer did not rebuild or claim independent signature validation because these reproducible failures already require rework.

Evidence attachments: TASK-260916-304bw2_review-probes-rev1.swift, TASK-260916-304bw2_review-probes-rev1.log, TASK-260916-304bw2_review-controls-rev1.log. Reproduce by appending the Swift fragment to Tests/RunnerCatalogLifecycleTests.swift in an isolated copy of the candidate and running the exact logged filter command (adjust package path).

No external blocker or human decision required. Repair in this leaf, retain named regressions and narrowing mutants, rerun changed-path validation, then return for independent review. The four demonstrated failures are not an exhaustive correctness claim about remaining paths.
