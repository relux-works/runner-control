# TASK-260916-2vzsmy: validate-and-publish-release

## Description
Validate repaired release automation, preflight and source documentation after the CI fix checkpoint. Exercise release metadata and packaging gates with focused tests; document exact signing/notarization and Sparkle requirements. This leaf prepares the release machinery for integration; do not tag or publish yet. Final release is a separate delivery Story after both code Stories land. Use Muse Spark max. No UI tests, no production runner interruption, no secret output, no manual Story commits.

## Scope
(define task scope)

## Acceptance Criteria
Release scripts and preflight are validated and documented, metadata tests pass, candidate ready for review and integration so the subsequent release tag uses the repaired workflow.
