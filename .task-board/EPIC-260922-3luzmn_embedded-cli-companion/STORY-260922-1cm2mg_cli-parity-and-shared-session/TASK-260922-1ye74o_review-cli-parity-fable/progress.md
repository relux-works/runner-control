## Status
done

## Review
none

## Task Class
metadata

## Estimate
notEstimated

## Blocked By
- TASK-260922-2qddb7

## Blocks
- TASK-260922-39urz9

## Checklist
- [x] Read proposal.md and the full uncommitted diff vs fb85df5
- [x] Verify GUI-effect parity claim command by command
- [x] Assess shared-session and Keychain safety
- [x] Assess JSON/exit-code contract for harnesses
- [x] Record verdict (accept/accept-with-findings/reject) with reasons in notes
- [x] Implementation matches AC
- [x] Solution fits project architecture
- [x] Tests green
- [x] Gate, refusal, validation, authorization, and attestation behavior attacked, not read — positive-path-only evidence is not accepted
- [x] If review does not accept the work — verdict evidence added and status routed by the explicit verdict branches

## Notes
spawn selection rationale tuple: {"role":"reviewer","pair":"claude-fable-5-1/high","text":"Independent second release-blocking review; user explicitly authorized high for both reviews"}
spawn selection rationale for claude-fable-5-1/high: Independent second release-blocking review; user explicitly authorized high for both reviews
spawn agent resolution: Agent selection: claude via explicit_override (preferred_agentic_system: mixed[muse,codex,claude], config: spawn.preferred_agentic_system)
spawn queued: [reviewer] reviewer (claude) (run=RUN-260922-85b26f, max_parallel=3)
spawn run started: [reviewer] reviewer (claude) (run=RUN-260922-85b26f)
fable review RUN-260922-85b26f started 2026-09-22T18:19Z. set_status(reviewing) refused: blocked by TASK-260922-2qddb7 (to-dev). Proceeding with read-only review; verdict will be recorded in notes + outcome resource, status retried at end.
fable review (RUN-260922-85b26f, 2026-09-22): VERDICT changes_requested -> to-dev. Astra verdict not read. Reran Core 269/269, CLI 18/18, Python 97/97; codesign verify OK; app+CLI one identity (V8V53456PB), universal; binary newer than sources. Blocking findings (bypass first): (1) argv0-self-location [bypass] CLIInstallerService.swift:70-72 + CLIConfig.swift:39-82 derive the binary from argv[0]; via the PATH symlink (the intended install) install-cli creates a DANGLING link to $CWD/runner-control and replaces a working one, uninstall-cli refuses a correct link, app version reports standalone — reproduced A5/A6/A7. (2) error-envelope-bypass [robustness] CLIEntry.swift:42-51 envelopes only CLIFailure: ArgumentParser errors exit 64 (contract says 1) with no JSON even with --json (A1/A2); runtime errors (URLError in check-updates) exit 1 = usage code with no JSON (B1). (3) login-item-mechanism [bypass, reproduction specified not executed under guardrails] GUI uses SMAppService.mainApp (LaunchAtLoginModel.swift:9-17), CLI uses System Events legacy login items via osascript (AppCommands.swift:306-330): different persisted registrations, status disagrees, and osascript needs a TCC Automation prompt. Notes: N1 decomposition claims a flock lease in CLIInstallerService (none exists; flock is in RunnerInstallerService); N2 UNKNOWN whether a GUI-created Keychain item is read prompt-free by the same-team CLI (evidence seeded a TESTCLIENT slot by an unrecorded method; code comment any-team contradicts verification.md denied cross-team read); N3 cross-process lock test passes silently when the helper cannot start (measured to have actually run here: HELD in 0.57s, test 0.93s); N4 lockInstallRoot fails open; N5 string booleans in app payloads; N6 remove --json drops the keeps-running note. Parity matrix: all GUI Relux effects have CLI equivalents (importFolder⊃importCandidate, loadCatalog⊃refresh, setEnabledMany, selectRepositories→--repo-id, UI-only: selectRunner/clearLog/updateDraft/cancel/reset/retry/dismissPermission). Full artifact: TASK-260922-1ye74o_review-verdict.md. set_status(reviewing) was refused at start (blocked by TASK-260922-2qddb7 in to-dev).
agent completed: [reviewer] reviewer (claude) (exit=0)
spawn run completed: claude (run=RUN-260922-85b26f, pid=35380, exit=0)
Verdict delivered (changes_requested, 3 findings + 6 notes). Orchestrator integrated every blocking finding + notes; no re-review run (high ceilings were one-time). Evidence: specs/embedded-cli-companion/verification.md.

## Precondition Resources
(none)

## Outcome Resources
- [TASK-260922-1ye74o_spawn-log_-reviewer--reviewer--claude-_RUN-260922-85b26f.log](file://TASK-260922-1ye74o/TASK-260922-1ye74o_spawn-log_-reviewer--reviewer--claude-_RUN-260922-85b26f.log) — System spawn log captured by task-board
- [TASK-260922-1ye74o_review-verdict.md](file://TASK-260922-1ye74o/TASK-260922-1ye74o_review-verdict.md) — Independent fable review verdict: changes_requested, findings array + surface table + notes

## Created
2026-09-22T18:00:47Z

## Last Update
2026-09-22T19:28:48Z

## Assigned To
[reviewer] reviewer (claude)
