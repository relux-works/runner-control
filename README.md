# Runner Control

Native macOS menu-bar app for the two registered GitHub Actions runners on this Mac.

- Click the lightning icon in the menu bar for individual or combined start/stop controls.
- Stopping CI requires confirmation because it can interrupt a build.
- Opening or quitting the app does not start or stop CI automatically. Quitting with an active service shows a reminder.
- Double-clicking the application again also opens a control window.
- Neither runner starts automatically at login. Existing `.command` controls remain compatible.
- Displayed state comes from local launchd, not GitHub's delayed online/busy status.
- Two enabled runners can execute two jobs concurrently.
- Missing registrations, invalid service manifests, command failures and paths with spaces are rejected and surfaced.

## Identity

Bundle ID: `works.relux.runnercontrol`  
Development team: `262RZ595FP` (Relux Works)  
Platform: macOS 14+, Apple Silicon build supplied.  
Signed with Apple Development for this Mac; not a notarized public distribution.

## Build

Requires Xcode, Tuist and the configured development team in Xcode.

```sh
./Scripts/build.sh
```

The result is `.temp/products/RunnerControl.app`. If changing the scaffold configuration, run `ios-app-manager generate macos-app --config ios-app-manager.json` before building. Native generator source: https://github.com/relux-works/skill-ios-app-manager.

## Tests

```sh
swift test --package-path Packages/RunnerControlCore
RUN_LAUNCH_AGENT_INTEGRATION=1 swift test --package-path Packages/RunnerControlCore
```

The integration option starts and stops only a unique temporary sleep service, never a production GitHub runner. Tests cover reducers, flow errors, idempotency, missing/permission states, path validation, output handling and real launchd lifecycle. No UI tests are included.

For logs and JUnit output use `Scripts/run-macos-package-tests.sh` from https://github.com/relux-works/skill-ios-testing-tools with `--package Packages/RunnerControlCore --output .temp/macos-tests`.

## Architecture

The app owns a single Relux runtime in `AppRegistry`; reopening a popover cannot recreate it. UI containers map state to plain page props/reactions. Core owns a HybridState, reducer, actor flow and actor launchd adapter. Process output is file-backed to avoid pipe deadlocks, commands have a timeout, and subprocess arguments are passed without a shell.

The runner service files remain in `~/Library/GitHubActions/macbook-iv` and `~/Library/GitHubActions/cocoaskills`. The app does not store a GitHub token or modify repository workflows.
