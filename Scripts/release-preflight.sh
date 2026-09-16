#!/bin/bash
set -euo pipefail
for tool in xcodebuild xcrun codesign security hdiutil tuist gh python3; do
  command -v "$tool" >/dev/null || { echo "Missing release tool: $tool" >&2; exit 1; }
done
identity_out="$(mktemp)"
identity_err="$(mktemp)"
if ! security find-identity -v -p codesigning >"$identity_out" 2>"$identity_err"; then
  echo 'Could not read signing identities; the result is unknown, not missing.' >&2
  head -n 5 "$identity_err" >&2 || true
  rm -f "$identity_out" "$identity_err"
  exit 1
fi
identities="$(grep -E 'Developer ID Application:.*\(262RZ595FP\)' "$identity_out" || true)"
rm -f "$identity_out" "$identity_err"
if [ -z "$identities" ]; then
  echo 'Missing Developer ID Application identity with private key for team 262RZ595FP.' >&2
  echo 'An Account Holder must issue it; Apple Development or another team cannot be substituted.' >&2
  exit 1
fi
if [ "$(printf '%s\n' "$identities" | grep -c .)" -gt 1 ]; then
  echo 'Multiple Developer ID Application identities for team 262RZ595FP; remove the stale certificate so release signing is unambiguous.' >&2
  exit 1
fi
profile="${NOTARY_PROFILE:-RunnerControl-notary}"
history_err="$(mktemp)"
if ! xcrun notarytool history --keychain-profile "$profile" --output-format json >/dev/null 2>"$history_err"; then
  if grep -q 'keychainLocked' "$history_err"; then
    echo "The login keychain is locked in this session, so notarytool profile '$profile' cannot be read." >&2
    echo 'Unlock the login keychain on macbook-iv (console login as the runner user) and re-run Release DMG via workflow_dispatch with the existing tag. Credentials are never printed or exported.' >&2
  elif grep -q 'No Keychain password item found for profile' "$history_err"; then
    echo "notarytool profile '$profile' is missing from the login keychain." >&2
    echo "Recreate it locally with 'xcrun notarytool store-credentials' (see RELEASING.md), then re-run Release DMG via workflow_dispatch with the existing tag." >&2
  else
    echo "notarytool history failed for profile '$profile':" >&2
    head -n 5 "$history_err" >&2 || true
  fi
  rm -f "$history_err"
  exit 1
fi
rm -f "$history_err"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
sparkle_bin="$("$root/Scripts/sparkle-tools.sh")"
actual="$("$sparkle_bin/generate_keys" --account works.relux.runnercontrol -p)"
expected="$(python3 -c 'import json; print(json.load(open("ios-app-manager.json"))["macos"]["info_plist"]["SUPublicEDKey"])')"
[ "$actual" = "$expected" ] || { echo 'Sparkle signing key is missing or does not match the app public key.' >&2; exit 1; }
printf "Release prerequisites verified (team 262RZ595FP, notary profile '%s').\n" "$profile"
