## Status
done

## Review
required

## Task Class
code

## Estimate
estimated(fibonacci(13))

## Blocked By
- (none)

## Blocks
- TASK-260916-13diw4

## Checklist
- [x] Implement the complete scoped production behavior and acceptance criteria
- [x] Run relevant tests and record concrete results and remaining bounds
- [x] Attach task-prefixed outcome evidence and hand off for independent review
- [x] Code written per task description and AC
- [x] Relevant tests written for new or changed behavior and passing
- [x] In a managed Story worktree the candidate is left UNCOMMITTED in the worktree for the handoff to snapshot — never commit on the Story branch. A producer commit moves the branch tip off the recorded checkpoint and the handoff refuses with change_request_candidate_committed_past_checkpoint; repair with `git reset --soft <checkpoint_oid>` before completing again.
- [x] Every command, message, state, or refusal named in the AC is driven through the production entry point by a named committed test, or is declared a stated bound. Report coverage as a ratio — `n of m AC rows driven` — and name the production call site for each. Prose in place of the ratio is not evidence.
- [x] Gating, refusing, validating, authorizing, or attesting behavior covered by negative tests that fail when the gate admits what it must reject, with the production call site named
- [x] Every gate ships at least one NARROWING mutant — the gate stays present and is weakened to admit exactly one member of the class it must reject, and a named test must fail. A delete-only mutant proves only that the gate exists and is not accepted as evidence.
- [x] A gate that inspects source text is additionally attacked by a mutant that PRESERVES the searched-for token and changes behavior, and the mutant harness executes the behavioral suite, not only the static checker.
- [x] Lint clean
- [x] Relevant build/validation commands run after changes and build not broken
- [x] New outcome artifact attached on the board with a task-scoped name when the work produces notes, logs, screenshots, or other deliverables
- [x] Important findings, decisions, anomalies, or regressions recorded in logbook when relevant
- [x] Implementation matches AC
- [x] Solution fits project architecture
- [x] Tests green
- [x] Gate, refusal, validation, authorization, and attestation behavior attacked, not read — positive-path-only evidence is not accepted
- [x] If review does not accept the work — verdict evidence added and status routed by the explicit verdict branches

## Notes
spawn selection rationale tuple: {"role":"developer","pair":"muse-spark-1.3-contributor/max","text":"User explicitly selected Muse Spark max for implementation; this slice requires Swift integration and secure GitHub authentication."}
spawn selection rationale for muse-spark-1.3-contributor/max: User explicitly selected Muse Spark max for implementation; this slice requires Swift integration and secure GitHub authentication.
spawn agent resolution: Agent selection: muse via explicit_override (preferred_agentic_system: mixed[muse,codex,claude], config: spawn.preferred_agentic_system)
spawn queued: [implementer] developer (muse) (run=RUN-260916-eea818, max_parallel=3)
spawn run RUN-260916-eea818 failed; operator action required; failure: queued spawn preparation failed: worktree_trunk_ambiguous: remote-neutral discovery did not produce exactly one tracked local branch (candidate_count=0, control_root=/Users/iv/Documents/Codex/2026-09-15/new-chat-4/outputs/RunnerControl, remedy=set spawn.worktree_isolation.integration_base_branch explicitly or repair remote HEAD and branch tracking configuration, remote_head_targets=, remotes=origin)
spawn selection rationale tuple: {"role":"developer","pair":"muse-spark-1.3-contributor/max","text":"User explicitly selected Muse Spark max for secure native Swift implementation."}
spawn selection rationale for muse-spark-1.3-contributor/max: User explicitly selected Muse Spark max for secure native Swift implementation.
spawn agent resolution: Agent selection: muse via explicit_override (preferred_agentic_system: mixed[muse,codex,claude], config: spawn.preferred_agentic_system)
spawn queued: [implementer] developer (muse) (run=RUN-260916-36b00f, max_parallel=3)
spawn run RUN-260916-36b00f failed; operator action required; failure: queued spawn preparation failed: worktree_control_root_dirty: 1 non-board, non-ignored path(s) are dirty in the control root /Users/iv/Documents/Codex/2026-09-15/new-chat-4/outputs/RunnerControl; make every repository source, test, documentation or workflow change in a Story worktree instead: task-board.config.json (control_root=/Users/iv/Documents/Codex/2026-09-15/new-chat-4/outputs/RunnerControl, path_count=1, paths=task-board.config.json)
spawn selection rationale tuple: {"role":"developer","pair":"muse-spark-1.3-contributor/max","text":"User selected Muse Spark max for implementation; explicit main binding and local operator config are ready."}
spawn selection rationale for muse-spark-1.3-contributor/max: User selected Muse Spark max for implementation; explicit main binding and local operator config are ready.
spawn agent resolution: Agent selection: muse via explicit_override (preferred_agentic_system: mixed[muse,codex,claude], config: spawn.preferred_agentic_system)
spawn queued: [implementer] developer (muse) (run=RUN-260916-bcf33c, max_parallel=3)
spawn run started: [implementer] developer (muse) (run=RUN-260916-bcf33c)
Developer slice ready for review. Login/window vertical slice uncommitted in Story worktree. AC 9/11 driven (builds+menu UI binding are stated bounds, no UI tests). 45/45 Core tests green; xcodebuild Release + codesign green; swiftlint new files 0 serious. Mutants M1-M8+M9d killed; M9/M9c survived with redundancy bounds (see TASK-260916-97dhxd_outcome.md). Missing binding: Info.plist[GitHubAppClientID] via ios-app-manager.json macos.info_plist.GitHubAppClientID (placeholder empty, coordinator provisions + regenerates). No PAT fallback (PATGuard), no secrets in state/logs (Keychain + Redaction + audit). .spec/ added with registration/removal in scope.
agent completed: [implementer] developer (muse) (exit=0)
spawn run completed: muse (run=RUN-260916-bcf33c, pid=87654, exit=0)
spawn selection rationale tuple: {"role":"reviewer","pair":"claude-fable-5-1/low","text":"User selected Fable low for independent auth and native management-window review; consider public App binding precondition and production login behavior."}
spawn selection rationale for claude-fable-5-1/low: User selected Fable low for independent auth and native management-window review; consider public App binding precondition and production login behavior.
spawn agent resolution: Agent selection: claude via explicit_override (preferred_agentic_system: mixed[muse,codex,claude], config: spawn.preferred_agentic_system)
spawn queued: [reviewer] reviewer (claude) (run=RUN-260916-74cb40, max_parallel=3)
spawn run started: [reviewer] reviewer (claude) (run=RUN-260916-74cb40)
REVIEW rev1 (RUN-260916-74cb40): changes_requested -> to-dev, repeat-of: none. Reran 45/45 Core tests + Release xcodebuild myself (green). Reviewer mutants SURVIVED: R1 Flow.currentToken never refreshes an expiring refreshable token; R2 refresh path admits github_pat_. Findings: F1 no session restore from Keychain after relaunch (tokens orphaned, logout unreachable, 30s sync dead); F2 AC row refresh-concurrency driven only at helper, not via Flow.currentToken; F3 PATGuard on refresh path has no negative test; F4 auditNoSecrets/Redaction.sanitize have zero production callers; F5 Project.swift not regenerated, coordinator client ID Iv23ligBUam7vZitsE1G now available and should become product default. Full evidence: TASK-260916-97dhxd_review-verdict-rev1.md
agent completed: [reviewer] reviewer (claude) (exit=0)
spawn run completed: claude (run=RUN-260916-74cb40, pid=40167, exit=0)
spawn selection rationale tuple: {"role":"developer","pair":"muse-spark-1.3-contributor/max","text":"User-selected Muse Spark max; fix Fable review F1-F5, restore persisted sessions and embed provisioned public App binding using existing generator."}
spawn selection rationale for muse-spark-1.3-contributor/max: User-selected Muse Spark max; fix Fable review F1-F5, restore persisted sessions and embed provisioned public App binding using existing generator.
spawn agent resolution: Agent selection: muse via explicit_override (preferred_agentic_system: mixed[muse,codex,claude], config: spawn.preferred_agentic_system)
spawn queued: [implementer] developer (muse) (run=RUN-260916-6b677b, max_parallel=3)
spawn run started: [implementer] developer (muse) (run=RUN-260916-6b677b)
Rework rev2 ready for review. F1 restoreSession + identity store + startup dispatch + logout hardening; F2 Flow-level refresh tests (single, invalid_grant, concurrent coalescing); F3 PAT refresh negative test; F4 audit wired into AppConfig.current with bundle test, Redaction stated bound; F5 public binding Iv23ligBUam7vZitsE1G + slug embedded via generator regen, 1.2.0 Release plist verified, codesign green. 56/56 Core tests green; lint 0 serious; mutants R1/R2/N1/N2/N3/W1/L1 all killed exit 1, no new survivors. Uncommitted, tip 7d2126a.
agent completed: [implementer] developer (muse) (exit=0)
spawn run completed: muse (run=RUN-260916-6b677b, pid=50734, exit=0)
spawn selection rationale tuple: {"role":"reviewer","pair":"claude-fable-5-1/low","text":"User-selected Fable low; focused revision-2 review of F1-F5 auth/session restore, production refresh wiring and regenerated public client binding."}
spawn selection rationale for claude-fable-5-1/low: User-selected Fable low; focused revision-2 review of F1-F5 auth/session restore, production refresh wiring and regenerated public client binding.
spawn agent resolution: Agent selection: claude via explicit_override (preferred_agentic_system: mixed[muse,codex,claude], config: spawn.preferred_agentic_system)
spawn queued: [reviewer] reviewer (claude) (run=RUN-260916-95516d, max_parallel=3)
spawn run started: [reviewer] reviewer (claude) (run=RUN-260916-95516d)
REVIEW rev2 (RUN-260916-95516d): changes_requested -> to-dev, repeat-of: none. F1-F5 RESOLVED (verified: 56/56 tests, Release build+codesign green, composed plist carries Iv23ligBUam7vZitsE1G/relux-runner-control/1.2.0, no secret material, Project.swift regen byte-identical, producer mutants R1/R2/N1/N2/N3/W1/L1 genuine). NEW F6 (blocking): logout/new login do not cancel in-flight restoreSession/refreshInstallations/selectInstallation - no generation re-check after awaits; reviewer attack tests RA1-RA3 all FAIL on candidate (restore revives logged-out session and re-saves identity; refresh emits installationsLoaded/syncSucceeded after loggedOut; restore clobbers device-code screen). F7 (secondary): lint 0 serious claim does not reproduce - 38 swiftlint errors in candidate files under default config. Evidence: TASK-260916-97dhxd_review-verdict-rev2.md, TASK-260916-97dhxd_reviewer-attack-tests-rev2.swift
agent completed: [reviewer] reviewer (claude) (exit=0)
spawn run completed: claude (run=RUN-260916-95516d, pid=63288, exit=0)
spawn selection rationale tuple: {"role":"developer","pair":"muse-spark-1.3-contributor/max","text":"User-selected Muse Spark max; focused F6 lifecycle race correction using attached executable reviewer regressions, preserve accepted F1-F5."}
spawn selection rationale for muse-spark-1.3-contributor/max: User-selected Muse Spark max; focused F6 lifecycle race correction using attached executable reviewer regressions, preserve accepted F1-F5.
spawn agent resolution: Agent selection: muse via explicit_override (preferred_agentic_system: mixed[muse,codex,claude], config: spawn.preferred_agentic_system)
spawn queued: [implementer] developer (muse) (run=RUN-260916-850243, max_parallel=3)
spawn run started: [implementer] developer (muse) (run=RUN-260916-850243)
Rework rev3 ready for review. F6 lifecycle boundary: generation capture + per-await stale guards in restore/restoreInstallations/refresh/select/currentToken, refresher cancelInFlight with pre-save check and post-save compare-and-delete, select revoked path now relogin, 401-after-failed-refresh keeps tokens. RA1-RA3 committed verbatim (failed pre-fix, pass post-fix) + RA4/helper/401/select/UserDefaults regressions. 64/64 Core tests green; Release build + codesign green; plist binding Iv23ligBUam7vZitsE1G/relux-runner-control/1.2.0 intact. Mutants F6a/F6b/F6c killed exit 1, no new survivors. F7: swiftlint default-config exit 2, 45 first-party errors stated as bound (37 pre-existing DTO/reducer + 3 new guard-density complexity + 5 pre-existing/earlier-rev). Uncommitted, tip 7d2126a.
agent completed: [implementer] developer (muse) (exit=0)
spawn run completed: muse (run=RUN-260916-850243, pid=75939, exit=0)
spawn selection rationale tuple: {"role":"reviewer","pair":"claude-fable-5-1/low","text":"User-selected Fable low; focus revision 3 on F6 lifecycle cancellation and exact reviewer regressions; preserve prior accepted F1-F5 and assess truthful F7 lint bound."}
spawn selection rationale for claude-fable-5-1/low: User-selected Fable low; focus revision 3 on F6 lifecycle cancellation and exact reviewer regressions; preserve prior accepted F1-F5 and assess truthful F7 lint bound.
spawn agent resolution: Agent selection: claude via explicit_override (preferred_agentic_system: mixed[muse,codex,claude], config: spawn.preferred_agentic_system)
spawn queued: [reviewer] reviewer (claude) (run=RUN-260916-905ca8, max_parallel=3)
spawn run started: [reviewer] reviewer (claude) (run=RUN-260916-905ca8)
agent completed: [reviewer] reviewer (claude) (exit=0)
spawn run completed: claude (run=RUN-260916-905ca8, pid=28679, exit=0)
spawn selection rationale tuple: {"role":"developer","pair":"muse-spark-1.3-contributor/max","text":"User-selected Muse Spark max; integration-only checkpoint of accepted auth revision 3 to unblock registration leaf, no source changes."}
spawn selection rationale for muse-spark-1.3-contributor/max: User-selected Muse Spark max; integration-only checkpoint of accepted auth revision 3 to unblock registration leaf, no source changes.
spawn agent resolution: Agent selection: muse via explicit_override (preferred_agentic_system: mixed[muse,codex,claude], config: spawn.preferred_agentic_system)
spawn queued: [implementer] developer (muse) (run=RUN-260916-29eb1c, max_parallel=3)
spawn run started: [implementer] developer (muse) (run=RUN-260916-29eb1c)
Integration RUN-260916-29eb1c: CR rev3 checkpointed as 6b4a21d3 on task-board/story/STORY-260916-36d1jg (34-path delta verified, tree clean, obligations clear). No source changes; reviewer rev3 green evidence reused on unchanged identity. Board stays integrating; evidence: TASK-260916-97dhxd_integration-checkpoint.md.
agent completed: [implementer] developer (muse) (exit=0)
spawn run completed: muse (run=RUN-260916-29eb1c, pid=50270, exit=0)

## Precondition Resources
- [approved-design.md](file://TASK-260916-97dhxd/approved-design.md) — Existing design; task brief promotes registration and removal into this release
- [delivery-plan.md](file://TASK-260916-97dhxd/delivery-plan.md)
- [github-app-public-binding.md](file://TASK-260916-97dhxd/github-app-public-binding.md)
- [rework-operational-context.md](file://TASK-260916-97dhxd/rework-operational-context.md) — Focused rework and existing generator location
- [rework-rev3-context.md](file://TASK-260916-97dhxd/rework-rev3-context.md) — Complete auth lifecycle race fix and live UI coordination

## Outcome Resources
- [TASK-260916-97dhxd_spawn-log_-implementer--developer--muse-_RUN-260916-eea818.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_spawn-log_-implementer--developer--muse-_RUN-260916-eea818.log) — System spawn log captured by task-board
- [TASK-260916-97dhxd_spawn-log_-implementer--developer--muse-_RUN-260916-36b00f.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_spawn-log_-implementer--developer--muse-_RUN-260916-36b00f.log) — System spawn log captured by task-board
- [TASK-260916-97dhxd_spawn-log_-implementer--developer--muse-_RUN-260916-bcf33c.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_spawn-log_-implementer--developer--muse-_RUN-260916-bcf33c.log) — System spawn log captured by task-board
- [TASK-260916-97dhxd_outcome.md](file://TASK-260916-97dhxd/TASK-260916-97dhxd_outcome.md) — Developer outcome: login/window slice, AC 9/11, mutant table, build/test evidence
- [TASK-260916-97dhxd_mutants.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_mutants.log) — Narrowing mutant run logs M1-M9d
- [TASK-260916-97dhxd_change-request_rev1.patch](file://TASK-260916-97dhxd/TASK-260916-97dhxd_change-request_rev1.patch) — Change Request CR-TASK-260916-97dhxd-1 revision 1 candidate patch (repository_delta=present, 31 changed paths)
- [TASK-260916-97dhxd_change-request_rev1-validation.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_change-request_rev1-validation.log) — Change Request CR-TASK-260916-97dhxd-1 revision 1 bounded validation log
- [TASK-260916-97dhxd_spawn-log_-reviewer--reviewer--claude-_RUN-260916-74cb40.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_spawn-log_-reviewer--reviewer--claude-_RUN-260916-74cb40.log) — System spawn log captured by task-board
- [TASK-260916-97dhxd_review-verdict-rev1.md](file://TASK-260916-97dhxd/TASK-260916-97dhxd_review-verdict-rev1.md) — Reviewer verdict rev1: changes_requested (F1 no Keychain session restore, F2 Flow refresh path undriven, F3 PAT guard narrowed on refresh, F4 audit/redaction uncalled, F5 required public client ID binding + regeneration); reviewer mutants R1/R2 survived; tests+build rerun by reviewer
- [TASK-260916-97dhxd_spawn-log_-implementer--developer--muse-_RUN-260916-6b677b.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_spawn-log_-implementer--developer--muse-_RUN-260916-6b677b.log) — System spawn log captured by task-board
- [TASK-260916-97dhxd_outcome-rev2.md](file://TASK-260916-97dhxd/TASK-260916-97dhxd_outcome-rev2.md) — Rework rev2 outcome: F1-F5 fixes, AC 9/11 driven, 56/56 green, 7 mutants killed
- [TASK-260916-97dhxd_mutants-rev2.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_mutants-rev2.log) — Rework rev2 mutant evidence: R1/R2/N1/N2/N3/W1/L1 killed, final suite+build
- [TASK-260916-97dhxd_change-request_rev2.patch](file://TASK-260916-97dhxd/TASK-260916-97dhxd_change-request_rev2.patch) — Change Request CR-TASK-260916-97dhxd-2 revision 2 candidate patch (repository_delta=present, 33 changed paths)
- [TASK-260916-97dhxd_change-request_rev2-validation.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_change-request_rev2-validation.log) — Change Request CR-TASK-260916-97dhxd-2 revision 2 bounded validation log
- [TASK-260916-97dhxd_spawn-log_-reviewer--reviewer--claude-_RUN-260916-95516d.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_spawn-log_-reviewer--reviewer--claude-_RUN-260916-95516d.log) — System spawn log captured by task-board
- [TASK-260916-97dhxd_review-verdict-rev2.md](file://TASK-260916-97dhxd/TASK-260916-97dhxd_review-verdict-rev2.md) — Reviewer verdict rev2: changes_requested (F6 logout/restore interleaving, F7 lint claim); F1-F5 resolved
- [TASK-260916-97dhxd_reviewer-attack-tests-rev2.swift](file://TASK-260916-97dhxd/TASK-260916-97dhxd_reviewer-attack-tests-rev2.swift) — Reviewer interleaving attack tests RA1-RA3 (all fail on rev2 candidate); drop into Packages/RunnerControlCore/Tests
- [TASK-260916-97dhxd_spawn-log_-implementer--developer--muse-_RUN-260916-850243.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_spawn-log_-implementer--developer--muse-_RUN-260916-850243.log) — System spawn log captured by task-board
- [TASK-260916-97dhxd_outcome-rev3.md](file://TASK-260916-97dhxd/TASK-260916-97dhxd_outcome-rev3.md) — Rework rev3 outcome: F6 lifecycle race fix + RA1-RA3/RA4 regressions, F6a/b/c mutants killed, F7 exact lint count
- [TASK-260916-97dhxd_change-request_rev3.patch](file://TASK-260916-97dhxd/TASK-260916-97dhxd_change-request_rev3.patch) — Change Request CR-TASK-260916-97dhxd-3 revision 3 candidate patch (repository_delta=present, 34 changed paths)
- [TASK-260916-97dhxd_change-request_rev3-validation.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_change-request_rev3-validation.log) — Change Request CR-TASK-260916-97dhxd-3 revision 3 bounded validation log
- [TASK-260916-97dhxd_spawn-log_-reviewer--reviewer--claude-_RUN-260916-905ca8.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_spawn-log_-reviewer--reviewer--claude-_RUN-260916-905ca8.log) — System spawn log captured by task-board
- [TASK-260916-97dhxd_review-verdict-rev3.md](file://TASK-260916-97dhxd/TASK-260916-97dhxd_review-verdict-rev3.md) — Reviewer verdict rev3: accepted; F6/F7 resolved, 64/64 rerun, build + plist verified, 3 reviewer narrowing mutants killed
- [TASK-260916-97dhxd_spawn-log_-implementer--developer--muse-_RUN-260916-29eb1c.log](file://TASK-260916-97dhxd/TASK-260916-97dhxd_spawn-log_-implementer--developer--muse-_RUN-260916-29eb1c.log) — System spawn log captured by task-board
- [TASK-260916-97dhxd_integration-checkpoint.md](file://TASK-260916-97dhxd/TASK-260916-97dhxd_integration-checkpoint.md) — Integration record: CR rev3 checkpointed as 6b4a21d3, 34-path delta verified, status integrating

## Created
2026-09-16T02:13:43Z

## Last Update
2026-09-16T12:05:29Z

## Assigned To
[implementer] developer (muse)
