#!/bin/bash
# Build, notarize and package. Never publishes a failed/unnotarized build.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
: "${RELEASE_TAG:?Set RELEASE_TAG to an existing vMAJOR.MINOR.PATCH tag}"
: "${GITHUB_RUN_NUMBER:?Use the GitHub release workflow for monotonic build numbers}"
: "${GITHUB_RUN_ATTEMPT:?Missing workflow run attempt}"
: "${IOS_APP_MANAGER:?Set IOS_APP_MANAGER to the pinned generator binary}"
./Scripts/release-preflight.sh
build="$(python3 Scripts/release_metadata.py prepare --config ios-app-manager.json --tag "$RELEASE_TAG" --run "$GITHUB_RUN_NUMBER" --attempt "$GITHUB_RUN_ATTEMPT")"
"$IOS_APP_MANAGER" generate macos-app --config ios-app-manager.json
tuist generate --no-open
release_root="$root/.temp/release-$build"
mkdir -p "$release_root/dist" "$release_root/image"
archive="$release_root/RunnerControl.xcarchive"
xcodebuild -workspace RunnerControl.xcworkspace -scheme RunnerControl -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$archive" \
  -derivedDataPath "$release_root/DerivedData" \
  CONFIGURATION_BUILD_DIR="$release_root/products" \
  CODE_SIGN_IDENTITY='Developer ID Application' DEVELOPMENT_TEAM=262RZ595FP \
  CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS='--timestamp' archive > "$release_root/archive.log" 2>&1
cat > "$release_root/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>262RZ595FP</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$release_root/export" \
  -exportOptionsPlist "$release_root/ExportOptions.plist" > "$release_root/export.log" 2>&1
app="$release_root/export/RunnerControl.app"
signing_identity="$(security find-identity -v -p codesigning | python3 Scripts/release_metadata.py signing-identity --team 262RZ595FP)"
cli_bin="$(CLI_MODE=release CLI_SCRATCH="$release_root/cli-build" CLI_IDENTITY="$signing_identity" "$root/Scripts/build-cli.sh")"
mkdir -p "$app/Contents/Helpers"
cp "$cli_bin" "$app/Contents/Helpers/runner-control"
# Re-seal before notarization sees it (embedding the CLI broke the seal).
codesign --force --timestamp --options runtime --sign "$signing_identity" "$app"
codesign --verify --deep --strict "$app"
metadata="$(codesign -dvv "$app" 2>&1)"
grep -q 'TeamIdentifier=262RZ595FP' <<< "$metadata"
grep -q 'Authority=Developer ID Application:' <<< "$metadata"
notarize() {
  local artifact="$1" result="$2"
  xcrun notarytool submit "$artifact" --keychain-profile "${NOTARY_PROFILE:-RunnerControl-notary}" \
    --wait --timeout 30m --output-format json > "$result"
  python3 - "$result" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
if r.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept this submission: ' + str(r))
PY
}
ditto -c -k --keepParent "$app" "$release_root/RunnerControl.zip"
notarize "$release_root/RunnerControl.zip" "$release_root/app-notary.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose "$app"
ditto "$app" "$release_root/image/RunnerControl.app"
ln -s /Applications "$release_root/image/Applications"
hdiutil create -volname 'Runner Control' -srcfolder "$release_root/image" -fs APFS \
  -format ULFO "$release_root/dist/RunnerControl.dmg"
codesign --force --timestamp --sign "$signing_identity" "$release_root/dist/RunnerControl.dmg"
notarize "$release_root/dist/RunnerControl.dmg" "$release_root/dmg-notary.json"
xcrun stapler staple "$release_root/dist/RunnerControl.dmg"
xcrun stapler validate "$release_root/dist/RunnerControl.dmg"
sparkle_bin="$(./Scripts/sparkle-tools.sh)"
"$sparkle_bin/generate_appcast" --account works.relux.runnercontrol \
  --maximum-versions 1 --maximum-deltas 0 \
  --download-url-prefix "https://github.com/relux-works/runner-control/releases/download/$RELEASE_TAG/" \
  --link 'https://github.com/relux-works/runner-control' "$release_root/dist"
python3 Scripts/release_metadata.py verify --appcast "$release_root/dist/appcast.xml" \
  --dmg "$release_root/dist/RunnerControl.dmg" --tag "$RELEASE_TAG" --build "$build"
(cd "$release_root/dist" && shasum -a 256 RunnerControl.dmg appcast.xml > SHA256SUMS)
if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'dist=%s\n' "$release_root/dist" >> "$GITHUB_OUTPUT"; fi
printf 'Notarized release assets: %s\n' "$release_root/dist"
