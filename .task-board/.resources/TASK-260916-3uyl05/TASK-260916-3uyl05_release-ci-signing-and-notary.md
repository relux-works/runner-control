# TASK-260916-3uyl05: release-ci-signing-and-notary — outcome

## 1. Diagnosis of release run 35040921163

`gh run view 35040921163 --log-failed` (repo `relux-works/runner-control`,
tag `v1.1.0`, run_number 1, attempt 1) failed in step **Release prerequisites**
after ~2s, before any build, signing, or notarization:

```
Error: keychainLocked(keychainName: "default", keychainURL: nil) Use Keychain
Access or the `security unlock-keychain` command line tool to unlock the
default keychain.
```

Root cause: the login keychain was **locked in the runner session** when
`Scripts/release-preflight.sh` ran `xcrun notarytool history --keychain-profile
RunnerControl-notary`. The old preflight had `set -e` with no error mapping, so
the raw Swift error was the whole diagnosis, and the earlier
`security find-identity` presence check passes while locked (certificates are
readable; secrets are not), hiding the real state. No draft or published
release was created (`gh release list` empty at handoff).

Ruled out (all verified, no change needed):
- Workflow file sound: trusted-tag validation, pinned actions, `gh release
  create --verify-tag` (means "abort if the tag does not exist remotely", not
  signature verification — lightweight tag `v1.1.0` is acceptable), 90-minute
  job budget fits two 30-minute notary waits plus build.
- Pinned scaffold generator commit `755a295` exists upstream.
- Credentials valid in an unlocked session: expected Developer ID identity
  `267D90FC…E025054` (team `262RZ595FP`) present; notarytool history returns
  100 entries; Sparkle public key matches `SUPublicEDKey`.
- Pending submission `6d537548-8c24-48ea-89b5-7ebb2dc959d5`
  (`RunnerControlSigningCheck.zip`) is a signing check, still `In Progress` at
  handoff — an external Apple-queue wait, not a release artifact and not a
  blocker (the release submits its own ZIP/DMG).

## 2. Repair (uncommitted candidate, release workflow/scripts/docs only)

- `Scripts/release-preflight.sh`: captures `notarytool history` stderr and maps
  `keychainLocked` → unlock-keychain + `workflow_dispatch` retry guidance,
  `No Keychain password item found for profile` → `store-credentials` recovery,
  anything else → bounded raw error; fails fast on zero or multiple
  `262RZ595FP` Developer ID identities; prints a success line naming team and
  profile (no secrets). Production entry point for all preflight gates.
- `Scripts/release_metadata.py`: new `resolve_signing_identity()` +
  `signing-identity --team` subcommand — returns the single team SHA-1,
  rejects zero/multiple matches and ignores Apple Development and other-team
  identities (replaces a sed pipeline that silently returned empty or
  first-match).
- `Scripts/release.sh:61`: DMG signing now resolves via
  `release_metadata.py signing-identity --team 262RZ595FP` (fails loudly under
  `pipefail` instead of `codesign --sign ""`).
- `RELEASING.md`: new "Failure recovery" section (run 35040921163 cause,
  unlock + `workflow_dispatch` retry, no tag deletion/re-push, 30m/artifact
  latency bound, no tag/publish until product review and coordinator dispatch).
- No workflow, tag, release, runner, `Project.swift`, app-code, or version-bump
  changes. `marketing_version` 1.1.1 already on main; nothing tagged/published.

## 3. Verification (real exit codes)

| Command | Result |
|---|---|
| `python3 -m unittest discover -s Scripts/tests -v` | 16/16 pass, exit 0 |
| `./Scripts/release-preflight.sh` (unlocked session) | exit 0, prerequisites verified |
| `swift test --package-path Packages/RunnerControlCore` | 12/12 pass, exit 0 |
| `release_metadata.py prepare --tag v1.1.1 --run 2 --attempt 1` (temp copy) | `102.1`, exit 0, repo config untouched |
| `security find-identity … \| release_metadata.py signing-identity --team 262RZ595FP` | `267D90FC…E025054`, exit 0 |
| `bash -n` (preflight, release), `py_compile` (py files) | all OK |
| `gh release list` / `git tag` | no releases; only pre-existing `v1.1.0` |
| `git status` | candidate uncommitted (5 modified + 1 new test) |

No repo-configured linter exists (no Makefile/CI lint/shellcheck); syntax
checks above are the lint evidence.

## 4. Mutants (6 narrowing, 0 survivors)

| Mutant | What it narrows the gate to | Named failing test |
|---|---|---|
| M1 preflight `keychainLocked`→`keychainlocked` | locked branch must match Apple's exact token; falls through to generic | `test_locked_keychain_fails_with_unlock_guidance` (exit 1) |
| M2 `resolve_signing_identity` team filter dropped | team scoping; admits other-team Developer ID | `test_rejects_missing_team_identity` (FAIL) + `test_returns_team_identity_ignoring_other_teams` (ERROR) |
| M3 `len(matches) > 1`→`> 2` | exactly-one rule; admits exactly-2 case | `test_rejects_multiple_team_identities` (exit 1) |
| M4 `release.sh` signing-identity line commented (**token preserved**) | wiring: call present vs removed | `test_release_signs_dmg_with_resolved_team_identity` (exit 1) |
| M5 preflight `-gt 1`→`-gt 2` | preflight count gate; admits exactly-2 | `test_multiple_team_identities_rejected` (exit 1) |
| M6 missing-profile pattern broken | profile-branch specificity; falls through to generic | `test_missing_profile_names_profile_without_locked_guidance` (exit 1) |

Every mutant was reverted and the full suite re-verified green (exit 0) after
each revert. Two early attempts were discarded as invalid before evidence was
taken (M1 run with wrong workdir left the file untouched; M2 run with `-k`
boolean syntax ran 0 tests); both were redone correctly. Python `__pycache__`
was cleared between mutate/restore cycles (same-size/same-second writes can
serve stale bytecode). M6 initially motivated a stronger assertion: the test
now requires the branch-specific `missing from the login keychain` line, which
the generic branch cannot print.

## 5. AC coverage: 4 of 8 rows driven by named tests

| # | AC row | Evidence |
|---|---|---|
| 1 | Failure diagnosed | Stated bound: historical log excerpt §1 (`gh run view … --log-failed`) |
| 2 | Locked-keychain refusal repaired | `test_locked_keychain_fails_with_unlock_guidance` → `Scripts/release-preflight.sh` |
| 3 | Missing-profile refusal repaired | `test_missing_profile_names_profile_without_locked_guidance` → `Scripts/release-preflight.sh` |
| 4 | Identity gates repaired (missing/multiple/other-team/wiring) | `test_missing_identity_rejected`, `test_multiple_team_identities_rejected`, `test_sparkle_key_mismatch_rejected` → preflight; `SigningIdentityTests` (5) → `release_metadata.py signing-identity`, called from `Scripts/release.sh:61`; `test_release_signs_dmg_with_resolved_team_identity` wiring |
| 5 | Metadata tests pass | Suite itself: 16/16, exit 0 |
| 6 | Preflight passes | Direct production run: exit 0 (§3) |
| 7 | External waits identified accurately | Stated bound: `notarytool info/history` status-only outputs (§1, §6) |
| 8 | No premature publish | Stated bound: `gh release list` empty, tags unchanged, producer committed nothing (§3) |

Rows 2–5 (4 of 8) are driven through production entry points by 13 named
committed tests; row 6 is a direct production run; rows 1, 7, 8 are
historical/external-state facts evidenced by recorded command output.

## 6. Remaining bounds and external waits

- Full `release.sh` (archive/export/notarize/staple/appcast) intentionally
  unrun: it creates real Apple submissions and needs a release tag plus
  workflow env — validated in CI on coordinator dispatch.
- Apple queue latency: signing-check submission `In Progress` for 2h+ at
  handoff; if a 30m `--wait` times out, inspect the logged submission ID with
  `xcrun notarytool info <id> --keychain-profile RunnerControl-notary`
  (status only) and re-dispatch (new monotonic build number).
- First accepted Apple submission and the two-version update-install cycle are
  still pending per `RELEASING.md`.
- Runner-session keychain state at dispatch time is operator-controlled
  (console login on macbook-iv); preflight now fails fast with recovery steps.
- Per-item keychain ACL prompts remain an operator prerequisite (validated on
  macbook-iv); preflight proves profile readability, not per-item codesign ACLs.
- Product decision left to review/dispatch: retry `v1.1.0` via
  `workflow_dispatch(tag=v1.1.0)` (old-tag checkout keeps old diagnostics) or
  tag the new 1.1.1 on main HEAD (gets this fix). The `v1.1.0` tag exists with
  no release; deleting it is a product call, not taken here.

## 7. Handoff state

Candidate left **uncommitted** in story worktree
`task-board/story/STORY-260916-1o0gkc`: `RELEASING.md`,
`Scripts/release-preflight.sh`, `Scripts/release.sh`,
`Scripts/release_metadata.py`, `Scripts/tests/test_release_metadata.py`,
new `Scripts/tests/test_release_preflight.py`. Runners untouched (PIDs
observed read-only, never signalled). No tags created, no releases created.
