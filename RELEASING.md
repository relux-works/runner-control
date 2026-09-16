# Release operations

## One-time setup on macbook-iv

The release workflow uses this Mac's manually controlled runner. Enable it in Runner Control before releasing; a disabled runner leaves the workflow queued. Pull requests run unit tests on GitHub-hosted macOS and do not use release credentials.

Required tools: Xcode, Tuist 4.9.0, GitHub CLI, Python 3. The workflow installs Go 1.25.5 and builds the scaffold generator at a pinned revision. Sparkle tools are downloaded at a pinned version and verified by SHA-256.

The runner's login Keychain needs:

- A Developer ID Application certificate **and matching private key** for team `262RZ595FP`. Apple Development and certificates belonging to other teams are rejected.
- A validated notarytool profile named `RunnerControl-notary`.
- The existing Sparkle Ed25519 signing key under account `works.relux.runnercontrol`. Keep a secure backup; losing it prevents updates to installed releases. Do not regenerate it for each release.

An Apple Account Holder must issue the Developer ID certificate from the supplied CSR. Import the issued certificate together with its matching private key. Use `xcrun notarytool store-credentials` locally with a valid App Store Connect API key, key ID and issuer ID; it validates authorization before saving the profile. Never commit keys, certificates with private keys, or credentials.

Run `./Scripts/release-preflight.sh` from any directory to verify these prerequisites. Keychain access must work from the runner session without an unattended authorization prompt.

## Publish

1. Set `marketing_version` in `ios-app-manager.json` to the intended version and regenerate with the pinned macOS app generator.
2. Commit to `main` and wait for the Tests workflow.
3. Tag that commit `vMAJOR.MINOR.PATCH` and push the tag. Alternatively run **Release DMG** with that existing tag.
4. The workflow tests, archives, exports with Developer ID, notarizes/staples the app and DMG, generates the Sparkle signature, and checks feed metadata.
5. Only after those checks does it create a draft release, upload `RunnerControl.dmg`, `appcast.xml` and `SHA256SUMS`, then publish it as latest. Assets remain in GitHub Releases without the artifact retention deadline.

Each feed points to its immutable version-specific DMG URL. The application follows the latest release's appcast. Published release assets are never overwritten by the workflow. If uploading fails after draft creation, inspect the draft and remove the incomplete draft before retrying the same run. Diagnostic logs are retained for 14 days.

Build numbers are derived from the release workflow run number and attempt. Keep this workflow's run counter continuous; do not replace it with a new workflow whose counter starts over without adjusting the build-number scheme.

## Validation status

Core and release metadata tests pass locally; the Sparkle-enabled app builds successfully. The complete notarization and update-install cycle requires the first accepted Apple submission and two published versions. No notarized public release has been published yet.
