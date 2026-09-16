# Revision 2 review — accepted

Candidate: 5e6ff8b2978790fd401491af3d6993c7034d2cb8 against 7d2126aef02d9bb2c5443f5ef433462fda537732. Repository delta is present and limited to seven release documentation/script/test paths. No production code was modified by this reviewer; mutants ran in an isolated export of the candidate.

Rev1 F1 and F2 are resolved. Failed security reads reject both empty and partial output as unknown. The real release.sh is now driven by named packaging tests on first attempt and retry; exact codesign identity is observed. Existing hardened runtime archive, ZIP submission/app stapling, DMG submission/stapling, appcast validation and success-dependent workflow publication remain in place.

Coverage checked before code review: producer enumerates 7 of 7 AC rows with evidence. More precisely, 3 of 7 rows are automated test-driven (preflight repair, signing repair, metadata); 4 of 7 are operational observations/stated bounds (historical diagnosis, live preflight, external waits, publication). These observational rows cannot be established by fixture tests. Named driving tests include ReleasePreflightTests.test_failed_identity_read_with_empty_output_is_unknown_not_missing, test_failed_identity_read_with_partial_output_is_not_verified, test_locked_keychain_fails_with_unlock_guidance; ReleasePackagingTests.test_release_signs_dmg_with_resolved_team_identity and test_retry_attempt_signs_with_resolved_team_identity; ReleaseMetadataTests. Entry points are Scripts/release-preflight.sh, Scripts/release.sh -> release_metadata.py signing-identity, and release_metadata.py prepare/verify.

Independent checks:
- Frozen candidate Python suite: 23 tests, exit 0. Full output attached.
- Token-preserving retry-only ad-hoc identity narrowing mutant: behavioral suite fails the retry identity test; first-attempt control passes.
- Partial-output-only failed-read narrowing mutant: partial-read regression fails; empty-output control passes.
- Additional retry attack: security succeeds in preflight then returns a valid identity plus exit 42 at DMG resolution. Real release.sh exits 42, no DMG signing and no dist output.
- Real release-preflight.sh: exit 0, prerequisites verified in this session. This does not establish keychain availability in a future runner session.
- bash -n and candidate git diff --check: exit 0.
- gh api repos/relux-works/runner-control/releases: successful read returned []. Initial unsupported gh release list --json was discarded, not treated as absence.
- notarytool info for 6d537548-8c24-48ea-89b5-7ebb2dc959d5: successful read, In Progress, RunnerControlSigningCheck.zip.

Accepted existing rev2 validation log for unchanged Swift scope: complete command terminators, exit 0; 12 reported tests include one skipped real launch-agent lifecycle test. No Swift/UI/build replay was needed for this release-only delta. Producer mutant table is supplementary; reviewer independently reproduced the two prior defect classes.

Bounds: actual Apple signing/notarization and update installation are not proven by stubbed packaging tests. Full archive/notarize/publish was not dispatched. Historical failure diagnosis is accepted from producer run-log evidence; current preflight corroborates usable credentials in the current session only. Future runner keychain unlock, product integration/review and coordinator dispatch for v1.2.0 remain required. v1.1.0 is not retried or deleted. No credentials exported, tags created, releases published, or production runners interrupted.

Verdict: accepted for integration, not landed or released. No unresolved finding. Run goal queried: not goal-bound.
