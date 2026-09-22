#!/bin/bash
# Build the runner-control CLI (universal), Apple-sign it, and print the
# binary path. Used by build.sh (dev) and release.sh (release). Never
# publishes anything.
#
# The signature is load-bearing, not cosmetic: only Apple-signed binaries
# read the shared Keychain session silently. Ad-hoc fallback builds run,
# but raise a Keychain prompt on first foreign-item access.
#
# Env: CLI_MODE=dev|release (default dev), CLI_SCRATCH=dir,
# CLI_IDENTITY (default: resolved Apple Development, else ad-hoc).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mode="${CLI_MODE:-dev}"
scratch="${CLI_SCRATCH:-$root/.temp/cli-dist}"
mkdir -p "$scratch"
swift build --package-path Packages/RunnerControlCLI -c release \
  --arch arm64 --arch x86_64 --scratch-path "$scratch" \
  --product runner-control > "$root/.temp/cli-build.log" 2>&1 || {
  cat "$root/.temp/cli-build.log" >&2; exit 1;
}
bin="$(find "$scratch" -path '*/Products/Release/runner-control' -type f -print 2>/dev/null | head -n 1)"
if [ -z "$bin" ]; then echo "CLI product not found under $scratch" >&2; exit 1; fi
identity="${CLI_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity="$("$root/Scripts/resolve-identity.sh" dev | cut -d' ' -f1)"
fi
if [ -z "$identity" ]; then
  echo "warning: no Apple Development identity; ad-hoc CLI will prompt for Keychain access" >&2
  codesign --force --sign - "$bin"
else
  opts=(--force --timestamp --sign "$identity")
  if [ "$mode" = "release" ]; then opts+=(--options runtime); fi
  codesign "${opts[@]}" "$bin"
fi
codesign --verify --strict "$bin"
printf '%s\n' "$bin"
