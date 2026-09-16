# TASK-260916-304bw2: catalog-lifecycle-and-polished-ui

## Description
Complete universal persistent catalog, existing manual and standard LaunchAgent discovery/import, user-selected folders and dedup, no-space validation. Implement local/remote/operation states, truthful busy/stale/offline UI, individual/bulk start and confirmed stop, log access, independent app/runner login preferences, and explicit unregister operation distinct from removing catalog entry. Preserve imported service policies and existing runners. Integrate full UI and bump to 1.2.0 suitable build. Run core tests and native macOS build. No SSH fleet controls or fake stop-after-job. Repo is public relux-works/runner-control; bundle works.relux.runnercontrol, team 262RZ595FP. Read precondition design and current source. Use /Users/iv/Documents/Codex/2026-09-15/new-chat-4/work/skills/skill-ios-app-manager/SKILL.md, work/skills/skill-swift-relux/SKILL.md and work/skills/skill-ios-testing-tools/agents/skills/ios-testing-tools/SKILL.md under that same workspace. No UI tests. Keep Relux actor services, state/reducer/flow, Container+Page. Modify generator input, never hand-edit generated Project.swift or Package.swift. Do not stop, re-register or interrupt any existing production runner. Do not commit producer changes; hand off candidate through task-board. No new delegates without coordinator direction.

## Scope
(define task scope)

## Acceptance Criteria
All approved flows integrated; imported production installs unaffected; no duplicate process; stop works for known service despite missing .runner; local controls work offline; tests pass and native app builds.
