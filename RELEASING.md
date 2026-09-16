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

## Exact requirements reference

Every value below is enforced by the named script and covered by `Scripts/tests`. If a value changes, update the script, this section, and the tests together.

| Requirement | Exact value | Enforced by |
|---|---|---|
| Signing identity | Exactly one `Developer ID Application` certificate with private key for team `262RZ595FP`; Apple Development and other teams are refused | `release-preflight.sh`, `release_metadata.py signing-identity`, `release.sh` DMG signing |
| Bundle and team | `works.relux.runnercontrol` / `262RZ595FP` | `release_metadata.py prepare` |
| Release tag | `vMAJOR.MINOR.PATCH`, equal to `marketing_version`, on `main` ancestry at `HEAD`; an existing release refuses the run; unknown `gh` lookup failures refuse instead of passing as absent | `validate-release-tag.sh` (invoked by `release.yml`), `prepare` |
| Build number | `project_version` = `(100 + run).attempt` with run 1..9899 and attempt 1..99 (for example run 1 attempt 1 → `101.1`) | `release_metadata.py prepare` |
| Notary profile | `RunnerControl-notary` in the runner's login keychain, unlocked in the runner session; `notarytool` waits up to 30 minutes per artifact (app ZIP, then DMG), each needs its own `Accepted` plus `stapler staple`/`validate` before publication | `release-preflight.sh`, `release.sh` notarize |
| Sparkle account and feed | Account `works.relux.runnercontrol`; private key must match `SUPublicEDKey`; feed `https://github.com/relux-works/runner-control/releases/latest/download/appcast.xml` | `release-preflight.sh`, `prepare` |
| Sparkle tools | Version `2.10.0`, SHA-256 `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c` | `sparkle-tools.sh` |
| Appcast | Exactly one item; `sparkle:version` = build, `shortVersionString` = marketing version, enclosure URL `https://github.com/relux-works/runner-control/releases/download/<tag>/RunnerControl.dmg`, 64-byte `edSignature`, `length` = DMG bytes, minimum macOS 14 | `release_metadata.py verify` |
| Scaffold generator | `skill-ios-app-manager` at `755a29538dfe0867671ac4291b016bf42d93a299`, built with Go `1.25.5` | `release.yml` |
| Host tools | Xcode, Tuist 4.9.0, GitHub CLI, Python 3, plus `xcodebuild xcrun codesign security hdiutil tuist gh python3` on `PATH` | `release-preflight.sh` |
| Publish order | Preflight → unit tests → package/notarize/verify → draft → upload DMG + appcast + SHA256SUMS → publish as latest; the publish step runs only after a successful package and never overwrites published assets | `release.yml`, `release.sh` |

## Failure recovery

Release run 35040921163 (`v1.1.0`) failed in Release prerequisites before any
build or signing: the login keychain was locked in the runner session, so
`notarytool` could not read profile `RunnerControl-notary` (`keychainLocked`).
No draft or published release was created.

Per coordinator directive, `v1.1.0` is neither retried nor deleted: the tag
stays as-is with no release, and the approved next release is new `v1.2.0`
after product integration. No new tag is created and nothing is published
until product review and coordinator dispatch.

If a future run reports a locked keychain in Release prerequisites, unlock
the login keychain on macbook-iv with a console login as the runner user (no
credentials are printed or exported), enable the runner in Runner Control,
then run **Release DMG** via workflow_dispatch with the existing tag. Do not
delete or re-push the tag and do not create the release by hand; the workflow
refuses to overwrite published assets. If prerequisites still report a locked
keychain, the runner session has no unlocked login keychain; unlock it and
dispatch again.

Preflight also fails fast when no Developer ID Application identity for team
`262RZ595FP` is present, when several are present (remove the stale
certificate so signing is unambiguous), when the notarytool profile is missing
(recreate it with `xcrun notarytool store-credentials` as above), when the
Sparkle private key does not match `SUPublicEDKey`, or when signing
identities cannot be read at all (a failed read is reported as unknown,
never as missing or verified).

Apple notarization waits up to 30 minutes per artifact (app ZIP, then DMG).
Each artifact must receive its own `Accepted` result and pass `stapler staple`
plus `stapler validate` before final publication; `release.sh` enforces this
and only `Accepted` proceeds for each submission. If a wait times out, the
submission ID in the release logs can be inspected read-only with
`xcrun notarytool info <id> --keychain-profile RunnerControl-notary` (status
only); retrying dispatches a new run with a new monotonic build number.

Diagnostic signing-check submission `6d537548-8c24-48ea-89b5-7ebb2dc959d5`
was `In Progress` at 02:49 UTC. Do not duplicate that test submission and do
not treat it as a release prerequisite: it is not a release artifact and its
state does not gate the next release. Inspect it read-only only if needed
(`xcrun notarytool info 6d537548-8c24-48ea-89b5-7ebb2dc959d5
--keychain-profile RunnerControl-notary`, status only). Submitting the
genuinely new release app ZIP and DMG for `v1.2.0` is authorized and is not
duplication; each must still reach its own `Accepted` and pass staple
verification before the draft is published.

## Validation status

Core and release metadata tests pass locally and in GitHub Actions; the Sparkle-enabled app builds successfully. Developer ID signing and the notarytool profile are validated on macbook-iv. The complete notarization and update-install cycle requires the first accepted Apple submission and two published versions. Check GitHub Releases for publication status.
