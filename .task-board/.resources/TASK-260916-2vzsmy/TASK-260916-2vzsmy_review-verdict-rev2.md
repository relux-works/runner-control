# Review verdict: changes_requested

Candidate: CR-TASK-260916-2vzsmy-2 revision 2, tree 0acdbb9b6db1b5f08efd76595f458e22f5434679; repository_delta=present.
repeat-of: rev1 F1

## F1 — workflow call-site bypass remains untested

Shape: bypass path around the check; token-preserving mutant; check present but its production caller can discard refusal.

Scripts/tests/test_release_workflow.py test_workflow_invokes_trust_script_before_any_work asserts only a substring. Behavioral tests run the script directly, so they do not execute the composed workflow run command. In an isolated archive of the exact candidate, changing the actual Validate trusted release tag run command to `./Scripts/validate-release-tag.sh || true` preserves the searched token and every script guard, but lets non-main ancestry proceed to release work. All 60 tests still pass (21.078s, exit 0). Independently executing the original and mutated workflow commands with ANCESTRY_EXIT=1 gives exit 1 and exit 0 respectively, with the same refusal stderr. See attached full attack log.

Required rework: add a named regression test that executes the actual workflow run command with refusing trust inputs and verifies the step fails. Include this call-site narrowing mutant and require that regression to fail. Keep this in the same leaf; no separate harness/research task is needed. This is the second consecutive same-class F1 finding.

## Coverage and resolved finding

Producer reports 5 of 6 AC rows driven, one procedural bound. Reviewer finds 4 of 6 adequately evidenced: row 6 remains only script behavior plus static workflow wiring, with the demonstrated caller blind spot; row 5 remains procedural. F2 is resolved in the candidate text: the diagnostic submission is explicitly not a prerequisite, while each actual release artifact requires Accepted and staple verification. No new F2 finding.

## Validation and limits

Personally ran the full 60-test behavioral/static suite against the token-preserving workflow mutant, plus the independent original/mutated composed-step refusal probe. Did not claim a pristine full-suite rerun or rerun prior producer mutants. Reviewed the task-scoped rev2 coverage/mutant report and production delta. Apple notarization, publication, Swift/UI tests, and live runner operations were not exercised. No source edits, tags, commits, publication, secret output, or runner interruption. Run goal queried: not goal-bound.

Route: to-dev. Acceptance is withheld pending F1 regression and another review.
