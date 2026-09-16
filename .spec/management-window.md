# Management window

## Goal

Native 760×540 "Раннеры и настройки" window alongside the existing ~400pt menu.
Menu stays fully functional; window adds GitHub + settings depth.

## Entry

- Reopen app (`applicationShouldHandleReopen`) and menu button "Раннеры и
  настройки…" open the window via `Notification openManagementWindow`
  (no new app delegate).
- First launch shows the window once (`hasShownWelcome`).

## Tabs

- **Раннеры**: Mac name + `N из M включено`, `RunnerCard` list in scroll,
  per-row errors, "Включить все" / "Выключить все…", offline note. Reuses
  `Runners.State` and `RunnerCard`; no GitHub-gated controls.
- **GitHub**: disconnected (server field + "Войти через GitHub" + Keychain
  note), requesting/verifying (progress), awaitingUser (large code +
  Copy/Open/Cancel + expiry/interval), connected (`@user`, host, last sync,
  Refresh/Logout/Revoke, installations picker, repo checklist, grant-access),
  failed (message + retry per `RetryKind` + offline note). Drives production
  `GitHubAuth.Effect` via `ManagementWindowContainer`.
- **Основные**: launch-at-login (`SMAppService.mainApp`, distinct from CI),
  version + Sparkle check/auto toggles, quit (warns if CI running, never
  stops CI).

## Rules

- Container maps state → props/reactions; Page is pure. Local `@State`
  only for server-host text and tab selection.
- GitHub failures never disable local toggles. Stale data is labeled with
  last-sync time; `busy=false` older than 60s is not proof of idle.
- Stop always confirms; per-row `changing` blocks only that row.
