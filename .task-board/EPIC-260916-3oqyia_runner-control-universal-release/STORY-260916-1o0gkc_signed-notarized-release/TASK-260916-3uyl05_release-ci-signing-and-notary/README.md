# TASK-260916-3uyl05: release-ci-signing-and-notary

## Description
Investigate failed release run 35040921163 and fix release CI for new version. Current signed identity 267D90FC976A48CF830BE7F41AE612999E025054; notarization Keychain profile RunnerControl-notary; Sparkle private signing key remains in Keychain account works.relux.runnercontrol. Existing notary submission 6d537548-8c24-48ea-89b5-7ebb2dc959d5 was pending, inspect status safely. Credentials never printed/exported. Preserve hardened runtime signing, ZIP and DMG notarization+stapling, signed appcast and assets before publish. Work only release workflow/scripts/docs; do not tag/publish until product review and coordinator dispatch. Read RELEASING.md. Repo is public relux-works/runner-control; bundle works.relux.runnercontrol, team 262RZ595FP. Read precondition design and current source. Use /Users/iv/Documents/Codex/2026-09-15/new-chat-4/work/skills/skill-ios-app-manager/SKILL.md, work/skills/skill-swift-relux/SKILL.md and work/skills/skill-ios-testing-tools/agents/skills/ios-testing-tools/SKILL.md under that same workspace. No UI tests. Keep Relux actor services, state/reducer/flow, Container+Page. Modify generator input, never hand-edit generated Project.swift or Package.swift. Do not stop, re-register or interrupt any existing production runner. Do not commit producer changes; hand off candidate through task-board. No new delegates without coordinator direction.

## Scope
(define task scope)

## Acceptance Criteria
Release pipeline failure diagnosed and repaired; metadata tests/preflight pass; evidence identifies remaining external waits accurately; no public release published prematurely.
