# RunnerControl specs

Materialized from approved-design.md for STORY-260916-36d1jg. Registration and
removal are in scope for this release (promoted from "next stage" in §2).

- `github-login-device-flow.md` — GitHub App Device Flow, Keychain, refresh, installations/repos.
- `management-window.md` — native 760×540 window, tabs, menu coexistence.
- `runner-registration.md` — new-runner wizard (implements TASK-260916-13diw4 contract).
- `runner-removal.md` — remove-from-app vs delete-from-GitHub boundary.
- `offline-local-control.md` — offline/401/403/rate-limit behavior.

Conventions: Relux actor services, state/reducer/flow, Container+Page. No UI
tests. Generator input (`ios-app-manager.json`) owns scaffold output; never
hand-edit `Project.swift`/`Package.swift`.
