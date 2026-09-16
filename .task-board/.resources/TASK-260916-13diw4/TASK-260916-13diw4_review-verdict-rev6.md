# Verdict: changes_requested

Task: TASK-260916-13diw4
Change Request: CR-TASK-260916-13diw4-6, revision 6
Candidate tree: 6ec7e124c1a303766516222406085c6c7e0f4576
Route: to-dev
repeat-of: revision 5 / R5-F1

## Evidence and scope

Checked coverage before code: **8 of 8 AC rows driven** by named production-entry tests in outcome_v6. Driving coverage does not imply satisfaction: exclusive directory ownership still fails below.

All 19 candidate paths byte-match the Story worktree; candidate whitespace check passes. Reviewed production Flow.apply -> RunnerInstallerService and confirmed runtime module registration and Container dispatch. No product or Story-worktree source modified. Exact candidate archived to /tmp/TASK-260916-13diw4-review6; reviewer test appended only there.

Independent execution:
- 10 focused controls pass, exit 0: symlink regression, nearest-existing-ancestor and Finder alias controls, prior same-directory config retry, begin/reset during download, cancel during config, stale failure, in-flight install, and nonconflicting-directory control. Complete command and test names in attached controls log.
- reviewerCaseAliasMissingLeafCannotBypassDirectoryLease fails, exit 1, 4 assertions. Reproduced twice; final run includes physical identity assertion and prints two download calls with identical filesystem inode for both spellings (460498252). Physical identity assertion passes.

Accepted the attached rev6 validation log as producer evidence: completed 157 Core tests and 4 metadata tests, both exit 0, required=2 green=2 failed=0 missing=0. Did not rerun the full suite or native build. Native build and narrowing M30 kill are producer-reported in outcome_v6, not independently re-established here. The M30 symlink class passes the independent pristine control but does not cover the failing case-folded missing-leaf class. No need to repeat unchanged M1-M29 campaigns.

Run is not goal-bound per spawn goal. No live API mutations, UI tests, production runner operations or commits.

## R6-F1 — P1: missing-leaf case alias bypasses canonical directory lease

repeat-of: revision 5 / R5-F1
Shape: bypass path around the check; path spelling substitutes for resource identity before directory creation.

RunnerInstallerService.swift:69-89 canonicalizes the nearest existing ancestor, then appends the missing suffix verbatim. On this case-insensitive filesystem, macbook-test and MACBOOK-TEST are the same directory but acquire different keys while the leaf is absent. downloadAndInstall acquires before awaiting download and creates the directory only afterwards. Thus a normal draft edit while download is in flight can admit concurrent mutations of the same physical resource. No symlink swap or malicious filesystem change is required.

Exact attached regression reviewerCaseAliasMissingLeafCannotBypassDirectoryLease drives production Flow.apply:
1. Begin macbook-test; suspend its first download. Assert install directory is absent.
2. Begin a new draft with installDirName MACBOOK-TEST; invoke downloadAndInstall while the original operation is alive.
3. Second download/extract completes instead of reporting directoryBusy. Observed download calls = 2; no failure recorded.
4. Assert both spellings address the same inode, release original download, and settle both operations.

The test demonstrates concurrent admitted downloads/extractions for one physical directory, not two remote GitHub registrations. Same physical directory identity is directly established, not inferred from spelling. All operations use temporary fixtures and controlled transport.

Required change: give not-yet-created installation paths the same resource identity according to the target filesystem equivalence rules, while preserving distinct physical-directory concurrency. Identity must remain consistent before/after creation and across download/config/service/recovery; retain original-key release. Resolve this within the existing canonical lease owner, not as a new research or harness task. Adopt the attached named Flow regression with a focused narrowing mutant that retains ordinary and symlink exclusion but admits the case-alias class; keep existing controls green. Do not simply assume every filesystem is case-insensitive when defining physical identity.

## Disposition

The exact R5 symlink attack is fixed, but the same canonical-resource class remains bypassable. This is ordinary implementation rework, not an external blocker or human-only decision. No logbook executable was available; this attached verdict, test/log evidence and board notes persist the finding.
