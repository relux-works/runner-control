# Review verdict: changes_requested

Task: TASK-260916-3uyl05 — release-ci-signing-and-notary
CR: CR-TASK-260916-3uyl05-1 revision 1
Candidate: 5a6f33c60d18360c07004a1a2837706f36274c1c
repeat-of: none

## F1 — Failed/partial identity read treated as satisfied (high)
repeat-of: none
Scripts/release-preflight.sh:6 suppresses the entire security/grep pipeline failure with `|| true`. Through the real preflight entry point, a stub security command emitted the valid expected identity and exited 42: preflight exited 0 and printed “Release prerequisites verified”. With no output and the same failure it falsely reported a missing identity and instructed certificate issuance. These are failed reads, not proof of presence or absence.
Required: preserve and check security exit status before parsing; distinguish unavailable/failed read from successful empty result. Add named production-entry regression tests for nonzero status with both empty and partial valid output, and a narrowing mutant admitting just the partial-output failure. Keep this rework within this leaf.

## F2 — Signing gate coverage is helper/static-only (high)
repeat-of: none
Coverage was checked before code: producer reports 4 of 8 AC rows driven, with historical/external observations explicitly bounded. Those bounds do not excuse claiming signing CLI/production coverage: SigningIdentityTests directly call the helper, and ReleaseWiringTests only searches a live source line. No test executes release.sh through the identity selection and codesign invocation.
Independent token-preserving narrowing mutant added, immediately after the intact resolver line: on GITHUB_RUN_ATTEMPT=2 only, replace signing_identity with “-”. All 16 tests still pass (exit 0). This demonstrates an unchecked retry path and a static-source proxy, not a current production ad-hoc-signing defect. Producer M4 comments out the resolver and tests source text; it does not prove behavioral wiring. M1/M6 alter diagnostic classification but still refuse, so “6 narrowing mutants” overstates admission-gate evidence.
Required: drive the actual release.sh entry point with isolated macOS command fixtures, assert the resolved identity reaches codesign and failures prevent later packaging/output; cover retry and zero/multiple identities. Kill the token-preserving retry mutant with a named behavioral test. Correct the AC ratio/call-site claims and classify mutants accurately. No actual Apple submission or publication is needed for this harness.

## Evidence and bounds
- Attached reviewer attack log contains all 16 mutant-suite results and both failed-read production-entry reproductions; all tools were fixtures, no credentials read/exported and no runner touched.
- Candidate files matched the provided tree before verdict. Mutations ran only in a disposable copy; repository source unchanged.
- Accepted existing attached validation log as evidence of baseline 16 Python tests and Swift core validation (real LaunchAgent test explicitly skipped); did not replay unrelated Swift tests.
- Did not rerun real release/sign/notarize/publish or assert current external Apple/GitHub state. Historical diagnosis is plausible and the producer explicitly leaves real release verification pending.
- Coordinator directive received: intended release is approved new v1.2.0 after product integration; do not retry/delete v1.1.0. Rework notes should use this target rather than presenting old-tag retry as an outstanding product decision.
- Run goal query: not goal-bound. No logbook tool/CLI available in this runtime; important findings persisted here and in board notes.

Route: to-dev for focused implementation/test rework, then independent review. No human decision or external blocker is needed for these findings.
