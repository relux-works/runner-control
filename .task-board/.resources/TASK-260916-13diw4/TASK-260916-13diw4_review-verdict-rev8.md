# Verdict: accepted

Task: TASK-260916-13diw4
Change Request: CR-TASK-260916-13diw4-8, revision 8
Candidate tree: 0d7ea4a9dc6b4133cca2c9616a22a1ac75b06b13
Disposition: accept_cr; accepted for integration, not landed.

## Scope and coverage

Checked coverage before code: **8 of 8 AC rows driven**, with named tests and production call sites in outcome_v8 (org/repo wizard, selected repositories, access/labels editing, failures, retries, secret hygiene, actual entry points). Repository delta is present. All 19 candidate paths byte-match the Story worktree; candidate and worktree diff --check pass. R7-to-R8 changes are confined to installer lease implementation, error wording, Flow comments and tests.

The coordinator explicitly superseded independent-directory concurrency with one mutating installer operation per app instance. The implementation follows that decision: a UUID owner is acquired before download/config awaits and released by defer only after completion; no filesystem spelling participates in admission. Synchronous setup/recovery respect the same owner and cannot interleave internally under actor isolation. Container dispatch reaches the registered Flow; AppRegistry has one guarded composition root and RunnerRuntime supplies one shared installer to that Flow. Ordinary runner control uses its separate service path.

R7-F1 is resolved by eliminating the path-equivalence decision, not by adding another approximate normalization. Prior server/scope/work-folder identity and UI generation gates are unchanged. No new acceptance finding.

## Independently executed

180-second bounded subprocess groups, both completed exit 0:
- 17 focused tests passed in the actual candidate worktree: alias/case/Unicode, stale failure, beginDraft/reset/cancel, duplicate config, different-directory busy/retry, local identity controls; the broad reviewer-name filter also selected five existing auth lifecycle controls.
- New reviewerGlobalLeaseBlocksServiceAndRecovery passed in an archived exact candidate at /tmp/TASK-260916-13diw4-review8. Only that disposable copy received the reviewer test. It starts download via Flow.apply, cancels UI, attempts service setup and partial recovery on another physical directory, asserts busy refusal and no filesystem mutation, then settles the owner and verifies both operations succeed. This attacks the bypass-path shape across synchronous production service/recovery entries.
- Unicode and ASCII alias tests each observed one download and equal post-settlement inode identities.

Attached focused log, additional attack source and complete attack log. No Story-worktree source changes, UI tests, production runner operations, live API mutations, commits or branch changes.

## Accepted producer evidence and bounds

Read complete attached rev8 validation log: 158 Core tests and 4 metadata tests, both exit 0; required=2 green=2 failed=0 missing=0. Full suite was not independently repeated. Read completed /tmp/r8_build.log (BUILD SUCCEEDED, EXIT:0), now preserved on the board; native build was not independently repeated. No configured lint gate; whitespace checks pass.

Read M32 narrowing log: same-path-only refusal admits different-directory concurrency; secondInstallForAnyDirectoryRefusedWhileInstallerBusy fails with three behavioral issues (exit 1), while two same-path controls pass under the mutant. Preserved kill log on board. Installer pristine SHA256 matches the producer restoration record: 7d3b98e94e0e2273102de518357021305ecb19b673de6d3a3669ac6d5edcf7d5. Did not rerun unchanged M1-M31 campaigns, as directed. Earlier M9 bound remains contextual producer evidence, not a fresh campaign claim. No source-text gate requires a token-preserving mutant here.

This review establishes controlled production-entry behavior, not live GitHub registration or release. Those remain separate smoke/integration delivery work. spawn goal reports this run is not goal-bound. All merged checklist rows were checked. No logbook executable is available; this artifact and board notes persist the decision.
