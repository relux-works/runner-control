#!/bin/bash
set -euo pipefail
for tool in xcodebuild xcrun codesign security hdiutil tuist gh python3; do
  command -v "$tool" >/dev/null || { echo "Missing release tool: $tool" >&2; exit 1; }
done
if ! security find-identity -v -p codesigning | grep -E 'Developer ID Application:.*\(262RZ595FP\)' >/dev/null; then
  echo 'Missing Developer ID Application identity with private key for team 262RZ595FP.' >&2
  echo 'An Account Holder must issue it; Apple Development or another team cannot be substituted.' >&2
  exit 1
fi
xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-RunnerControl-notary}" --output-format json >/dev/null
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
sparkle_bin="$("$root/Scripts/sparkle-tools.sh")"
actual="$("$sparkle_bin/generate_keys" --account works.relux.runnercontrol -p)"
expected="$(python3 -c 'import json; print(json.load(open("ios-app-manager.json"))["macos"]["info_plist"]["SUPublicEDKey"])')"
[ "$actual" = "$expected" ] || { echo 'Sparkle signing key is missing or does not match the app public key.' >&2; exit 1; }
