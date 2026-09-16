# Offline and degraded GitHub

## Invariants

- Local `Runners` inspect/start/stop never depends on GitHub reachability,
  401/403, rate limits, or token state.
- `LocalState`, `RemoteState`, `OperationState`, observation time stay
  separate. Offline never renders a running service as stopped; missing
  registration never hides a running service or its Stop.
- Contradictions show both facts (e.g. "Служба выключена · GitHub: данные
  обновляются").

## Mapping

- Offline/transport error → `AuthError.network`, `syncFailed`, stale label +
  last-success time + retry. Poll loop fails with `.retry`, not infinite.
- 401/`invalid_grant`/missing token → `unauthorized`/`revoked` → relogin.
  Connected-phase 401 fails the sync, not local runners.
- 403 → body-inspected: SSO → `ssoRequired`; rate-limit text →
  `rateLimited`; else `forbidden` (grant/approve). All keep local enabled.
- 429 → `rateLimited` with backoff; menu poll ~30s, local poll 3s menu /
  slower background, immediate after command and wake.

## Freshness

- Older than 60s → explicit "данные устарели". Stale `busy=false` is not
  idle proof. Stop of a running service always confirms; unknown/stale busy
  warns "may interrupt a job".
