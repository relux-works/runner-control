# Verdict: changes_requested

Task: TASK-260916-13diw4
Change Request: CR-TASK-260916-13diw4-5, revision 5
Candidate tree: 3c311b2cb4800eaaaf5f30eb3289493bd2038df7
Route: to-dev
repeat-of: revision 4 / R4-F1

## Evidence and scope

Checked AC coverage before code: **8 of 8 AC rows driven** by named production-entry tests in outcome_v5. Driving coverage does not establish satisfaction: the repeated-operation requirement fails in the alias attack below.

Archived the exact candidate to /tmp/TASK-260916-13diw4-review5 and appended one reviewer test only there. No product source edits. All 19 changed Story-worktree paths byte-match the candidate; candidate diff whitespace check passes. Production Container dispatch and RunnerRuntime module registration reach Flow.apply and the installer.

Independent executions (complete logs attached):
- Lifecycle filter: reviewerSymlinkAliasCannotBypassDirectoryLease plus the seven revision-5 lifecycle controls. **Exit 1: 8 tests, 7 passed, alias attack failed with 2 assertions.**
- Prior identity/scope/public-repo/checksum controls: **Exit 0: 14 tests passed.** Exact filter and tests appear in attached log. Includes foreign-server, work-folder, group-change, in-flight labels/access, duplicate-name, public-group, missing-checksum and end-to-end controls.

The rev5 producer validation log has a completed terminal tail: **154 Core tests and 4 metadata tests, exit 0**, required=2 green=2 failed=0 missing=0. Accepted as attached producer evidence, not independently replayed full validation. Native build success and M28/M29 killed are reported in outcome_v5; this review did not independently establish the build or rerun those mutants. No UI tests, live GitHub mutations, production runner operations or commits. The attack uses production Flow and installer, controlled transport/config executor, real temporary filesystem and symlink. It proves admission and filesystem overwrite, not actual creation of two remote GitHub registrations. Run is not goal-bound per spawn goal.

## R5-F1 — P1: directory lease can be bypassed through a symlink alias

repeat-of: revision 4 / R4-F1
Shape: bypass path around the check through retry; path spelling substitutes for resource identity.

RunnerInstallerService.swift:65–66 calls standardizedFileURL.path for leaseKey. This normalizes spelling but does not resolve symlinks. Consequently two accepted install folder names pointing to the same physical directory acquire independent leases. The same key is used for install/config acquisition and service/recovery refusal.

Exact production-entry regression: reviewerSymlinkAliasCannotBypassDirectoryLease (attached source; variant of the adopted R4 attack). Install macbook-test, suspend its first config command, create alias-install as a symlink to macbook-test, update the draft to alias-install / renamed-runner, invoke downloadAndInstall and registerRunner before releasing the first command. Download reuses the installed marker through the alias; registration acquires a second lease and executes config again. Observed:
- **2 config calls while the first remains live**, expected 1.
- Reducer reports registerRunner complete for renamed-runner, then the old config writes macbook-test to the same physical .runner; completed state contradicts the local registration.

This requires an existing filesystem alias, not a concurrent malicious symlink swap. Both folder names pass normal draft validation. Existing production runners were never touched.

Required change: make lease ownership represent canonical filesystem identity consistently across install/config/service/recovery and hold the originally acquired identity until settlement, or explicitly refuse aliased installation paths before any side effect. Account for existing symlink ancestors and the actual filesystem's aliases when defining identity. Keep safe nonconflicting directories usable. Adopt the attached named Flow-entry regression and a narrowing mutant that preserves ordinary same-spelling exclusion while admitting an alias class. Preserve all seven R5 and 14 prior controls. This is focused rework of the already-required canonical-directory lease, not a new research or harness task.

## Disposition

R4-F2 stale failure cleanup and same-spelling R4-F1 overlap controls now pass. Canonical directory ownership is still incomplete, so revision 5 is not accepted. This is ordinary implementation rework, not an external blocker or human-only decision.

No logbook executable or repository logbook was found. This task-scoped verdict, attached attack/logs and board notes durably record the finding.
