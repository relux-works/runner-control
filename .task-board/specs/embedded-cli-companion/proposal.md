# Embedded `runner-control` CLI — proposal

Goal (user statement): embed a special CLI in the macOS app (installed like
other macOS apps do) giving a CLI interface to every parameter and
configuration the GUI app manages — 1:1 parity — including sharing the
authentication session, so all functions can run from an AI agent harness.

Non-goals:

- Installing app updates from the CLI (read-only `check-updates`; installs
  stay with Sparkle/GUI — deliberate design decision).
- Interactive UI state (selections, drafts) beyond its persisted/user-goal
  equivalent (flags, two-step flows, re-run-as-retry).

Constraints:

- JSON output + stable exit codes (0/1/2/3) for harnesses. Parse errors are
  usage(1) with ArgumentParser's brief message; run-phase failures are
  failed(2); needs-login is 3. `--json` always yields exactly one envelope
  doc; help/version keep native handling (exit 0).
- No SecurityAgent interaction in normal operation: Apple-signed, same-team
  Keychain sharing; ad-hoc is a loud fallback, never quiet default.
- Same Relux runtime/effects as the GUI (parity by construction).
- Installer lease (flock) for PATH symlink install; GUI "Install CLI" button
  + `app install-cli` self-install share one service. Lease acquisition
  failures fail closed (never unserialized mutations).
- launch-at-login drives the GUI's own SMAppService registration through a
  shared-defaults + distributed-notification bridge (a bare tool cannot use
  SMAppService.mainApp; System Events would diverge + prompt). CLI status is
  last-known with an explicit pending flag.
