# TASK-260916-2vzsmy: validate-and-publish-release — validation evidence

Leaf validated the repaired release automation after the CI fix checkpoint.
No production script required a change: every gate held under narrowing attack.
Gaps closed were test coverage (23 → 51 tests) and exact-requirements documentation.
No tag created, nothing published.

## Changes (uncommitted in story worktree)

- `RELEASING.md`: new "Exact requirements reference" table (11 rows: identity,
  tag, build formula, notary, Sparkle pin + checksum, appcast invariants,
  generator commit, host tools, publish order), each with its enforcing script.
- `Scripts/tests/test_release_metadata.py`: +10 tests (short-tag vs marketing,
  run/attempt bounds both directions, pubkey length/base64, bundle mismatch,
  shortVersion, item count, signature, enclosure/minimum, malformed-XML ParseError).
- `Scripts/tests/test_release_preflight.py`: +3 tests (same-team Apple Development
  refused, missing tool via isolated PATH, unknown notary error reporting).
- `Scripts/tests/test_release_packaging.py`: harness knobs (tag, run/attempt,
  NOTARY_STATUS, CODESIGN_TEAM, APPCAST_TAMPER) + 7 E2E tests (tag mismatch,
  run 0, boundary 9899/99 accept, notary Rejected, wrong codesign team, appcast
  tamper, malformed identity hash that passes preflight but must fail DMG signing).
- `Scripts/tests/test_release_docs.py` (new): 5 tests deriving expectations from
  code (Sparkle pin/checksum, team/profile/account, toolchain pins, docs↔code
  bound tie in both directions, no secret material in docs).
- `Scripts/tests/test_release_workflow.py` (new): 3 tests on `release.yml`
  (gate→package→publish order, only log step overrides success gating,
  strict tag-trust block).

## AC coverage: 6 of 6 rows driven

| # | AC row | Named committed test(s) | Production call site |
|---|---|---|---|
| 1 | Release scripts validated | test_release_signs_dmg_with_resolved_team_identity, test_tag_marketing_mismatch_prevents_packaging, test_notarization_rejection_prevents_publish, test_appcast_tamper_prevents_publish, (+4 more packaging) | `Scripts/release.sh` end to end |
| 2 | Preflight validated | test_preflight_passes_with_valid_credentials + 10 refusal tests | `Scripts/release-preflight.sh` |
| 3 | Validated and documented | 5 ReleaseDocsTests (code-derived expectations) | `RELEASING.md` vs `Scripts/*`, `release.yml` |
| 4 | Metadata tests pass | full `Scripts/tests` suite, 51 green, exit 0 | `python3 -m unittest discover -s Scripts/tests` |
| 5 | Candidate ready for review and integration | handoff mechanics: tree uncommitted, suite green, this artifact attached | `task-board handoff --role developer` |
| 6 | Subsequent tag uses repaired workflow; nothing published yet | 3 ReleaseWorkflowTests + `git tag` shows no v1.2.0 | `.github/workflows/release.yml` |

## Validation commands (exit codes observed)

- `python3 -m unittest discover -s Scripts/tests` → exit 0, 51 tests OK (20.9s)
- `bash -n` on release.sh, release-preflight.sh, sparkle-tools.sh → exit 0
- `python3 -m py_compile` on release_metadata.py + tests → exit 0
- `git tag -l 'v*'` → only pre-existing `v1.1.0`; no v1.2.0 created
- Docs tests were observed RED before the RELEASING.md update (2 failures +
  1 error) and green after — authentic failure, not a vacuous pass.

## Narrowing mutants: 11 of 11 killed, 0 survivors

Each mutant weakens a gate to admit exactly one member of its reject class
(no delete-only mutants). Restored from backup copies with diff verification.

| Mutant | Narrowed gate | Named failing test | Module result |
|---|---|---|---|
| M1b | tag regex admits short `v1.2` | test_rejects_short_tag_even_when_marketing_matches | failures=1 (only named) |
| M2 | run bound 9899 → 99999 | test_rejects_invalid_run_attempt_bounds | failures=1 |
| M3 | resolver drops Developer-ID requirement | test_rejects_same_team_apple_development | failures=1 |
| M4 | appcast admits shortVersion 9.9.9 | test_rejects_short_version_mismatch | failures=1 |
| M5 | appcast admits length off-by-one | test_appcast_archive_binding | failures=1 |
| M6 | preflight grep drops Developer-ID requirement | test_apple_development_same_team_rejected | failures=1 |
| M7 | codesign check admits any team | test_codesign_team_mismatch_prevents_packaging | failures=1 |
| M8 | notarize admits `Rejected` | test_notarization_rejection_prevents_publish | failures=1 |
| M9 | signing token kept, fallback SHA on resolver failure | test_malformed_identity_hash_prevents_signing; static wiring test still PASS (token preserved) | failures=1 |
| M10 | publish step gains `if: always()` | test_only_log_preservation_overrides_success_gating | failures=1 |
| M11 | docs claim run 1..99999 | test_documented_run_attempt_bounds_match_code | errors=1 |

M9 is the token-preserving attack: the behavioral packaging suite (not only the
static wiring checker) kills it. Earlier M1 variant also rejected valid 3-part
tags, so it was replaced by pure-narrowing M1b; both killed, M1b reported.

## Stated bounds (unknown, not inferred)

- B1 malformed appcast XML raises `ET.ParseError`, not `ValueError`; production
  still fails closed (nonzero exit under `set -euo pipefail`).
- B2 missing config keys raise `KeyError` (fails closed); refusal shape untested.
- B3 identity hash match is uppercase 40-hex only (platform output format);
  lowercase behavior untested.
- B4 Sparkle download+checksum path untested (no network in tests); harnesses
  exercise only the pre-created-tools short-circuit.
- B5 real Apple notarization/staple/`spctl` untested (stubs); first accepted
  Apple submission still pending per RELEASING.md.
- B6 Swift core suite and full tuist/xcode build not run (no Swift/project
  changes in this leaf; out of scope).
- B7 suite run locally only; CI run happens after integration.
- B8 no linter configured in repo; shellcheck/ruff unavailable — `bash -n` +
  `py_compile` only.
- B9 publish commands never executed by design (no tag/publish in this leaf).

## Findings

- Preflight previously had no test pinning the Developer-ID (vs any same-team
  identity) requirement; the M6-shaped weakening survived the old suite. Fixed
  with test_apple_development_same_team_rejected.
- `verify_appcast` shortVersion clause previously had no dedicated refusal case.
  Fixed with test_rejects_short_version_mismatch.
- No defects found in production scripts; all refusals fail closed with actionable
  messages naming the profile/tag/bound involved.
