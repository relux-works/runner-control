# TASK-260916-13diw4: register-mac-and-repository-access

## Description
Implement new-runner wizard through GitHub API: architecture-matched official download with integrity verification, no-space install/work directories, scoped short-lived registration token, exact config invocation, runsvc.sh setup, manual LaunchAgent, idempotent retries and recovery. Organization registration uses a dedicated per-Mac group and selected repo access; personal repos get separate installations. Allow editing repository access and labels. Fetch real IDs and retain permissions errors. Do not mutate unrelated/shared groups without explicit UI scope. Use production services with controlled filesystem/transport tests. Repo is public relux-works/runner-control; bundle works.relux.runnercontrol, team 262RZ595FP. Read precondition design and current source. Use /Users/iv/Documents/Codex/2026-09-15/new-chat-4/work/skills/skill-ios-app-manager/SKILL.md, work/skills/skill-swift-relux/SKILL.md and work/skills/skill-ios-testing-tools/agents/skills/ios-testing-tools/SKILL.md under that same workspace. No UI tests. Keep Relux actor services, state/reducer/flow, Container+Page. Modify generator input, never hand-edit generated Project.swift or Package.swift. Do not stop, re-register or interrupt any existing production runner. Do not commit producer changes; hand off candidate through task-board. No new delegates without coordinator direction.

## Scope
(define task scope)

## Acceptance Criteria
Wizard can register this Mac for org or repo without terminal; selected repositories are applied and can be changed; failed/repeated operations avoid orphan/duplicate registrations; no secret leakage; tests exercise actual entry points.
