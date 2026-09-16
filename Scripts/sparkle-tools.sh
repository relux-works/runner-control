#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version=2.10.0
checksum=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
tools="$root/.temp/tools/Sparkle-$version"
mkdir -p "$tools"
if [ ! -x "$tools/bin/generate_appcast" ]; then
  archive="$root/.temp/tools/Sparkle-$version.tar.xz"
  curl --fail --location --silent --show-error "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$archive"
  printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check --status
  tar -xf "$archive" -C "$tools"
fi
printf '%s\n' "$tools/bin"
