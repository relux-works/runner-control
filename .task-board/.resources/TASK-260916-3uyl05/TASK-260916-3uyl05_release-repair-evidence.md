# TASK-260916-3uyl05 — release CI signing/notary repair: evidence (rev2)

Rework run addressing review verdict rev1 (`changes_requested`, F1 + F2,
both `repeat-of: none`). No `repeat-of` class was named, so no repeat-of
regression obligation applies; F1/F2 rework below is the verdict's required scope.

## Diagnosis (independent, read-only)

Failed run `35040921163` (tag `v1.1.0`, push-triggered) failed in step
**Release prerequisites** after 17s; no build, signing, notarization, or
publish step ran. Failed-step log (`gh run view 35040921163 --log-failed`):

- `Error: keychainLocked(keychainName: "default", keychainURL: nil)` from
  `xcrun notarytool history --keychain-profile RunnerControl-notary`
- exit code 1; root cause is environmental: the login keychain was locked
  in the runner session on macbook-iv, so the notary profile was unreadable.
- `gh release list` is empty and tag `v1.1.0` still points at `8b3a276`:
  **no draft or published release was created.** No premature publication.
- Local counter-proof: `./Scripts/release-preflight.sh` exits 0 in an
  unlocked interactive session on the same Mac (exactly one Developer ID
  Application identity for team `262RZ595FP`, fingerprint
  `267D90FC976A48CF830BE7F41AE612999E025054`; notary profile readable;
  Sparkle private key matches `SUPublicEDKey`). Same credentials, different
  session state — confirms keychain lock, not missing credentials.
- Notary submission `6d537548-8c24-48ea-89b5-7ebb2dc959d5`
  (`RunnerControlSigningCheck.zip`) inspected status-only via
  `xcrun notarytool info --keychain-profile RunnerControl-notary`:
  **In Progress**. It is a signing check, not a release artifact, and does
  not block the next release. No credentials printed or exported at any point.

## Repair (release workflow/scripts/docs only; no tag/publish)

1. `Scripts/release-preflight.sh` — fails fast with actionable guidance:
   locked login keychain (`keychainLocked`) → unlock + `workflow_dispatch`
   retry guidance; missing notary profile → `store-credentials` guidance;
   zero or multiple Developer ID Application identities for `262RZ595FP` →
   hard error; Sparkle key mismatch → reject.
2. **F1 (verdict):** identity read is fail-closed. `security find-identity`
   now runs unwrapped from the parse pipeline; a nonzero exit reports
   `Could not read signing identities; the result is unknown, not missing`
   and exits 1 — never "verified" (partial output) and never "missing"
   (empty output). `release.sh` line 61 was already fail-closed here via
   `set -o pipefail` with no `|| true` (verified by reading the script;
   a `security` failure fails the command substitution and aborts).
3. `Scripts/release_metadata.py` — `signing-identity` subcommand
   (`resolve_signing_identity`): ignores Apple Development and other-team
   identities, raises on zero or several team matches.
4. `Scripts/release.sh` line 61 — DMG identity resolved through
   `release_metadata.py signing-identity --team 262RZ595FP` instead of
   `sed | head -n 1`. Hardened-runtime signing, app ZIP + DMG
   notarization/stapling, signed appcast + SHA256SUMS gating before publish
   are unchanged and preserved.
5. **F2 (verdict):** new `Scripts/tests/test_release_packaging.py` drives
   the REAL `release.sh` end to end with stubbed macOS tools (fixture
   target: coordinator-approved `v1.2.0`): asserts the exact resolved team
   identity reaches `codesign --sign` on attempt 1 and on retry
   (`GITHUB_RUN_ATTEMPT=2`), and that zero/multiple identities prevent all
   packaging (`release-*` dirs) and workflow output (`dist=`). The static
   `ReleaseWiringTests` source-line check is retained only as a tripwire,
   not claimed as behavioral coverage.
6. `RELEASING.md` — "Failure recovery": run diagnosis, fail-fast list
   (including failed-read semantics), 30-min Apple waits, pending-check
   note. Per coordinator directive: **`v1.1.0` is neither retried nor
   deleted; the approved next release is new `v1.2.0` after product
   integration**; no tag until product review + coordinator dispatch. The
   unlock/`workflow_dispatch` procedure now applies to future runs.

No Relux/app code, generator output, or runner state touched. No new
delegates. Candidate left uncommitted in the story worktree.

## Validation results (all exit codes real, run this session unless noted)

| Command | Result |
|---|---|
| `python3 -m unittest discover -s Scripts/tests` | exit 0 — 23/23 pass (11 metadata+resolver+wiring, 8 preflight, 4 packaging) |
| `./Scripts/release-preflight.sh` (unlocked session, post-F1) | exit 0 — prerequisites verified |
| `swift test --package-path Packages/RunnerControlCore` | exit 0 — 12/12 pass (earlier this run; Swift sources untouched since, green evidence reused) |
| `python3 -m py_compile` + `bash -n` on touched scripts | exit 0 |
| CI gates (`ci.yml`) | no linter configured; both CI test commands green |
| `gh release list` / `git ls-remote --tags` | no releases; only tag `v1.1.0` — nothing published |

## Mutant evidence (harness `/tmp/TASK-260916-3uyl05_mutants.py`, files checksum-restored)

Admission mutants prove a forbidden member is refused; the one diagnostic
mutant (M4) proves guidance precision and is classified as such, not as
admission evidence.

| Mutant | Class | What it narrows the gate to | Named failing test | Verdict |
|---|---|---|---|---|
| M1 team-prefix (kind token preserved) | admission | admits exactly near-match team `262RZ595FX` | `SigningIdentityTests.test_rejects_near_match_team` | KILLED |
| M2 multi-identity (`>1`→`>2`) | admission | admits exactly the 2-identity case | `SigningIdentityTests.test_rejects_multiple_team_identities` | KILLED |
| M3 kind-team-only (team token preserved) | admission | admits exactly same-team Apple Development cert | `SigningIdentityTests.test_rejects_same_team_apple_development` | KILLED |
| M4 locked-classifier | diagnostic | locked class falls to generic branch, still refuses; proves guidance precision | `ReleasePreflightTests.test_locked_keychain_fails_with_unlock_guidance` | KILLED |
| M5 preflight-multi (`-gt 1`→`-gt 2`) | admission | admits exactly the 2-identity case | `ReleasePreflightTests.test_multiple_team_identities_rejected` | KILLED |
| M6 partial-read (F1 required) | admission | admits just the partial-output failure as success; paired empty-output test still passes | `ReleasePreflightTests.test_failed_identity_read_with_partial_output_is_not_verified` | KILLED+NARROW-OK |
| M7 retry-adhoc (reviewer's token-preserving mutant, resolver line intact) | admission | attempt 2 ad-hoc signs with `-`; paired attempt-1 test still passes | `ReleasePackagingTests.test_retry_attempt_signs_with_resolved_team_identity` | KILLED+NARROW-OK |
| M8 team-swap (`--team` token preserved, value swapped) | admission | DMG signing resolves wrong-team member | `ReleasePackagingTests.test_release_signs_dmg_with_resolved_team_identity` | KILLED |

No survivors. M1/M3/M7/M8 preserve the searched-for token while changing
behavior; M7/M8 execute the behavioral `release.sh` suite, not a static checker.

## AC coverage: 7 of 7 explicitly enumerated rows, each with production call site

AC sentence split into auditable rows (row = one verifiable claim):

1. Failure diagnosed — `gh run view 35040921163 --log-failed` (production
   run log: `keychainLocked` in Release prerequisites, exit 1).
2. Preflight repaired — `Scripts/release-preflight.sh` real run exit 0 +
   8 production-entry harness tests (locked/missing-profile/zero/multiple/
   sparkle-mismatch/failed-read-empty/failed-read-partial).
3. Signing repaired — `Scripts/release.sh:61 → release_metadata.py
   signing-identity`: 4 behavioral packaging tests assert the exact SHA
   reaches `codesign --sign` (attempts 1–2) and failures block output.
4. Metadata tests pass — `python3 -m unittest discover -s Scripts/tests`, exit 0.
5. Preflight passes — `./Scripts/release-preflight.sh`, exit 0.
6. Remaining external waits identified — `xcrun notarytool info`
   (submission In Progress), Apple 30-min waits, runner-session keychain
   unlock, v1.2.0 coordinator dispatch (v1.1.0 explicitly not retried).
7. No premature publication — `gh release list` empty; no tag/release/run
   dispatched by this task.

## Remaining external waits / bounds (stated, not inferred)

- Runner-session login keychain must be unlocked (console login as runner
  user on macbook-iv) before any future release run; preflight now names
  this state explicitly on failure.
- Next release is `v1.2.0` after product integration (version bump + tag are
  product/coordinator scope, not this task); `v1.1.0` stays untagged-as-release.
- Full archive → notarize → staple → publish cycle is the release workflow
  itself and was not re-run here (would publish); app code is untouched by
  this task, and prior validation status for the app build stands.
- Workflow annotation only: Node.js 20 deprecation warning on pinned
  actions (forced to Node 24); not a failure, pins intentionally unchanged.
