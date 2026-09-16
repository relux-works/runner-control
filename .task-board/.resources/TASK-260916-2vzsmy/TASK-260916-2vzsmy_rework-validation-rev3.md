# TASK-260916-2vzsmy rev3: workflow call-site regression — validation evidence

Rework of review rev2 (`changes_requested`, `repeat-of: rev1 F1`). Single
remaining finding F1: composed workflow call-site bypass untested. Adds named
regression that extracts the actual `Validate trusted release tag` run field
from `release.yml` and executes it under Actions-equivalent
`bash -e -o pipefail`; kills the exact caller mutant
`./Scripts/validate-release-tag.sh || true`. Docs F2 already resolved in rev2;
prior script gates already accepted. No production change in this rev, no tag,
no publication, no notary submission, no runner interruption, no secrets.

## Changes (uncommitted in story worktree)

Tests only, one file:

- `Scripts/tests/test_release_workflow.py`: +2 composed-step tests and one
  extractor helper (62 total, was 60).
  - `trust_run_command()`: reads the production workflow file at test time
    and returns the actual `Validate trusted release tag` run field verbatim.
    Supports inline and block-scalar `run:` forms. No hardcoded command, so a
    call-site mutant changes what the tests execute.
  - `ReleaseWorkflowComposedStepTests.test_workflow_trust_step_refuses_non_main_ancestry`:
    regression for rev2 F1. Reuses existing `GIT_STUB`/`GH_STUB` fixtures,
    sets `ANCESTRY_EXIT=1`, executes the extracted run field via
    `bash -e -o pipefail -c <run>` with cwd at a fixture root containing
    `Scripts/validate-release-tag.sh`, and requires nonzero exit plus the
    ancestry refusal on stderr. Fails (exit 0) under the `|| true` mutant.
  - `ReleaseWorkflowComposedStepTests.test_workflow_trust_step_accepts_trusted_tag`:
    same composed path with trusted inputs; requires exit 0 and the
    `Trusted release tag v1.2.0 verified` stdout. Proves the regression is
    not a test that always fails.

Production unchanged in rev3: `Scripts/validate-release-tag.sh` and
`.github/workflows/release.yml` are byte-identical to the rev2 candidate.
`RELEASING.md` untouched (F2 stays resolved).

## AC coverage: 5 of 6 rows driven, 1 procedural bound

AC: "Release scripts and preflight are validated and documented, metadata
tests pass, candidate ready for review and integration so the subsequent
release tag uses the repaired workflow."

| # | AC row | Named committed test(s) | Production call site |
|---|---|---|---|
| 1 | Release scripts validated | test_release_signs_dmg_with_resolved_team_identity, test_tag_marketing_mismatch_prevents_packaging, test_notarization_rejection_prevents_publish, test_appcast_tamper_prevents_publish (+7 more packaging) | `Scripts/release.sh` end to end |
| 2 | Preflight validated | test_preflight_passes_with_valid_credentials + 11 refusal tests | `Scripts/release-preflight.sh` |
| 3 | Validated and documented | 6 ReleaseDocsTests incl. test_docs_state_notarization_gates_and_diagnostic_handling | `RELEASING.md` vs `Scripts/*`, `release.yml`, `release.sh` |
| 4 | Metadata tests pass | full `Scripts/tests` suite, 62 green, exit 0 | `python3 -m unittest discover -s Scripts/tests` |
| 5 | Candidate ready for review and integration | PROCEDURAL BOUND, not a committed test: tree uncommitted (`git status`), suite green, this artifact attached, handoff mechanics | `task-board handoff --role developer` |
| 6 | Subsequent tag uses repaired workflow; nothing published yet | test_workflow_invokes_trust_script_before_any_work + 8 ReleaseTagTrustBehaviorTests + 2 ReleaseWorkflowComposedStepTests (composed run-field accept + refuse) + `git tag -l` shows only v1.1.0 | `.github/workflows/release.yml` Validate trusted release tag run field via `bash -e -o pipefail -c` + `Scripts/validate-release-tag.sh` |

Row 6 was 4-of-6 per rev2 review (caller blind spot). The two composed-step
tests close that spot: row 6 is now behavioral at the caller as well as the
script. Row 5 stays procedural by nature.

## Validation commands (real exit codes observed)

- `python3 -m unittest discover -s Scripts/tests -v` → exit 0, 62 tests OK (24.0s). Full log: `TASK-260916-2vzsmy_suite-rev3.log`.
- `python3 -m unittest Scripts.tests.test_release_workflow -v` → exit 0, 13 OK (2.3s).
- `python3 -m unittest Scripts.tests.test_release_workflow.ReleaseWorkflowComposedStepTests -v` → exit 0, 2 OK.
- `python3 /tmp/rev3-mutant-harness.py` (M18, see below) → exit 0, `MUTANT_KILLED=True`, `HARNESS_OK=True`, restored byte-identical True. Full log: `TASK-260916-2vzsmy_mutants-rev3.log`.
- `bash -n` on validate-release-tag.sh, release.sh, release-preflight.sh, sparkle-tools.sh → exit 0 each.
- `python3 -m py_compile` on release_metadata.py + all 5 test modules → exit 0.
- `git tag -l 'v*'` → only pre-existing `v1.1.0`; no v1.2.0 created (exit 0).
- `git status --short` → 5 modified + 3 untracked, nothing committed (exit 0).
- Extraction probe: original run → `'./Scripts/validate-release-tag.sh'`; mutant text → `'./Scripts/validate-release-tag.sh || true'` (exit 0).
- Lint: no linter configured (no Makefile, pyproject, ruff/eslint/flake8 config in repo root); syntax gates above are the validation. Swift suite not run (Python-only test change; see B6).

## Narrowing mutants: 1 of 1 killed in this rework, 0 survivors

Harness `/tmp/rev3-mutant-harness.py` mutates the real workflow file in place,
runs the full workflow module per mutant (not only the static checker), then
restores byte-identical content. The mutant preserves the searched-for token
so the static wiring checker still passes; only the composed behavioral test
kills it. Full log: `TASK-260916-2vzsmy_mutants-rev3.log`. Prior M12–M17
(rev2) accepted with production gates unchanged and their killing tests
unchanged; not rerun in this focused rev per the rev3 brief.

| Mutant | Narrowed gate (admits exactly) | Named failing test(s) | Module result |
|---|---|---|---|
| M18 (rev2 F1 exact) | workflow trust call `run: ./Scripts/validate-release-tag.sh \|\| true` (token `validate-release-tag.sh` kept; refusal exit 1 masked to 0): admits non-main ancestry at the caller | test_workflow_trust_step_refuses_non_main_ancestry | failures=1 (only the regression); trusted-path composed test still ok; static wiring still ok |

No survivors in this rework. No `repeat-of` survivor bound to state.

## Stated bounds (unknown, not inferred)

- B1–B14 from rev2 unchanged (malformed-XML ParseError, KeyError on missing
  config keys, uppercase-only identity hash, Sparkle download path, real Apple
  notarization/staple/spctl, Swift suite not run, local-only run, no linter
  configured, publish never executed, gh absence marker, origin/main assumed,
  rev-parse hard-fail shape, push/dispatch paths not executed, diagnostic ID
  operational fact).
- B15 Composed harness runs `bash -e -o pipefail -c <run>` (bash 3.2.57 on
  macOS) with stubbed git/gh, not a full Actions runner. The trust step has
  no `${{ }}` expressions, so expression substitution is unexercised by
  construction.
- B16 Extractor supports inline and block-scalar `run:` forms; YAML
  anchors/aliases or multi-step composition beyond the single trust step are
  untested.

## Findings

- Rev2 F1 reproduced as specified before the fix by construction: the static
  test asserts a substring and the behavioral tests invoke the script
  directly, so neither executes the composed `run:` string. After the fix,
  M18 fails exactly one test (the new refusal regression) while trusted and
  static checks still pass, proving the gate is narrowing at the caller.
- No forced fit encountered. Fixture reuse required making the tmp
  `Scripts/validate-release-tag.sh` copy explicitly executable (the composed
  `./Scripts/...` invocation needs +x; direct `bash <script>` did not).
- Candidate left uncommitted for handoff snapshot; no Story branch commit.
