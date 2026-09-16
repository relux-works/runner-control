# TASK-260916-2vzsmy rev2: F1/F2 rework — validation evidence

Rework of review rev1 (`changes_requested`, `repeat-of: none`). F1 behavioral
trust-gate regression added; F2 notarization/submission docs corrected per
`release-operational-context.md` clarification. No tag created, nothing
published, no runner interruption, no secrets.

## Changes (uncommitted in story worktree, branch snapshot for handoff)

Production:
- `Scripts/validate-release-tag.sh` (new, executable): trusted-tag gate
  extracted from `release.yml`. Rejects malformed tags, HEAD/tag mismatch,
  non-main ancestry, existing releases; treats unknown `gh release view`
  failures as unknown (fail closed) and only `release not found` as confirmed
  absence. Success prints `Trusted release tag <tag> verified`.
- `.github/workflows/release.yml`: `Validate trusted release tag` step now runs
  `./Scripts/validate-release-tag.sh` (9 inline lines replaced by 1 call).
  Gate order, publish gating, toolchain pins unchanged.

Tests:
- `Scripts/tests/test_release_workflow.py`: 3 static tests replaced by 3 wiring
  tests + 8 behavioral tests executing the production script with stubbed
  git/gh (11 total). Wiring test proves the workflow invokes the production
  script and the script contains all trust tokens.
- `Scripts/tests/test_release_docs.py`: +1 test
  `test_docs_state_notarization_gates_and_diagnostic_handling` tying
  per-artifact `Accepted` + staple gates to `release.sh` and requiring the
  diagnostic ID, no-duplicate instruction, read-only inspection, and v1.2.0
  boundary in docs.
- Prior rev1 tests unchanged: metadata, packaging, preflight still 49 tests.

Docs:
- `RELEASING.md`: tag row now names `validate-release-tag.sh` + unknown-lookup
  refusal; notary row names per-artifact `Accepted` + `stapler staple/validate`;
  recovery section states diagnostic submission
  `6d537548-8c24-48ea-89b5-7ebb2dc959d5` (`In Progress` at 02:49 UTC), no
  duplicate test submission, diagnostic is NOT a release prerequisite, new app
  ZIP + DMG each need their own `Accepted` + staple verification, read-only
  `notarytool info` path, v1.2.0 boundary preserved.

## AC coverage: 5 of 6 rows driven, 1 procedural bound

AC: "Release scripts and preflight are validated and documented, metadata
tests pass, candidate ready for review and integration so the subsequent
release tag uses the repaired workflow."

| # | AC row | Named committed test(s) | Production call site |
|---|---|---|---|
| 1 | Release scripts validated | test_release_signs_dmg_with_resolved_team_identity, test_tag_marketing_mismatch_prevents_packaging, test_notarization_rejection_prevents_publish, test_appcast_tamper_prevents_publish (+7 more packaging) | `Scripts/release.sh` end to end |
| 2 | Preflight validated | test_preflight_passes_with_valid_credentials + 11 refusal tests | `Scripts/release-preflight.sh` |
| 3 | Validated and documented | 6 ReleaseDocsTests incl. test_docs_state_notarization_gates_and_diagnostic_handling | `RELEASING.md` vs `Scripts/*`, `release.yml`, `release.sh` |
| 4 | Metadata tests pass | full `Scripts/tests` suite, 60 green, exit 0 | `python3 -m unittest discover -s Scripts/tests` |
| 5 | Candidate ready for review and integration | PROCEDURAL BOUND, not a committed test: tree uncommitted (`git status`), suite green, this artifact attached, handoff mechanics | `task-board handoff --role developer` |
| 6 | Subsequent tag uses repaired workflow; nothing published yet | test_workflow_invokes_trust_script_before_any_work + 8 ReleaseTagTrustBehaviorTests (accept trusted, refuse malformed/HEAD-mismatch/non-main/existing/unknown-gh) + `git tag -l` shows only v1.1.0 | `Scripts/validate-release-tag.sh` via `.github/workflows/release.yml` |

Row 6 is now behavioral (review rev1 found it static-only). Row 5 stays
procedural as the reviewer noted; it is verified by commands below, not prose.

## Validation commands (real exit codes observed)

- `python3 -m unittest discover -s Scripts/tests` → exit 0, 60 tests OK (29.1s)
- `python3 -m unittest Scripts.tests.test_release_workflow -v` → exit 0, 11 OK
- `python3 -m unittest Scripts.tests.test_release_docs -v` → exit 0, 6 OK
- `bash -n` on validate-release-tag.sh, release.sh, release-preflight.sh, sparkle-tools.sh → exit 0 each
- `python3 -m py_compile` on release_metadata.py + all 5 test modules → exit 0
- `git tag -l 'v*'` → only pre-existing `v1.1.0`; no v1.2.0 created (exit 0)
- `git status --short` → 5 modified + 3 untracked, nothing committed (exit 0)
- F1 pre-fix reproduction (`/tmp/f1-repro.sh`) → static check passed mutant,
  original block exit 1 vs mutant exit 0 (authentic bypass confirmed)
- Docs F2 check fails on pre-fix text (no diagnostic ID) and passes after

## Narrowing mutants: 6 of 6 killed in this rework, 0 survivors

Each mutant keeps the gate present and weakens it to admit exactly one member
of its reject class. M12/M13/M16 preserve the searched-for tokens so the
static wiring checker still passes; the behavioral suite kills them. Harness
`/tmp/f1f2-mutants-v2.py` runs the full workflow/docs module per mutant (not
only the static checker) and verifies byte-identical restore via `diff`.
Full log: `TASK-260916-2vzsmy_mutants-rev2.log`. Prior M1–M11 (rev1) reused
bound to unchanged source/test/config/env identity; M10 rechecked after the
workflow edit (killed, failures=1).

| Mutant | Narrowed gate (admits exactly) | Named failing test(s) | Module result |
|---|---|---|---|
| M12 | ancestry `if ! ... && false` (token `merge-base --is-ancestor` kept; `if !` analogue of reviewer's bare-command `\|\| true` bypass): admits non-main ancestry | test_non_main_ancestry_refused | failures=1, wiring still ok, trusted still ok |
| M13 | tag regex `...$|^v[0-9]+\\.[0-9]+$` (original token kept as substring): admits short `v1.2` | test_malformed_tags_refused_before_any_git_work | failures=1, wiring still ok |
| M14 | HEAD check `&& false`: admits HEAD/tag mismatch | test_head_tag_mismatch_refused | failures=1 |
| M15 | existing-release branch `exit 1`→`exit 0`: admits existing release | test_existing_release_refused | failures=1 |
| M16 | absence matcher `grep ... 'release not found' \|\| true` (token kept): admits unknown/empty gh failures as absent | test_gh_lookup_failure_fails_closed_not_absent + test_gh_empty_error_fails_closed | failures=2 (same unknown-failure class), wiring still ok |
| M17 | docs `Do not duplicate`→`Duplicate ... if convenient`: drops F2 instruction | test_docs_state_notarization_gates_and_diagnostic_handling | failures=1 (docs module) |
| M10 recheck | publish step gains `if: always()` | test_only_log_preservation_overrides_success_gating | failures=1 |

No survivors in this rework. A wrong-shape M12 variant (`|| true` inside
`if !`, which always refuses instead of admitting) was rejected during
development because it narrows the wrong direction; the reported M12 is the
pure admit-one-member bypass.

## Stated bounds (unknown, not inferred)

- B1–B9 from rev1 unchanged (malformed-XML ParseError, KeyError on missing
  config keys, uppercase-only identity hash, Sparkle download path, real Apple
  notarization/staple/spctl, Swift suite not run, local-only run, no linter
  configured, publish never executed).
- B10 `gh release view` absence marker is case-insensitive `release not found`
  (observed live: `gh release view <missing> --repo cli/cli` → `release not
  found`, exit 1; unknown repo → `Could not resolve...`, exit 1). If GitHub
  changes the message, the script fails closed (refuses valid absent case);
  stubs encode the current message.
- B11 ancestry check assumes `origin/main` exists (workflow uses
  `fetch-depth: 0`); behavior with missing remote ref untested.
- B12 `git rev-parse` hard failures exit nonzero via `set -e` (fail closed);
  message shape untested.
- B13 real push-tag and workflow_dispatch paths not executed (no tag/publish
  in this leaf by design).
- B14 diagnostic submission ID/state is an operational fact from
  `release-operational-context.md`, not code-derived; docs test pins the
  literal ID.

## Findings

- F1 confirmed pre-fix: token-preserving `|| true` survived all 51 rev1 tests
  while production behavior flipped 1→0. Fixed by extraction + 8 behavioral
  tests; M12 now proves the behavioral suite kills what the static checker
  misses.
- F1 also fixed a latent fail-open: original `if gh release view ...` treated
  any `gh` failure as absence. New script distinguishes confirmed absence
  (`release not found`) from unknown failures (fail closed with original
  stderr preserved). Covered by two negative tests + M16.
- F2 fixed per clarification: diagnostic ZIP is not a prerequisite, but each
  final artifact needs its own `Accepted` + staple verification; new-artifact
  submission is authorized and is not duplication. Pinned by docs test + M17.
- No production runner interruption, no Apple submission, no network download
  in tests, no secret material in docs (secret-scan test green).
