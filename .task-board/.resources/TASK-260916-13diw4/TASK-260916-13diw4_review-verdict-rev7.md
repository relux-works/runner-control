# Verdict: changes_requested

Task: TASK-260916-13diw4
Change Request: CR-TASK-260916-13diw4-7, revision 7
Candidate tree: 3c9045533cac0e31c14aed850b9ea285013fbfef
Route: to-dev
repeat-of: revision 6 / R6-F1

## Evidence and scope

Checked AC coverage before code: **8 of 8 AC rows driven** by named production-entry tests in outcome_v7. Driving coverage is not satisfaction: resource ownership still fails below.

All 19 candidate paths byte-match the Story worktree. Candidate diff --check passes. R6-to-R7 delta is limited to installer and registration tests. Confirmed Container effect dispatch and RunnerRuntime module registration; download/config call acquireLease and service/recovery call requireIdleDirectory. Original acquired-key release remains intact. Story-worktree production and test source were not modified. Exact candidate archived to /tmp/TASK-260916-13diw4-review7; additional reviewer test exists only in that disposable copy.

Independent bounded execution (180-second process-group timeout, completed normally): five focused tests executed, four controls passed and one attack failed with four issues (exit 1):
- reviewerCaseAliasMissingLeafCannotBypassDirectoryLease: PASS, one download, identical inodes.
- reviewerSymlinkAliasCannotBypassDirectoryLease: PASS.
- nonconflictingInstallProceedsWhileOtherDirectoryRuns: PASS.
- leaseKeyCaseFoldingFollowsVolumeSensitivity: PASS.
- reviewerUnicodeCaseAliasCannotBypassDirectoryLease: FAIL, two downloads, identical inodes 460630541, no busy failure.

Accepted attached rev7 validation log as producer evidence of 160 Core tests and 4 metadata tests, both exit 0, required=2 green=2 failed=0 missing=0. Full suite/build not independently repeated. Native BUILD SUCCEEDED and M31 narrowing kill are producer-reported in outcome_v7; M31 addresses ASCII case aliases, not the failing class. Earlier unchanged campaigns not repeated. The inode assertion relocation in the adopted ASCII regression is justified: the fixed refused path creates nothing while the first download is latched, so physical identity can only be asserted after settlement.

Run is not goal-bound (spawn goal checked). No UI tests, live API mutations, production runner operations, commits, or branch changes.

## R7-F1 — P1: Unicode case equivalence bypasses canonical directory lease

repeat-of: revision 6 / R6-F1
Shape: bypass path around the check; path spelling substitutes for resource identity.

RunnerInstallerService.swift:116 lowercases with POSIX locale, but lowercase equality does not represent the target filesystem equivalence relation. On the real case-insensitive host filesystem, runner-σ and runner-ς address the same directory while lowercasing leaves distinct keys. Gates.validateNoSpace accepts both names, so this is a supported input through production Flow.apply, not an injected sensitivity override or a filesystem-swap attack.

Exact attached reviewerUnicodeCaseAliasCannotBypassDirectoryLease derives from the accepted ASCII test with only the two installation spellings and test name changed (first draft installation name explicitly set). It starts and latches the first download with the leaf absent, begins a new draft under the equivalent spelling, then invokes downloadAndInstall. The second download/extraction is admitted while the first is alive. Observed calls=2 and no busy failure; after settling, both paths have identical non-nil inode numbers. Four assertions fail. Thus the claimed exclusive directory ownership is violated without changing anything on disk externally.

The outcome explicitly calls Unicode an approximate bound, but the R7 brief requires filesystem equivalence and forbids deferring findings as acceptable bounds. This is a reproduced violation of the same class, not a demand for speculative platform coverage. The forced-sensitive control also uses a case-insensitive physical filesystem, so it verifies branching only and must not be described as proof of distinct physical-directory behavior on a sensitive volume.

Required rework: fix the existing canonical resource owner for supported filesystem-equivalent names and stable pre/post-creation identity, retaining original-key release and independent physical-directory concurrency. Adopt the attached exact Flow regression and a narrowing mutant that retains ASCII and symlink exclusion but admits the Unicode equivalence class. Preserve prior controls. Do not add a separate research/harness task or silently narrow supported names to ASCII. If using a platform equivalence primitive, exercise it through the production Flow and prove physical identity rather than assuming string conversion matches filesystem semantics.

## Disposition

Ordinary implementation rework, not a human-only blocker. No logbook executable was available; this task-scoped verdict and board notes persist the finding. Attach attack source and complete log before routing to-dev.
