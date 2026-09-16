# Runner Control

Native macOS menu-bar app for installed GitHub Actions runners on the current Mac.

- Click the lightning icon in the menu bar for individual or combined start/stop controls.
- Stopping CI requires confirmation because it can interrupt a build.
- Opening or quitting the app does not start or stop CI automatically. Quitting with an active service shows a reminder.
- Double-clicking the application again also opens a control window.
- Opening the app preserves each service’s existing login startup policy. Existing `.command` controls remain compatible.
- Displayed state comes from local launchd, not GitHub's delayed online/busy status.
- Each enabled runner can execute a job; multiple registrations may run concurrently.
- Missing registrations, invalid service manifests, command failures and paths with spaces are rejected and surfaced.

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

At launch, the app discovers `manual-service.plist` files in immediate subdirectories of `~/Library/GitHubActions` and standard `actions.runner.*.plist` files in `~/Library/LaunchAgents`. It reads the registration name and GitHub scope from `.runner`, uses the actual service label/path, and deduplicates registrations. Discovery does not execute scripts, alter services or register runners. Arbitrary folder selection and GitHub sign-in are planned, not implemented. The app does not store a GitHub token or modify repository workflows.

## Releases and automatic updates

The app uses Sparkle 2.10.0. Its menu offers manual update checks and separate automatic checking/download settings. Updating the app does not stop independently running CI services.

After the first successful release, the latest DMG is available at:
https://github.com/relux-works/runner-control/releases/latest/download/RunnerControl.dmg

The signed update archive is announced at:
https://github.com/relux-works/runner-control/releases/latest/download/appcast.xml

See [RELEASING.md](RELEASING.md) for host setup and release steps. Apple signing and notarization credentials are configured on macbook-iv. Download links become available after the first successful release workflow.
