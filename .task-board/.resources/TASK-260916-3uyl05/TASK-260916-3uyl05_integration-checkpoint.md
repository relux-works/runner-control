# TASK-260916-3uyl05 — integration checkpoint evidence (RUN-260916-d3bf6f)

Accepted Change Request `CR-TASK-260916-3uyl05-2` revision 2 checkpointed onto
`task-board/story/STORY-260916-1o0gkc`. Board status remains `integrating`;
nothing landed on trunk, nothing released.

- Base: `7d2126aef02d9bb2c5443f5ef433462fda537732` (main)
- Checkpoint: `80f324080e7700f4ad2aff6458b1ec6c125a4d50`
- Delta: 7 release-only paths (RELEASING.md, Scripts/release.sh,
  Scripts/release-preflight.sh, Scripts/release_metadata.py, 3 Scripts/tests files)
- Review verdict rev2: accepted for integration, no unresolved finding

## Fresh verification (this run, standalone processes)

| Command | Exit | Result |
|---|---|---|
| `python3 -m unittest discover -s Scripts/tests -v` | 0 | 23/23 ok (11 metadata/wiring/signing + 4 packaging + 8 preflight) |
| `bash -n Scripts/release.sh` | 0 | syntax ok |
| `bash -n Scripts/release-preflight.sh` | 0 | syntax ok |
| `git diff --check` | 0 | clean |
| `bash Scripts/release-preflight.sh` (standalone, live keychain) | 0 | `Release prerequisites verified (team 262RZ595FP, notary profile 'RunnerControl-notary').` |
| `gh api repos/relux-works/runner-control/releases --jq 'length'` | 0 | `0` — no public release published |
| `git tag --list` | 0 | only pre-existing `v1.1.0`; no tag created by this work |
| `task-board worktree checkpoint TASK-260916-3uyl05` | 0 | checkpointed as 80f3240; status integrating |

## Reused evidence (unchanged identity)

Swift core suite: 12 tests (1 skipped real launch-agent lifecycle test), exit 0,
accepted from `TASK-260916-3uyl05_change-request_rev2-validation.log`.
Identity unchanged — the accepted delta touches no Swift, Package, or Tuist
inputs — so no replay was run for that scope. Reviewer rev2 independently
reproduced the F1/F2 mutant kills on the frozen candidate; not re-attacked here.

## Stated bounds

- Live preflight exit 0 corroborates usable signing/notary credentials in the
  current session only; it does not establish keychain availability in a future
  runner session (the original run-35040921163 failure mode).
- Notary submission `6d537548-...` status accepted from reviewer rev2 evidence
  (`notarytool info`: successful read, In Progress); not re-polled in this run.
- Actual Apple signing/notarization and update installation are not proven by
  stubbed packaging tests; full archive/notarize/publish was not dispatched.
- Historical failure diagnosis accepted from producer run-log evidence.
- No credentials printed or exported; no production runner interrupted.

## Post-checkpoint state

- `git status`: clean tree on `task-board/story/STORY-260916-1o0gkc`
- `git show --stat HEAD`: 7 files, 478 insertions, 3 deletions
- `task-board worktree obligations`: no revision waiting without a live run
