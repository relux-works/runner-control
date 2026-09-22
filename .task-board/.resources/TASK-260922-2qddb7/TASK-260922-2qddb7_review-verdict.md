# TASK-260922-2qddb7 - review-cli-parity-astra: REJECT

Verdict: changes_requested; route to-dev. Four reproduced mechanisms block acceptance. No Change Request revision was handed to this run; spawn goal reports not goal-bound. No commit, live auth logout, real Keychain mutation, real runner mutation, or plist-key deletion was performed. Candidate product files are unchanged from the recorded SHA256 manifest.

## Findings

- installer-lock-fails-open: unavailable lock evidence admits two installer owners.
- executable-path-from-argv: ordinary PATH invocation reports the wrong executable and self-installs a dangling symlink with success.
- shared-refresh-loser-erases-session: a late failing independent auth owner erases a newer shared session.
- json-error-adapter-bypass: parser failures exit 64 with no JSON; a transport failure exits 1 with no JSON.

The findings array below is authoritative. Every repeat-of is none: the prior failed spawn had no completed verdict/revision. All repro assertions fail against the exact unmodified candidate objects/binary; no production code was mutated. Requested regression tests and narrowing mutants belong in the implementation leaf, not a separate research task.

## Review coverage and validation

No producer review/free-hunt budget was supplied; the review used a 30-minute sweep ceiling and 5-minute additional hunt ceiling. Each initial surface result was appended to the board artifact before the next row. The extra concurrency probes are recorded as free hunt. Final rows carry exactly one result each; held only means the named attacks did not reproduce.

Reran 18 CLI tests, 6 focused Core tests, 5 static parity pins, and 12 release-packaging tests; all passed. CLI built afresh from this candidate in /tmp. The Core and packaging subsets were repeated solely to save complete standalone logs. Custom adversarial probes deliberately exit 1 when their contract assertion fails. All five probe modes fail as expected (four mechanisms; JSON parser and network modes share one mechanism).

Producer claims of full Core 269/269, full Python 97/97, live same-team session sharing, and release-path signing were not adopted as fresh measured results. Real Keychain suite coverage was excluded under the explicit user guardrail. Existing dev app/helper pass codesign strict/deep, both TeamIdentifier V8V53456PB; helper is arm64+x86_64. This is a dev artifact inspection, not proof the reviewed source was released or notarized.

AC-driving map at intake: 0/4 proposal constraints explicitly bound to named driving tests in the handoff; this measures missing bindings, not missing tests. Source reference overlap is 25/36 explicitly spelled GUI effects, with blind spots for indirect factories and semantic equivalents. It is not a parity coverage percentage or a gate proof.

## Checklist evidence

1. Read proposal and full product diff vs fb85df5: proposal.md plus all 30 changed/untracked product files in candidate-sha256.json; board activity noise excluded from the stated product scope.
2. Command-by-command parity assessed below. Unresolved: complete behavioral parity, including login settings and retry semantics. Sources: HeadlessRuntime.swift:29; ManagementWindowContainer.swift:69; RunnerRegistrationContainer.swift:112.
3. Shared session/Keychain assessed: CLIConfig.swift:13-28; RunnerRuntime.swift:45-56; GitHubKeychainStore.swift:79; shared-refresh-loser-erases-session. Real cross-surface Keychain behavior unresolved.
4. JSON/exit assessed: CLIEntry.swift:42-50; DTOs.swift:7-12; json.log and network.log reproduce failures.
5. Reject verdict and reasons recorded in this task outcome and notes.
6. Implementation matches AC: NO. Four findings; full parity unresolved. Checklist tick records assessment, not successful conformance.
7. Architecture assessed: shared Runtime/effects and service reuse fit the project; per-process mutable authority and the separate System Events settings adapter leave gaps (findings/notes below).
8. Tests green: named repository subsets pass; full suite explicitly unresolved/not run. Adversarial assertions are red and must become regressions before acceptance.
9. Gates attacked through production entries: main CLI parser/run, CLIInstallerService called by app install/uninstall, RunnerInstallerService.downloadAndInstall, GitHubAuth.Flow.apply(restoreSession), and release.sh packaging. Logs and replay files attached.
10. Evidence attached before the single to-dev verdict transition. No acceptance, CR integration, commit acknowledgement, or commit performed.

## Command/effect assessment

All file references in this table are under Packages/RunnerControlCLI/Sources unless stated. “Source match” is not a behavioral end-to-end claim.

| Command | Production mapping/evidence | Assessment |
|---|---|---|
| auth status | AuthCommands.swift:36; HeadlessRuntime.restore :58 | Shared restore; stale-owner session finding; live execution excluded |
| auth login | AuthCommands.swift:75; HeadlessRuntime.waitForLogin | Same beginLogin/poll effects; live login excluded |
| auth logout | AuthCommands.swift:118 | Same logout effect; NEVER invoked |
| auth installations | AuthCommands.swift:140 | Same refresh effect; live auth excluded |
| auth installation | AuthCommands.swift:176 | Same selectInstallation effect; invalid-ID parser tested |
| runners list | RunnersCommands.swift:41; :49 | loadCatalog and optional refreshRemote; live catalog not touched |
| runners show | RunnersCommands.swift:78 | Snapshot/DTO view; helper DTO tests passed |
| runners on | RunnersCommands.swift:130 | setEnabledMany; direct single GUI setEnabled represented by list; not run live |
| runners off | RunnersCommands.swift:166-167 | confirmation plus setEnabledMany; not run live |
| runners discover | RunnersCommands.swift:209 | discover effect; hermetic headless test passes |
| runners add | RunnersCommands.swift:239 | importFolder; GUI importCandidate equivalence source-assessed only |
| runners remove | RunnersCommands.swift:264-269 | same removeFromApp; suppressed error note unresolved |
| runners unregister | RunnersCommands.swift:295-296 | typed confirmation and effect; NEVER invoked live |
| runners alias | RunnersCommands.swift:329-341 | same setAlias; missing-argument parser tested |
| runners login-start | RunnersCommands.swift:363-374 | same setRunAtLoad; not run live |
| runners relink | RunnersCommands.swift:402 | same relinkDirectory; not run live |
| runners logs | RunnersCommands.swift:430, :438 | diagnostics paths and loadLog; source match only |
| runners group-access | RunnersCommands.swift:473, :499 | load/apply effects; empty selection note unresolved |
| register | RegisterCommand.swift:46-79 | same begin/group/download/register/setup/access/labels effects; scope inputs tested; retry/post-registration edits unresolved |
| app version | AppCommands.swift:24 | Wrong executable and bundle discovery under PATH reproduced |
| app check-updates | AppCommands.swift:49-55 | Intentional read-only non-goal exception; transport error contract fails |
| app launch-at-login | AppCommands.swift:306; GUI LaunchAtLoginModel.swift:9 | Different platform mechanisms; parity unverified |
| app auto-check | AppCommands.swift:121, :266 | Shared defaults key; live GUI propagation unverified |
| app auto-update | AppCommands.swift:138, :266 | Shared defaults key; live GUI propagation unverified |
| app install-cli | AppCommands.swift:158; Core CLIInstallerService.swift:103 | shared GUI service; PATH resolution finding, PATH lease omission note |
| app uninstall-cli | AppCommands.swift:192 | foreign link refusal passed in isolated fixture; PATH target resolution affected |

GUI-only selection/draft/dismissal/log-preview state can fit the stated non-goals, but re-running the register pipeline as retry is not proven by sharing individual effect types. Public effect reference details follow as a diagnostic inventory, with no claim of source scanning completeness.


| GUI effect | GUI reference | CLI reference |
|---|---|---|
| GitHubAuth.beginLogin | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:123 | Packages/RunnerControlCLI/Sources/AuthCommands.swift:75 |
| GitHubAuth.cancelLogin | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:86 | Packages/RunnerControlCLI/Sources/HeadlessRuntime.swift:101 |
| GitHubAuth.logout | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:87 | Packages/RunnerControlCLI/Sources/AuthCommands.swift:118 |
| GitHubAuth.refreshInstallations | Targets/RunnerControl/Sources/AppRegistry.swift:42 | Packages/RunnerControlCLI/Sources/AuthCommands.swift:140 |
| GitHubAuth.restoreSession | Targets/RunnerControl/Sources/AppRegistry.swift:18 | Packages/RunnerControlCLI/Sources/HeadlessRuntime.swift:59 |
| GitHubAuth.selectInstallation | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:91 | Packages/RunnerControlCLI/Sources/AuthCommands.swift:176 |
| GitHubAuth.selectRepositories | Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift:97 | No explicit reference; equivalence/exclusion needs assessment |
| RunnerRegistration.applyLabels | Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift:125 | Packages/RunnerControlCLI/Sources/RegisterCommand.swift:78 |
| RunnerRegistration.applyRepositoryAccess | Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift:118 | Packages/RunnerControlCLI/Sources/RegisterCommand.swift:73 |
| RunnerRegistration.cancel | Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift:128 | No explicit reference; equivalence/exclusion needs assessment |
| RunnerRegistration.dismissPermission | Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift:130 | No explicit reference; equivalence/exclusion needs assessment |
| RunnerRegistration.downloadAndInstall | Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift:113 | Packages/RunnerControlCLI/Sources/RegisterCommand.swift:60 |
| RunnerRegistration.registerRunner | Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift:114 | Packages/RunnerControlCLI/Sources/RegisterCommand.swift:63 |
| RunnerRegistration.reset | Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift:129 | No explicit reference; equivalence/exclusion needs assessment |
| RunnerRegistration.resolveGroup | Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift:112 | Packages/RunnerControlCLI/Sources/RegisterCommand.swift:51 |
| RunnerRegistration.retry | Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift:127 | No explicit reference; equivalence/exclusion needs assessment |
| RunnerRegistration.setupService | Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift:115 | Packages/RunnerControlCLI/Sources/RegisterCommand.swift:66 |
| RunnerRegistration.updateDraft | Targets/RunnerControl/Sources/RunnerRegistrationContainer.swift:148 | No explicit reference; equivalence/exclusion needs assessment |
| Runners.applyGroupAccess | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:269 | Packages/RunnerControlCLI/Sources/RunnersCommands.swift:499 |
| Runners.clearLog | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:79 | No explicit reference; equivalence/exclusion needs assessment |
| Runners.discover | Targets/RunnerControl/Sources/AppRegistry.swift:22 | Packages/RunnerControlCLI/Sources/RunnersCommands.swift:209 |
| Runners.importCandidate | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:70 | No explicit reference; equivalence/exclusion needs assessment |
| Runners.importFolder | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:188 | Packages/RunnerControlCLI/Sources/RunnersCommands.swift:239 |
| Runners.loadCatalog | Targets/RunnerControl/Sources/AppRegistry.swift:21 | Packages/RunnerControlCLI/Sources/HeadlessRuntime.swift:60 |
| Runners.loadGroupAccess | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:82 | Packages/RunnerControlCLI/Sources/RunnersCommands.swift:473 |
| Runners.loadLog | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:78 | Packages/RunnerControlCLI/Sources/RunnersCommands.swift:438 |
| Runners.refresh | Targets/RunnerControl/Sources/AppRegistry.swift:29 | No explicit reference; equivalence/exclusion needs assessment |
| Runners.refreshRemote | Targets/RunnerControl/Sources/AppRegistry.swift:43 | Packages/RunnerControlCLI/Sources/RunnersCommands.swift:49 |
| Runners.relinkDirectory | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:288 | Packages/RunnerControlCLI/Sources/RunnersCommands.swift:402 |
| Runners.removeFromApp | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:203 | Packages/RunnerControlCLI/Sources/RunnersCommands.swift:264 |
| Runners.selectRunner | Targets/RunnerControl/Sources/RunnerContainer.swift:21 | No explicit reference; equivalence/exclusion needs assessment |
| Runners.setAlias | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:257 | Packages/RunnerControlCLI/Sources/RunnersCommands.swift:341 |
| Runners.setEnabled | Targets/RunnerControl/Sources/RunnerContainer.swift:44 | No explicit reference; equivalence/exclusion needs assessment |
| Runners.setEnabledMany | Targets/RunnerControl/Sources/RunnerContainer.swift:41 | Packages/RunnerControlCLI/Sources/RunnersCommands.swift:130 |
| Runners.setRunAtLoad | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:74 | Packages/RunnerControlCLI/Sources/RunnersCommands.swift:374 |
| Runners.unregister | Targets/RunnerControl/Sources/ManagementWindowContainer.swift:240 | Packages/RunnerControlCLI/Sources/RunnersCommands.swift:296 |

## Structured verdict

```json
{
  "task": "TASK-260922-2qddb7",
  "title": "review-cli-parity-astra",
  "run": "RUN-260922-3075e9",
  "verdict": "changes_requested",
  "display_verdict": "reject",
  "route": "to-dev",
  "candidate_base": "fb85df52b7ed74a05725ac4be3c2b0668aff54a8",
  "change_request": null,
  "goal_bound": false,
  "surface_table": [
    {
      "id": "shared-session",
      "catalog_surface": "identity",
      "result": "broken",
      "attacks": "Independent-owner stale refresh cleanup",
      "findings": [
        "shared-refresh-loser-erases-session"
      ],
      "bound": "Production flow entry with deterministic in-memory persistence/transport; no real signed cross-process Keychain test."
    },
    {
      "id": "json-exit",
      "catalog_surface": "error surface",
      "result": "broken",
      "attacks": "Unknown flag, missing argument, invalid scalar; transport failure",
      "findings": [
        "json-error-adapter-bypass"
      ]
    },
    {
      "id": "path-install",
      "catalog_surface": "destination conflicts",
      "result": "broken",
      "attacks": "PATH and symlink invocation; regular-file and foreign-link refusals",
      "findings": [
        "executable-path-from-argv"
      ]
    },
    {
      "id": "gui-effect-parity",
      "catalog_surface": "selector paths",
      "result": "not-attacked",
      "reason": "Missing injectable full-command GUI/CLI mutation fixture; live runner/session/plist mutations excluded. Source and command inventory assessed with explicit unresolved notes."
    },
    {
      "id": "release-identity",
      "catalog_surface": "identity",
      "result": "held",
      "attacks": "Public release.sh via test_release_packaging.py: missing/ambiguous/malformed identity, wrong team, notary rejection, appcast tamper",
      "bound": "External signing/notary tools are stubbed. Existing dev artifact also verifies strict/deep and has matching team; release notarization remains unobserved."
    },
    {
      "id": "installer-lease",
      "catalog_surface": "destination conflicts",
      "result": "broken",
      "attacks": "Free hunt: unavailable lock evidence compared with normal contention control",
      "findings": [
        "installer-lock-fails-open"
      ]
    }
  ],
  "findings": [
    {
      "id": "installer-lock-fails-open",
      "row": "installer-lease",
      "invariant": "Independent installer owners must not enter mutation work without the shared exclusive lease.",
      "mechanism": "Packages/RunnerControlCore/Sources/RunnerInstallerService.swift:206 returns nil when open fails; acquireMutationLease accepts it at :171. The same fail-open occurs on mkdir or non-contention flock errors.",
      "reproductions": [
        {
          "test_file": "review-driver.swift (in TASK-260922-2qddb7_reproductions.zip)",
          "command": "./review-driver lock",
          "expected_failure": "Exit 1: no_two_downloaders=false when the lock path is a directory.",
          "observed": "Normal file: one downloader and installerBusy. Unopenable lock: two independent real RunnerInstallerService.downloadAndInstall calls enter downloader concurrently.",
          "log": "lock.log"
        }
      ],
      "severity": "bypass",
      "repeat-of": "none",
      "requested_rework": "Fail closed on all lease acquisition errors, and hold leases for the whole mutation. Add a named public-entry regression test for unopenable lock evidence and a narrowing mutant that handles contention but admits other lock failures. Also address the separate PATH installer lease required by proposal.md."
    },
    {
      "id": "executable-path-from-argv",
      "row": "path-install",
      "invariant": "An installed command invoked by name through PATH resolves its running binary and self-installs a working symlink to it.",
      "mechanism": "Packages/RunnerControlCore/Sources/CLIInstallerService.swift:71 resolves argv[0] as a cwd-relative path; Packages/RunnerControlCLI/Sources/CLIConfig.swift:60 repeats this assumption for bundle discovery. AppCommands.swift:155 passes the nonexistent target to install, which does not validate target existence.",
      "reproductions": [
        {
          "test_file": "blackbox.py (in TASK-260922-2qddb7_reproductions.zip)",
          "command": "python3 blackbox.py path",
          "expected_failure": "Exit 1: actual-executable and working-link assertions fail.",
          "observed": "PATH invocation returns $PWD/runner-control as executable and reports install success with a dangling symlink. A separate zsh -f invocation reproduced the wrong executable path. Regular-file install and foreign-symlink uninstall refusal controls pass.",
          "log": "path.log"
        }
      ],
      "severity": "bypass",
      "repeat-of": "none",
      "requested_rework": "Resolve the process executable independently of argv spelling, use it consistently for bundle/config discovery, and refuse invalid installer targets. Add public subprocess tests for absolute, relative, PATH and symlink invocation."
    },
    {
      "id": "shared-refresh-loser-erases-session",
      "row": "shared-session",
      "invariant": "A stale failing refresh must preserve a newer valid shared session written by another owner.",
      "mechanism": "Packages/RunnerControlCore/Sources/GitHubAuth+Flow.swift:346-348 deletes shared credentials and identity after refresh failure without checking which record is still current. GitHubTokenRefresh.swift:37 only coalesces within one actor; RunnerRuntime.swift:47 creates one per runtime/process.",
      "reproductions": [
        {
          "test_file": "review-driver.swift (in TASK-260922-2qddb7_reproductions.zip)",
          "command": "./review-driver refresh",
          "expected_failure": "Exit 1: newer_shared_session_survives=false.",
          "observed": "Two independent production GitHubAuth.Flow.apply(restoreSession) owners share in-memory stores. Both refresh old credentials. First succeeds and saves a new session; second receives invalid_grant. token_after_winner=true, token_after_loser=false, identity_after_loser=false.",
          "log": "refresh.log"
        }
      ],
      "severity": "regression",
      "repeat-of": "none",
      "requested_rework": "Coordinate shared refresh/session writes across owners and condition destructive cleanup on the failed record still being current. Add a named regression covering this deterministic interleaving and a narrowing mutant that protects only one in-process owner. Test both failed refresh and late unauthorized readback cleanup paths."
    },
    {
      "id": "json-error-adapter-bypass",
      "row": "json-exit",
      "invariant": "Every --json failure emits exactly one JSON error and obeys usage=1, operation failure=2, needs-login=3.",
      "mechanism": "Packages/RunnerControlCLI/Sources/CLIEntry.swift:43 only adapts CLIFailure; :50 delegates all other errors to ArgumentParser. AppCommands.swift:50 lets URLSession errors reach this fallback.",
      "reproductions": [
        {
          "test_file": "blackbox.py (in TASK-260922-2qddb7_reproductions.zip)",
          "command": "python3 blackbox.py json",
          "expected_failure": "Exit 1: usage-code and JSON-envelope assertions fail.",
          "observed": "Unknown flag, invalid integer, and missing required argument return exit 64 and empty stdout. Custom CLIFailure validation control returns JSON/exit 1.",
          "log": "json.log"
        },
        {
          "test_file": "blackbox.py (in TASK-260922-2qddb7_reproductions.zip)",
          "command": "python3 blackbox.py network",
          "expected_failure": "Exit 1: operational-code and JSON-envelope assertions fail.",
          "observed": "Exact rebuilt CLI copied under a fixture app with loopback feed failure returns exit 1 and empty stdout, instead of JSON/exit 2.",
          "log": "network.log"
        }
      ],
      "severity": "robustness",
      "repeat-of": "none",
      "requested_rework": "Normalize parser and operational errors at the main boundary while handling help/version explicitly. Add subprocess contract tests for unknown flags, bad values, missing arguments, and transport failures; include a narrowing mutant that wraps only CLIFailure."
    }
  ],
  "notes": [
    {
      "id": "coverage-map-missing",
      "text": "No AC-to-driving-test map, surface table or narrowing-mutant evidence was supplied. 0/4 proposal constraint rows have explicit driving-test bindings in the handoff; this does not mean there are no tests. The reviewer derived the surface inventory. Existing test_cli_parity.py checks constants/text, not GUI-effect equivalence; its five checks pass despite the reproduced behavior failures."
    },
    {
      "id": "settings-parity-unverified",
      "text": "AppCommands.swift:306-329 uses System Events login items; Targets/RunnerControl/Sources/LaunchAtLoginModel.swift:9-20 uses SMAppService.mainApp. Shared on/off/status behavior is unverified. Auto-check/auto-update write the defaults suite at AppCommands.swift:266; GUI writes its live Sparkle updater. CLI-to-running-GUI observation was not tested."
    },
    {
      "id": "empty-group-selection",
      "text": "RunnersCommands.swift:471-490 treats --set empty exactly like omitted --set, so source suggests clearing all group repository access is unavailable. No safe full-command authenticated fixture was supplied; not promoted to a blocking finding."
    },
    {
      "id": "retry-and-remove-outcome",
      "text": "RegisterCommand always begins a new draft and traverses the pipeline. Equivalence to GUI retry/apply-labels after an existing registration remains unverified. RunnersCommands.swift:265 suppresses catalogError after removeFromApp even though Runners+Flow.swift:333 also uses it for persistence failure. No live runner mutation was attempted; these are unresolved notes, not reproduced findings."
    },
    {
      "id": "keychain-platform-bound",
      "text": "The preservation fix for unreadable token keeps the identity (six selected Core tests include this check). SecurityKeychainBackend.load at GitHubKeychainStore.swift:79-89 still converts every OSStatus failure to nil and has no UI-suppression option. The new any-team silent-access comment at :59-67 is not established by attached platform evidence. Real same-team/cross-team access, locked/denied reads, and CLI-to-GUI session propagation remain unknown. Existing dev app/helper codesign verification proves signatures only."
    },
    {
      "id": "lease-scope-and-duration",
      "text": "CLIInstallerService.install/uninstall and privileged scripts contain no flock, although proposal.md explicitly requires a PATH symlink installer lease. The added lock is in RunnerInstallerService for runner installation. Holding that lock name in a temporary PATH directory did not block self-install; no PATH lock filename was specified, so that probe is supporting evidence only. RunnerInstallerService.swift:230-231 also closes the synchronous probe before setup/recovery writes; no deterministic cross-process write-window race was run."
    },
    {
      "id": "test-scope",
      "text": "Reran CLI 18/18, selected Core 6/6, parity pins 5/5, release packaging 12/12. Did not claim producer Core 269/269 or Python 97/97 as rerun. Full Core suite was deliberately excluded because GitHubTransportTests.swift:347 realKeychainBackendRoundTripsUniqueRecord creates/deletes real Keychain items, contrary to this review guardrail. Release harness stubs external tools, proving routing/refusal control flow only. No actual release/notary submission was performed."
    }
  ]
}
```

## Candidate identity

```json
{
  "Packages/RunnerControlCLI/Package.resolved": "f66e5f81a8f53a23d2494cdd7fe04227ddd617395d30c60df4c105e99f5929c9",
  "Packages/RunnerControlCLI/Package.swift": "744e24ab156a354654cf67e0d4d208458af4b1cbf112c2b17f8618e5eb80b1ee",
  "Packages/RunnerControlCLI/Sources/AppCommands.swift": "13e2a45f9a3b9c7d6b5e43d29803cc36e43299f2fcccdc2bcda56c4f13217a20",
  "Packages/RunnerControlCLI/Sources/AuthCommands.swift": "903f827168e7e164107336a4642b05ad0d188197dc324f1f0b29ca8bd674917e",
  "Packages/RunnerControlCLI/Sources/CLIConfig.swift": "1644962abf810557adbde3a2a063e9842eed39d6dab2198bfea581953d810690",
  "Packages/RunnerControlCLI/Sources/CLIEntry.swift": "c8d4785b9f8d775f5e88c81cb8308fcc465e2bd3314da7c1c6405c3270accbb6",
  "Packages/RunnerControlCLI/Sources/DTOs.swift": "f260179a7085868d298086dcff9f96066e95cc591b68a3be2e3b37ef960344b2",
  "Packages/RunnerControlCLI/Sources/HeadlessRuntime.swift": "c42201c3291d098295c78c11784658b94405aff1de14fc9a3c5dd2afaac86a4f",
  "Packages/RunnerControlCLI/Sources/Output.swift": "a8dc97c35785e09422ecd4320e236b0d9a0eee321cf77260ee5f3bb99633ff4c",
  "Packages/RunnerControlCLI/Sources/RegisterCommand.swift": "50aced9cec0be8bd3b684427c97ca5d0ae8985b3676e01e12a55cc50dc72646c",
  "Packages/RunnerControlCLI/Sources/RunnerMatching.swift": "14030e7c48a750c02b395d61fea38449f1e8fe74aa380cc70c65b9b9151eadad",
  "Packages/RunnerControlCLI/Sources/RunnersCommands.swift": "ef93ebbe2d380212b886e2e1e3395d5283c4dfafdc17450999a8204d2a6e7498",
  "Packages/RunnerControlCLI/Tests/CLITests.swift": "091fa450dd8534602b1ddb0f06e12ea0dec70e64448e36c78696196204aaf08d",
  "Packages/RunnerControlCore/Sources/CLIInstallerService.swift": "37b5398469788957cf9143e39e248b847c16368638691bdd35ff01e18c1c2d66",
  "Packages/RunnerControlCore/Sources/GitHubAuth+Flow.swift": "158461280c4e0da1d117c055c1e2c918ab8a1490ffd002bd9ddc957c94c333a2",
  "Packages/RunnerControlCore/Sources/GitHubKeychainStore.swift": "f008a4b770b1028e410653648f6177979b0e91428ee9845d23ebe3ff6e0ab618",
  "Packages/RunnerControlCore/Sources/RunnerInstallerService.swift": "020addac3b6f80013ed90f3f995c8f309b78156315ca208cc9e58214e090743b",
  "Packages/RunnerControlCore/Sources/RunnerRuntime.swift": "e05b4cd4b631cba1fb907820e81bddcc638a09801dc8ced78ad0eef8511b5c94",
  "Packages/RunnerControlCore/Tests/CLICompanionTests.swift": "7af1819f1de3ca2caab31d17743cd492381b414212b08d7d821d07ebbf16da29",
  "Packages/RunnerControlCore/Tests/GitHubAuthFlowTests.swift": "f0d42c61257b89543d50d0f2d450ac0a84df0f4d109096c43c2d44b9057c6bd4",
  "Scripts/build-cli.sh": "251ec97186a2dcce7a67a60ee57c17f9e60ef64eb8e15dd96c84d5dd2965da22",
  "Scripts/build.sh": "24d08a80312a4ffa63e35a8155e37b384f48ee5327bc6a8d416e1971409881e7",
  "Scripts/release.sh": "9d447dbf09361c835c47a8674d8966562d5d274cf3537f92029cc266f515ebec",
  "Scripts/resolve-identity.sh": "9ed954086548dc077bc83a1471d9aef5f620d3c705e0e1fd66ec6c3cc4f59502",
  "Scripts/tests/test_cli_parity.py": "98b868cf05e08f14ec53d980e44a8e6610b47e2548cfbbb039b34263dc128bc6",
  "Scripts/tests/test_release_packaging.py": "02018518a65af1ec4dc0f4ced157a6be0649e87e6cf69cac67f3f7bf9148d538",
  "Targets/RunnerControl/Sources/CLIInstallModel.swift": "8e07847be9259a6cd07cc2f5355955bad6cc18a214c80c4b1d47a2954ec39fc4",
  "Targets/RunnerControl/Sources/ManagementWindowContainer.swift": "0a6695dda52f9c2bacd8effba4ac06499e867a4f33a6538e8ac78f28f0c9183f",
  "Targets/RunnerControl/Sources/ManagementWindowPage+Props.swift": "55d65f8acbed7825ad9c3889c5e1347ca70774674eda3df3b46cac645b1b4303",
  "Targets/RunnerControl/Sources/ManagementWindowPage.swift": "9e48ab414b9ec2c5a7cd84125c0b1e9a8f80925d78ce1ce2d9a01b1531986d65"
}
```
