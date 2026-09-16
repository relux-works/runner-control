#!/bin/bash
# Validate that RELEASE_TAG is a trusted release tag before any release work.
# Production entry point invoked by .github/workflows/release.yml ("Validate
# trusted release tag"). Refuses malformed tags, HEAD/tag mismatch, non-main
# ancestry, existing releases, and unknown lookup failures (fail closed).
set -euo pipefail
: "${RELEASE_TAG:?Set RELEASE_TAG to an existing vMAJOR.MINOR.PATCH tag}"
if ! [[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Refusing untrusted release tag '$RELEASE_TAG': must be vMAJOR.MINOR.PATCH." >&2
  exit 1
fi
head_commit="$(git rev-parse HEAD)"
tag_commit="$(git rev-parse "$RELEASE_TAG^{commit}")"
if [ "$head_commit" != "$tag_commit" ]; then
  echo "Refusing tag $RELEASE_TAG: HEAD ($head_commit) does not match tag commit ($tag_commit)." >&2
  exit 1
fi
if ! git merge-base --is-ancestor HEAD origin/main; then
  echo "Refusing tag $RELEASE_TAG: HEAD is not on origin/main ancestry." >&2
  exit 1
fi
gh_err="$(mktemp)"
if gh release view "$RELEASE_TAG" >/dev/null 2>"$gh_err"; then
  echo 'Release already exists. Inspect it before retrying; no published assets are overwritten.' >&2
  rm -f "$gh_err"
  exit 1
fi
gh_text="$(cat "$gh_err" 2>/dev/null || true)"
rm -f "$gh_err"
if printf '%s\n' "$gh_text" | grep -qi 'release not found'; then
  printf 'Trusted release tag %s verified (HEAD matches, on origin/main, no existing release).\n' "$RELEASE_TAG"
  exit 0
fi
echo "Could not verify release absence for $RELEASE_TAG; refusing to proceed." >&2
if [ -n "$gh_text" ]; then
  printf '%s\n' "$gh_text" >&2
fi
exit 1
