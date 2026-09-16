# TASK-260916-97dhxd: github-login-and-management-window

## Description
Implement the first runnable vertical slice: native management window, GitHub App Device Flow login/logout with Keychain and serialized token refresh, installation/account listing and repository selection. Local control remains usable offline. Never embed client secrets, App private keys, or tokens in state/logs. Public client ID will be provisioned by coordinator; model app config cleanly, report exact missing binding. Add focused transport and Keychain tests. Materialize approved design into .spec with registration and removal now in scope. Repo is public relux-works/runner-control; bundle works.relux.runnercontrol, team 262RZ595FP. Read precondition design and current source. Use /Users/iv/Documents/Codex/2026-09-15/new-chat-4/work/skills/skill-ios-app-manager/SKILL.md, work/skills/skill-swift-relux/SKILL.md and work/skills/skill-ios-testing-tools/agents/skills/ios-testing-tools/SKILL.md under that same workspace. No UI tests. Keep Relux actor services, state/reducer/flow, Container+Page. Modify generator input, never hand-edit generated Project.swift or Package.swift. Do not stop, re-register or interrupt any existing production runner. Do not commit producer changes; hand off candidate through task-board. No new delegates without coordinator direction.

## Scope
(define task scope)

## Acceptance Criteria
App builds; real login flow UI drives production services; cancellation, slow_down, expired code, refresh concurrency, logout and 401/403 are covered; no PAT fallback; existing menu remains functional.
