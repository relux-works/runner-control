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
codesign --verify --deep --strict .temp/products/RunnerControl.app
