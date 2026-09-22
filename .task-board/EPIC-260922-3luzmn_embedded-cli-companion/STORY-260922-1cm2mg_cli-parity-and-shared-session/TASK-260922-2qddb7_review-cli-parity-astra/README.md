# TASK-260922-2qddb7: review-cli-parity-astra

## Description
Independent review of the embedded CLI work against the goal in .task-board/specs/embedded-cli-companion/proposal.md. Scope: uncommitted diff vs fb85df5 (Packages/RunnerControlCLI, CLIInstallerService, Core diffs, GUI Install-CLI wiring, Scripts). Judge 1:1 GUI parity (effect coverage), shared-session correctness and Keychain safety, JSON/exit-code contract stability for harnesses, installer lease, signing/notarization path. Guardrails: never sign out (no auth logout), never register/unregister/touch runners, never delete keychain items or plist keys, never commit; tests and dev builds are allowed. Record the verdict (accept / accept-with-findings / reject with reasons) in task notes and the checklist.

## Scope
(define task scope)

## Acceptance Criteria
Verdict recorded in notes with reasons; every checklist item checked with file:line evidence or an explicit unresolved note.
