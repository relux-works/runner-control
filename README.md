# Runner Control

Native macOS menu-bar app for your GitHub Actions runners on the current Mac.
Works for any organization, repository, Mac name and install path — nothing
is hardcoded. Local start/stop works offline without GitHub sign-in.

- Click the lightning icon for per-runner Enable / Disable… buttons, bulk
  Enable all / Disable all…, Add runner… and Runners and settings….
- Stopping always confirms. When GitHub reports busy you choose Leave on or
  Interrupt and disable. When busy is unknown, stale or disconnected the
  dialog says so plainly. Stopping can interrupt a build; quitting the app
  never stops CI.
- Opening or quitting the app does not start or stop CI. Importing an
  existing service preserves its login-startup policy and never re-registers.
- Double-clicking the app also opens the Runners and settings window.
- Displayed power state comes from local launchd. GitHub online/busy/labels
  are a separate signature with explicit stale/offline labels.
- Each enabled runner can execute a job; multiple registrations may run
  concurrently. Re-clicking never creates a duplicate process.
- Missing registrations never hide a running service or its Stop. Invalid
  manifests block Start. Paths with spaces require relocation — running
  runners are never moved automatically.

## Getting started

1. Install the app and open it. On first launch your existing installs in
   `~/Library/GitHubActions` and `~/Library/LaunchAgents` (`actions.runner.*`)
   are imported read-only into the local catalog.
2. To add another install: Runners and settings → Runners → Find on Mac or
   Choose folder…. Pick Add. Import never changes the existing service.
3. Optional GitHub login: Settings → GitHub → Sign in with GitHub. Approve the
   device code in your system browser. Then install the Runner Control GitHub
   App on the accounts or repositories you choose, or request owner approval.
4. To create a new runner: Create runner… in the Runners tab. The wizard
   downloads the official package, verifies SHA-256, installs to a no-space
   path, registers with a short-lived token and writes a manual service with
   login start off. Enabling stays your separate action.
5. Removing: Remove from app deletes only the catalog entry. Unregister from
   GitHub is an explicit separate operation with typed confirmation. Neither
   deletes your files silently.
6. Repository access (organization runners, after any restart): Runners and
   settings → select the org runner → Repository access → Load current
   access. The group comes from fresh GitHub membership (local `.runner`
   pool fields can lag server-side moves), matched by agent ID, never by
   name. Tick repositories and Apply. Groups this Mac owns apply directly
   with an explicit scope confirmation; shared or imported groups require an
   explicit take-over step first and are never edited silently. Repository
   runners use separate per-repository installs instead of groups.

## GitHub permissions

Sign-in uses a GitHub App with Device Flow. The app binary holds only the
public `client_id`; tokens live in Keychain and never in logs or exports.

- Reading runner state needs Self-hosted runners/read (organization) or
  Administration/read (repository). Reading job details needs extra rights
  and stays off unless you grant it.
- Registering needs Self-hosted runners/write (organization) or
  Administration/write (repository) plus matching user rights.
- Organization access also needs the App installed on that organization.
  Without it the app shows the concrete grant-access step instead of an
  empty list.

## Identity

Bundle ID: `works.relux.runnercontrol`  
Development team: `262RZ595FP` (Relux Works)  
Platform: macOS 14+, universal Apple Silicon + Intel build supplied.  
Local builds use Apple Development. Public releases require Developer ID Application and Apple notarization.

## Build

Requires Xcode, Tuist and the configured development team in Xcode.

```sh
./Scripts/build.sh
```

The result is `.temp/products/RunnerControl.app`. If changing the scaffold configuration, edit `ios-app-manager.json` and run `ios-app-manager generate macos-app --config ios-app-manager.json` before building. Never hand-edit generated `Project.swift` or `Package.swift`. Native generator source: https://github.com/relux-works/skill-ios-app-manager.

## Tests

```sh
swift test --package-path Packages/RunnerControlCore
RUN_LAUNCH_AGENT_INTEGRATION=1 swift test --package-path Packages/RunnerControlCore
```

The integration option starts and stops only a unique temporary sleep service, never a production GitHub runner. Tests cover reducers, flow errors, idempotency, catalog dedupe and validation, local/remote separation, unregister identity binding, missing/permission states, path validation, output handling and real launchd lifecycle. No UI tests are included.

For logs and JUnit output use `Scripts/run-macos-package-tests.sh` from https://github.com/relux-works/skill-ios-testing-tools with `--package Packages/RunnerControlCore --output .temp/macos-tests`.

## Architecture

The app owns a single Relux runtime in `AppRegistry`; reopening a popover cannot recreate it. UI containers map state to plain page props/reactions. Core owns HybridState, reducers, actor flows and actor launchd/installer adapters. Process output is file-backed to avoid pipe deadlocks, commands have a timeout, and subprocess arguments are passed without a shell.

At launch, the app migrates discovered installs into a versioned catalog in
`Application Support/RunnerControl/catalog.json` (identity, canonical paths,
display names, controller kinds, preferences; no secrets), then keeps local
power state, GitHub observations and operation locks separate. Discovery reads
`manual-service.plist` files in `~/Library/GitHubActions`, standard
`actions.runner.*.plist` files in `~/Library/LaunchAgents` and folders you
choose. It reads the registration name, server, scope and agent ID from
`.runner`, uses the actual service label/path, deduplicates by canonical
directory (symlink spellings collapse), and never executes scripts, alters
services, reads `.credentials` or registers runners. Installer mutations
(download, config, service setup, recovery, unregister) share one app-wide
exclusive lease; ordinary start/stop never takes it.

## Releases and automatic updates

The app uses Sparkle 2.10.0. Settings offers manual update checks and separate automatic checking/download settings. Updating the app does not stop independently running CI services.

After the first successful release, the latest DMG is available at:
https://github.com/relux-works/runner-control/releases/latest/download/RunnerControl.dmg

The signed update archive is announced at:
https://github.com/relux-works/runner-control/releases/latest/download/appcast.xml

See [RELEASING.md](RELEASING.md) for host setup and release steps.
