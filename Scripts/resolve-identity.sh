#!/bin/bash
# Resolve a codesigning identity + team for local (dev) builds.
# Prints "<sha> <team>" (e.g. "7FB8... 45W9YW7M6V"), or nothing when no
# Apple Development identity exists. Preference: product team first.
# Usage: resolve-identity.sh dev
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
team_id="$(python3 -c 'import json;print(json.load(open("'"$root"'/ios-app-manager.json"))["team_id"])' 2>/dev/null || echo 262RZ595FP)"
line="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | grep "($team_id)" | head -n 1)"
if [ -z "$line" ]; then
  line="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | head -n 1)"
fi
if [ -z "$line" ]; then exit 0; fi
sha="$(printf '%s' "$line" | sed -E 's/^ *[^ ]+ +([0-9A-F]{40}).*/\1/')"
team="$(printf '%s' "$line" | sed -E 's/.*\(([0-9A-Z]+)\).*/\1/')"
if [[ "$sha" =~ ^[0-9A-F]{40}$ && "$team" =~ ^[0-9A-Z]+$ ]]; then
  printf '%s %s\n' "$sha" "$team"
fi
