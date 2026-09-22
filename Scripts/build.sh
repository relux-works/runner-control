#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# Regenerate scaffold after config changes with ios-app-manager generate macos-app.
tuist generate --no-open
xcodebuild -workspace RunnerControl.xcworkspace -scheme RunnerControl \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .temp/DerivedData -allowProvisioningUpdates \
  CONFIGURATION_BUILD_DIR="$root/.temp/products" \
  CODE_SIGN_IDENTITY='Apple Development' DEVELOPMENT_TEAM=262RZ595FP build
# One identity for the app re-seal and the CLI so both stay Apple-signed.
app_identity="$("$root/Scripts/resolve-identity.sh" dev | cut -d' ' -f1)"
if [ -n "$app_identity" ]; then
  cli_bin="$(CLI_MODE=dev CLI_IDENTITY="$app_identity" "$root/Scripts/build-cli.sh")"
else
  echo "warning: no Apple Development identity; ad-hoc dev build prompts for Keychain access" >&2
  cli_bin="$(CLI_MODE=dev "$root/Scripts/build-cli.sh")"
fi
mkdir -p .temp/products/RunnerControl.app/Contents/Helpers
cp "$cli_bin" .temp/products/RunnerControl.app/Contents/Helpers/runner-control
# Re-seal: embedding the CLI invalidated the Xcode seal.
if [ -n "$app_identity" ]; then
  codesign --force --timestamp --sign "$app_identity" \
    .temp/products/RunnerControl.app
fi
codesign --verify --deep --strict .temp/products/RunnerControl.app
