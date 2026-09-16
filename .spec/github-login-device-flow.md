# GitHub login — Device Flow

## Goal

Connect GitHub without manual PAT. Public `client_id` only in the app; no
client secret, App private key, or token in binary, resources, state, or logs.

## Config

- Source: `Info.plist[GitHubAppClientID]` via `ios-app-manager.json →
  macos.info_plist.GitHubAppClientID` (coordinator-provisioned).
- Missing/empty → `GitHubAuth.Action.failed` with exact binding
  `Info.plist[GitHubAppClientID] (scaffold input ios-app-manager.json →
  macos.info_plist.GitHubAppClientID, coordinator-provisioned public
  client_id)`. Local control unaffected.
- Enterprise host uses `https://<host>/login/...` and `https://<host>/api/v3`;
  requires its own App registration. Until configured, show concrete limit.

## Endpoints

- `POST {server}/login/device/code` `{client_id}` → `device_code`,
  `user_code`, `verification_uri`, `expires_in`, `interval`.
- `POST {server}/login/oauth/access_token`
  `{client_id, device_code, grant_type: urn:ietf:params:oauth:grant-type:device_code}`
  polled at `interval`; `slow_down` adds 5s. HTTP 200 with `error` body is not
  success: `authorization_pending` / `slow_down` / `access_denied` /
  `expired_token`.
- Refresh: `POST {server}/login/oauth/access_token`
  `{client_id, grant_type: refresh_token, refresh_token}` — no client secret.
- `GET {api}/user`, `GET {api}/user/installations`,
  `GET {api}/user/installations/{id}/repositories` with
  `Accept: application/vnd.github+json`, `Authorization: Bearer ghu_…`.

## States

`disconnected → requestingCode → awaitingUser → verifyingAccount →
verifyingInstallations → connected`. Terminal failures: `denied`,
`codeExpired` (new code), `cancelled` (device_code destroyed, poll stopped),
`network` (retry), `needsInstallation`/`needsApproval` (grant access), `sso`,
`revoked`/`unauthorized` (relogin), `rateLimited` (stale + local works).

## Storage

- Keychain service `works.relux.runnercontrol.github-token`, account
  `<serverHost>:<userID>:<clientID>`, JSON `{accessToken, refreshToken?,
  expiresAt?}`. Atomic save; `deleteAll` sweeps by prefix/suffix.
- Relux state holds username, IDs, hosts, timestamps only. `device_code`,
  access/refresh tokens live in Flow actor privates + Keychain.
- `GitHubRedaction.sanitize` scrubs exact secrets plus
  `"access_token"/"refresh_token"/"device_code"` JSON shapes.

## Refresh

`GitHubTokenRefresh.refresh` is an actor: concurrent callers with the same
`current` coalesce to one HTTP refresh (second caller sees the new store
value and returns without network). Missing refresh token →
`tokenRefreshFailed`; `invalid_grant` → `revoked`.

## Guards

- `PATGuard` rejects `ghp_*` / `github_pat_*` with `patNotSupported`. No PAT
  UI exists; injected PATs fail closed.
- `RESTMapper`: 401 → `unauthorized`; 403 inspects body for SSO/rate-limit,
  else `forbidden`; 429 → `rateLimited`. Login-phase 401/revoked → relogin;
  connected-phase 403/offline/rate-limit → `syncFailed` (stale, local works).
- `AppConfig.auditNoSecrets` rejects plist keys containing `secret`,
  `private_key`/`privatekey`, `token` (except `GitHubAppClientID`).

## Session restore

- `GitHubAuth.Effect.restoreSession` runs once at startup (`AppRegistry`).
  It loads non-secret identity (`serverHost`, `userID`, `clientID`,
  `username`) from UserDefaults, loads the Keychain record, validates via
  `GET /user`, then loads installations (+ first-installation repositories).
- 401/revoked/`invalid_grant` clears Keychain + identity and requires
  relogin. Exception: a 401 with an unrefreshed expiring token (refresh
  failed transiently) blames the expired access token, keeps storage, and
  reports stale so a later tick can retry. Offline/403 keeps the restored
  session with a stale `syncFailed` marker; logout stays available and
  deletes both stores.
- Identity holds no tokens. `logout` also clears persisted stores when the
  in-memory session is already gone, so relaunch can never orphan tokens.

## Lifecycle boundary

- `beginLogin`/`cancelLogin`/`logout` bump the Flow `generation` and cancel
  the poll plus the in-flight token refresh. `restoreSession`,
  `restoreInstallations`, `refreshInstallations`, `selectInstallation`,
  and `currentToken` capture the generation at entry and stop silently
  after every `await` once superseded: no state emission, no
  session/identity restore, no token saves.
- A cancelled refresh surfaces `CancellationError` and never writes the
  refreshed record (pre-save check plus compare-and-delete for a
  cancel that lands mid-save). Revoked sessions surface relogin from
  both refresh and select paths.
