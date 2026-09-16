# Review verdict — TASK-260916-2vzsmy revision 1

Verdict: changes_requested
repeat-of: none
Candidate: ab06be999eaa6481270aa98de9111422ea900288
Base: 7d2126aef02d9bb2c5443f5ef433462fda537732
Route: to-dev

## F1 — High: workflow trust coverage is static and admits a token-preserving bypass
repeat-of: none
Location: Scripts/tests/test_release_workflow.py:43-47.
Shape: bypass path around the check; source-text token preserved while behavior changes.
The new test only searches tokens in the workflow. In an isolated export of the exact candidate, append ` || true` to `git merge-base --is-ancestor HEAD origin/main`. All 51 tests pass (20.252s, exit 0), including the supposedly protective test. Execute the actual workflow run block with bash -e -o pipefail and harmless git/gh stubs: equal HEAD/tag hashes, ancestry exit 1, no existing release. Original exits 1; mutant exits 0. This weakens only the ancestry refusal and retains syntax, HEAD equality, and existing-release checks. The reviewer ran the entire behavioral suite, not only the static checker.
Required rework: add a named regression test that executes the actual workflow trust block with controlled command fixtures (or a production-extracted script actually invoked by that block), accepting a trusted tag and refusing non-main ancestry, mismatched HEAD/tag and malformed tags. Include this narrowing token-preserving mutant in evidence and require the behavioral regression to fail. Review existing-release lookup failure separately from confirmed absence. Keep work in this leaf; no separate research/harness task needed.

## F2 — Medium: recovery documentation contradicts the explicit release prerequisite
repeat-of: none
Location: RELEASING.md:78-83.
The statement that a pending signing-check submission does not block the next release contradicts release-operational-context.md: live submission 6d537548-8c24-48ea-89b5-7ebb2dc959d5 must not be duplicated and final release must wait for Accepted. The document currently encourages a conclusion the task explicitly forbids.
Required rework: state the existing submission ID, read-only status/recovery path, no duplicate test submission, and the Accepted prerequisite before final publication. Preserve the v1.2.0/product-and-smoke-integration boundary. No new submission or tag is needed for this correction.

## Coverage and validation bounds
Producer reports 6 of 6 AC rows driven. Review finds named tests for all six rows but does not accept 6/6 behavioral coverage: row 6 is static-only, row 5 is a handoff procedure rather than a driving test. Rows 1-4 have test bindings; 4 of 6 rows have executable test evidence, with documentation semantics limited as F2 shows, row 5 is procedural, row 6 requires rework. Production entries for rows 1/2 are release.sh/release-preflight.sh; metadata CLI is driven by packaging tests; documentation checks are direct source comparisons.
Accepted as prior evidence: complete attached revision-1 validation log records 51 release tests green and Swift test execution exit 0. Reviewer did not rerun Swift, real signing, network downloads, Apple submission, or publication. Independently reran all 51 release tests against the isolated one-line mutant; full output attached as TASK-260916-2vzsmy_review-attack-rev1.log. This is diagnostic evidence of a surviving mutant, not a claim of a new baseline run. Producer bounds B1-B9 remain relevant. No repository code was edited, no UI tests or production runner actions occurred, and nothing was committed, tagged or published.

Run goal query: Active Goal none (run not goal-bound).
