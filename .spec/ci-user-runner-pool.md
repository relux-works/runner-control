# Spec: dedicated-user CI runners controlled from runner-control

Status: build specification, v1. Derived from `DESIGN.md` (same directory). Where the two differ, this spec wins; each deliberate difference is marked **[spec-added]** and listed in section 6.2 for owner acknowledgement.

Audience: an independent developer who has not seen the design discussion. Read this file top to bottom, then `DESIGN.md` only for rationale and evidence.

Repositories involved (both PUBLIC, see section 7):

| Short name | Repository | Role |
| --- | --- | --- |
| `skill` | `skill-macos-ci-runner`, base tag v0.1.0, target v0.2.0 | root-owned host policy and control plane (bash) |
| `rc` | `runner-control` (macOS menu-bar app, embedded CLI, Sparkle updates), base 1.3.0 | helper, core, UI, CLI, release |
| `gen` | `skill-ios-app-manager` | generator that emits runner-control's `Project.swift` (needed by WP3) |

---

## 1. Goal, non-goals, conventions

### 1.1 Goal

Let the owner of a Mac run GitHub Actions runners as **dedicated, unprivileged, headless OS users** (system LaunchDaemons with `UserName=<ci-user>`), and switch them on and off from the runner-control menu bar and CLI, with these properties:

1. No GUI login of the CI user is needed, now or after reboot.
2. The only root code is skill-installed, owner-reviewed and hash-pinned. runner-control ships through Sparkle and Developer ID, so a compromised runner-control release must reach at most "toggle allowlisted CI runners", never root.
3. "Off" is the default and the easy direction. Disable drains by default; enable needs a session-owner authorization.
4. CI jobs reach loopback only on their own sockets (pf), and fork pull requests are refused by the job-started hook, not by workflow YAML.
5. Desired state survives app quit, Sparkle update and reboot.

### 1.2 Non-goals

- No iOS/XCUITest lane: it stays in the v0.1 GUI-session model (`RUNNER_MODE=gui`, unchanged).
- No creating or unregistering dedicated runners from runner-control (the skill does it).
- No migration of owner-account runners (they stay managed by the existing `LaunchAgentService`, unchanged).
- No root helper inside the app bundle, and no root-plus-privilege-drop variant (rejected, see 4.1).
- No VM-per-job runner (a possible fallback of gate G2, not built here).
- No change to the consumer repository's workflows (that is a separate lane).
- No GitHub-side automation of runner groups or settings beyond what runner-control already does.

### 1.3 Configuration parameters (never hardcode)

Every host- or org-specific value is a parameter. Code, tests, fixtures and docs use these placeholders or obvious dummies (`example-org`, `example-repo`, uid `60001`), never real values.

| Parameter | Meaning | Source |
| --- | --- | --- |
| `<support>` | root-owned support tree of one lane | `SUPPORT_ROOT` in `ci-runner.conf` |
| `<prefix>` | reverse-DNS prefix of daemons, logs, pf anchor files | `LABEL_PREFIX` |
| `<lane>` | lane name, `^[a-z0-9][a-z0-9-]{0,31}$` | config |
| `<id>` | instance id, same charset; `<id>` must never equal any `<lane>` | config |
| `<owner-uid>` | uid allowed to call the helper | `registry.conf` (`owner_uid`), written by `host` from `OWNER_UID` |
| `<team-id>` | Apple Developer Team ID in the code-signing requirement | read from runner-control's `ios-app-manager.json` (`team_id`) at build time; the helper never has it as a second literal |
| `<app-id>`, `<cli-id>` | signing identifiers of the app and the embedded CLI | `ios-app-manager.json` (`bundle_id`) and the CLI target config |
| `<service-user>` | helper's non-root account, default `_rcctl` | `registry.conf`/skill config |
| `<right>` | authorization right name, `<prefix>.enable` style | skill config, mirrored in `registry.conf` |
| `<vol>` | CI volume mount point | `VOL_NAME` |
| `<ci-user-prefix>`, `<uid-base>`, `<gid-base>` | per-instance accounts | `CI_USER_PREFIX`, `CI_UID_BASE`, `CI_GID_BASE` |
| `<org>`, `<group>`, `<repo>` | GitHub org, runner group, `owner/repo` served by the lane | config |

A test in each repo must fail if a real value from the design (host names, real usernames or uids, Team ID literals outside `ios-app-manager.json`, repository names) appears in a committed file other than the single source above. Use a deny-list file kept outside the repository, passed in by the developer at test time, plus a repository-local generic regex for IPv4 addresses and `/Users/<name>` paths.

### 1.4 Language and tooling constraints

- Skill scripts: bash 3.2 compatible (macOS `/bin/bash`), stock tools only, strict KEY=VALUE configs parsed never sourced, unknown keys refused, `env -i` re-exec for root entry points. Tests extend `tests/run.sh` (PASS/FAIL/SKIP counters; a test that cannot run is SKIP, never PASS).
- runner-control: Swift 6, macOS 14 minimum, Relux architecture as in the existing code, **Swift Testing** (not XCTest). Release scripts keep their existing Python `unittest` tests. `Project.swift` and the SwiftPM `Package.swift` files are generated: change the generator and its config, never the generated files by hand.
- A negative test asserts the specific refusal (reason code, exit code, post-state), never "any error". Each negative test sits next to a positive control so that "reject everything" fails. Every test carries a one-line comment stating the claim it proves.

---

## 2. Work packages

Estimates in LU (1 LU = producer + owner review + independent review + one fix round + landing, about 3 wall hours). Gate spikes are inside the owning package's estimate and run first.

| WP | Name | Repo | LU | Depends on |
| --- | --- | --- | ---: | --- |
| WP0 | Contract and shared fixtures | skill + rc | 0.5 | none |
| WP1 | Skill control plane: `ci-runnerctl`, `ci-supervisor`, registry, sudoers, right | skill | 1.5 | WP0, WP2a |
| WP2 | Skill host policy (split below) | skill | 6.5 | WP0 |
| WP2a | Daemon mode, harden-then-register, system-domain session checks | skill | 2.0 | WP0 |
| WP2b | Multi-instance: users, rendering, baselines, shared volume | skill | 1.5 | WP2a |
| WP2c | pf self-only loopback, `pf.ready`, Q2 probes (**contains gate G2**) | skill | 1.0 | WP2a |
| WP2d | Hook trust, drain refusal, CLT toolchain mode, `HOST_PROFILE=personal` | skill | 1.5 | WP2a |
| WP2e | Home and cache policy, root-installed rustup | skill | 0.5 | WP2b |
| WP3 | runner-control helper and generator support (**contains gate G1**) | gen + rc | 2.5 | WP0 |
| WP3a | Generator: bundled helper daemon target | gen | 1.0 | none |
| WP3b | Helper: SMAppService, XPC, signing/uid/auth checks, sudo spawn | rc | 1.5 | WP0, WP3a |
| WP4 | Core and UI: model, composite service, menu, window, CLI `ci` | rc | 2.5 | WP0 (WP3b for end-to-end only) |
| WP4a | Core model, `PrivilegedRunnerService`, composite, reducer, observer mapping | rc | 1.5 | WP0 |
| WP4b | Menu and window UX, disable dialog, approval flow, CLI parity | rc | 1.0 | WP4a |
| WP5 | Release: sign and notarize helper, Sparkle path, preflight tests | rc | 1.0 | WP3b, WP4b |
| WP6 | Host qualification Q0-Q9 | host (owner + agent) | 1.0 | WP1, WP2, WP3b, WP4b |

Total: 0.5 (WP0) + 1.5 (WP1) + 6.5 (WP2) + 2.5 (WP3) + 2.5 (WP4) + 1.0 (WP5) + 1.0 (WP6) = **15.5 LU** (skill 8.0, runner-control and generator 6.0, contract 0.5, qualification 1.0). Out of scope and not counted: the consumer repository's workflow follow-ups (about 0.5 LU, other lane) and the owner's non-development latency (section 5).

---

### WP0. Contract and shared fixtures (0.5 LU)

Purpose: freeze the interfaces below so WP1, WP3b and WP4a can proceed independently.

Deliverables:

- `skill/references/CONTRACT.md` and `rc/.spec/ci-control.md`, both containing sections 2.1 to 2.4 of this spec verbatim as the normative text.
- `fixtures/ci-runnerctl/1/` in both repos, byte-identical, containing valid and invalid JSON documents for every output in 2.1.4, plus valid/invalid `instances.conf` and `registry.conf` samples. Each fixture has a sibling `.expect` file (`valid` or `invalid:<reason>`).
- A drift test in each repo: the SHA-256 of the fixture directory manifest equals a pinned value in a `CONTRACT.sha256` file; changing a fixture without bumping it fails.

Acceptance: both a bash validator (skill) and Swift decoders (rc) classify every fixture exactly as its `.expect` says. A contract change after WP0 lands needs the owner's explicit approval and either a new schema suffix (`ci-runnerctl/2`) or a documented additive field.

Tests (positive and negative): every fixture, both implementations; fixture drift test; negative: a fixture with an unknown field, a wrong `schema` string, an out-of-range uid, an id with `../`, an over-long `held_detail`, a lane name equal to an instance id, and each wrong type for each field.

#### 2.1 `ci-runnerctl/1` contract

**2.1.1 Install paths and modes** (written by `host`, verified by `preflight --ioc`; every path is under a root-owned, non-group/other-writable, symlink-free chain)

| Path | Owner:mode | Content |
| --- | --- | --- |
| `<support>/etc/instances.conf` | root:wheel 0644 | per-instance records (2.1.2) |
| `<support>/launchd/<label>.plist` | root:wheel 0644 | runner daemon definition (2.1.5). Not under `/Library/LaunchDaemons`. |
| `<support>/state/<id>.desired` | root:wheel 0644 | exactly `on\n` or `off\n`; missing = `off` |
| `<support>/state/<id>.draining` | root:wheel 0644 | present only while draining; one line, epoch seconds |
| `<support>/state/supervisor.ts` **[spec-added]** | root:wheel 0644 | epoch seconds of the last completed supervisor pass |
| `<support>/state/.lock` **[spec-added]** | root:wheel 0600 | lock file for `/usr/bin/lockf` |
| `/var/run/<prefix>.pf.ready` | root:wheel 0644 | `boot_uuid=<kern.bootsessionuuid>`, `ts=<epoch>`, `anchor_sha256=<hex>`, one per line |
| `<support>/sbin/ci-runnerctl` | root:wheel 0755 | control CLI |
| `<support>/sbin/ci-supervisor` | root:wheel 0755 | reconciler |
| `/Library/LaunchDaemons/<prefix>.supervisor.plist` | root:wheel 0644 | `RunAtLoad`, `StartInterval 10`, kickstartable |
| `/etc/sudoers.d/<prefix>-runnerctl` | root:wheel 0440 | the two lines in 3.1 and nothing else |
| `/Library/Application Support/macos-ci-runner/registry.conf` | root:wheel 0644 | registry (2.1.3). The only file the helper reads. |
| `/var/log/<prefix>.ctl.log` | root:wheel 0644 | audit log (2.1.6) |
| authorization right `<right>` | authorizationdb | rule `authenticate-session-owner`, no credential reuse (timeout 0, `shared` false) |
| user `<service-user>` | uid below 500, no home, shell `/usr/bin/false`, own group, not admin | helper identity |

`host` also records the SHA-256 of `ci-runnerctl`, `ci-supervisor`, and the sudoers file; `preflight --ioc` fails on any mismatch or any sudoers rule for `<service-user>` other than the exact one allowed in 3.1.

**2.1.2 `instances.conf`** (per lane). Records are blocks of `KEY=VALUE` lines separated by one blank line; the first line of a block is `id=<id>`. Parsed, never sourced. Comments only on their own `#` lines. Unknown key, duplicate key, missing key, trailing spaces, quotes or a charset violation refuse the whole file (`manifest-damaged`).

| Key | Charset / rule |
| --- | --- |
| `id` | `^[a-z0-9][a-z0-9-]{0,31}$`, unique, never equal to the lane name |
| `ci_user` | `^[a-z_][a-z0-9_-]{0,31}$`, unique |
| `uid` | integer 501..65000, unique, never equal to `owner_uid` |
| `label` | `^[A-Za-z0-9._-]{1,128}$`, unique, starts with `<prefix>.` |
| `runner_dir` | absolute path, no spaces, no `..`, under `<vol>` |
| `runner_name` | `^[A-Za-z0-9._-]{1,64}$` |
| `agent_id` | positive integer; read by root from the runner's `.runner` at registration, never at runtime |
| `org`, `group` | GitHub name charset `^[A-Za-z0-9._-]{1,100}$` (group may contain spaces only if a test and a rationale are added; default: not allowed) |
| `labels` | comma-separated, each `^[A-Za-z0-9._-]{1,50}$` |
| `repo` | `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` |

**2.1.3 `registry.conf`**: lines `owner_uid=<int>`, `require_auth_enable=true|false`, `service_user=<name>`, `right=<name>`, and one `lane=<lane> ctl=<abs path>` line per lane. Same strictness as 2.1.2. `ctl` must equal `<support>/sbin/ci-runnerctl` of that lane.

**2.1.4 Verbs and output** (the whole privileged API; argv is the only input; `env -i` re-exec; no stdin)

```
ci-runnerctl list
ci-runnerctl status  [<id>|<lane>]
ci-runnerctl enable  <id>|<lane>
ci-runnerctl disable <id>|<lane> --drain
ci-runnerctl disable <id>|<lane> --interrupt
ci-runnerctl cancel-drain <id>|<lane>
ci-runnerctl events  <id> [--lines <1..50>]        [spec-added]
(all verbs accept a trailing optional  --caller <desc>,  desc matching ^[A-Za-z0-9._:-]{1,64}$, audit only)
```

Argument validation, applied before any state is read: verb in the fixed set; flags in the fixed set for that verb; target matches `^[a-z0-9][a-z0-9-]{0,31}$` and is an `id` or the `lane` name present in `instances.conf`. No path, plist, user, label, command or signal is ever read from argv.

Success output (stdout, one JSON object, exit 0):

```
{"schema":"ci-runnerctl/1","ok":true,"verb":"<verb>","ts":<epoch>, ...payload}
list   payload: "lanes":[{"lane":L,"instances":[{"id","runner_name","agent_id","org","group","labels":[...],"ci_user","uid"}]}]
others payload: "instances":[<status>]            (events: "events":[{"ts","source":"supervisor|ctl|hook","text"}], text charset ^[ -~]{0,200}$)
<status> = {"id","desired":"on|off","draining":bool,"loaded":bool,"pid":int|null,"last_exit":int|null,
            "busy_local":bool,"held":[<reason>...],"held_detail":{<reason>:"<=200 printable ASCII>"},
            "supervisor_age_s":int,"ts":int}
<reason> in: pf-not-ready | volume-locked | volume-mismatch | disk-low | gui-session | manifest-damaged
```

Refusal output (stdout JSON, exit 2): `{"schema":"ci-runnerctl/1","ok":false,"reason":"<code>"}` with `<code>` in `bad-argv`, `unknown-target`, `not-draining`, `supervisor-stale`, `host-policy-damaged`, `lock-timeout`. Internal error: exit 1, `{"schema":...,"ok":false,"reason":"internal"}`, no state change.

Verb semantics (every state change takes `/usr/bin/lockf -t 10` on `<support>/state/.lock`, writes via temp file + `mv`, then kickstarts the supervisor `launchctl kickstart system/<prefix>.supervisor`):

| Verb | Effect | Waits |
| --- | --- | --- |
| `status`, `list`, `events` | read only; never write state | no |
| `enable T` | `desired=on`, clears `draining` (idempotent: on an already-draining target it is equivalent to `cancel-drain`) | up to 15 s for a fresh supervisor pass, then returns status |
| `disable T --drain` | `desired=off`; sets `draining` only if the instance is loaded; otherwise just `desired=off` | returns status (draining or off) |
| `disable T --interrupt` | `desired=off`, clears `draining`; the supervisor boots out and terminates the UID | up to 15 s |
| `cancel-drain T` | allowed only while `draining` exists, else refuse `not-draining`; sets `desired=on` then removes `draining` | no |

`enable` is refused with `supervisor-stale` when `supervisor_age_s > 30`; `disable` is always recorded, even when the supervisor is stale. Lane targets apply to every instance of the lane and return one status per instance; a lane-wide request is all-or-nothing on validation, per-instance on effect.

**2.1.5 Runner daemon definition (model A)**

```
Label                 <label>
ProgramArguments      [<runner_dir>/runsvc.sh]        root-owned (from harden-runner)
UserName, GroupName   <ci_user>                       InitGroups true
WorkingDirectory      <runner_dir>
EnvironmentVariables  ACTIONS_RUNNER_SVC=1, HOME=<vol>/home/<ci_user>
SessionCreate true    ProcessType Standard    Nice 10
RunAtLoad true        KeepAlive false
StandardOutPath / StandardErrorPath  under the CI home, Library/Logs/<label>/
```

**2.1.6 Audit log line** (append only, one per verb call, including refusals): `<ISO-8601 UTC> sudo_uid=<SUDO_UID> caller=<desc|-> verb=<verb> target=<t|-> result=<ok|refused:<reason>|error>`.

**2.1.7 Drain semantics.** Request sets `desired=off` + `draining`; the supervisor keeps the runner loaded; a running job (`Runner.Worker` process of that uid) finishes, including the job-completed hook; a job assigned during drain is refused by the job-started hook with an error line (`runner is draining; re-run later`) before repository code runs; after two idle samples one second apart the supervisor boots the runner out, terminates the UID and removes `draining`. Interrupt boots out at once and terminates the UID.

**2.1.8 XPC protocol (helper) `protocolVersion "1"`** (shared Swift types in a small SwiftPM package `RunnerControlCIKit`; the helper links only this package, not the whole core)

Request (NSSecureCoding class): `protocolVersion: String` (must be `"1"`), `verb: String` in `list|status|enable|disableDrain|disableInterrupt|cancelDrain|events`, `lane: String?`, `instance: String?`, `authorization: Data?` (exactly 32 bytes, `AuthorizationExternalForm`), `lines: Int?` (1..50, `events` only). All strings at most 64 bytes, charset as in 2.1.2. `instance` requires `lane`. Absent `lane` means "all lanes" for `list`, `status`, `enable`, `disableDrain`, `cancelDrain` (never for `disableInterrupt` and `events`).

Reply (NSSecureCoding class): one `Data` holding UTF-8 JSON `{"protocolVersion":"1","helperVersion":"x.y.z","ctlSchema":"ci-runnerctl/1","ok":bool,"reason":<HelperReason>|null,"lanes":[{"lane":L,"ok":bool,"reason":<HelperReason|ctl reason>|null,"payload":<validated ctl JSON>|null}]}`. One lane's failure must not hide other lanes' results.

`HelperReason`: `bad-request`, `oversized-field`, `unknown-lane`, `auth-required`, `auth-denied`, `host-policy-missing`, `ctl-chain-invalid`, `ctl-timeout`, `ctl-output-invalid`, `ctl-refused`, `ctl-failed`, `uid-mismatch`. A connection that fails the code-signing requirement is invalidated by the OS before any message and gets no reply.

---

### WP1. Skill control plane (1.5 LU, skill)

Scope: `scripts/ci-runnerctl`, `scripts/ci-supervisor`, their installation by `host-prep.sh host`, the `<service-user>`, the sudoers drop-in, `registry.conf`, the authorization right, the audit log, `preflight --ioc` rule I3, and the shared functions library the tests extract from.

Interfaces: everything in 2.1.1 to 2.1.7. Supervisor entry points: run by launchd every 10 s, at load, and on kickstart.

**States and transitions (per instance)**

| State | desired | draining | loaded | Meaning |
| --- | --- | --- | --- | --- |
| Off | off | no | no | |
| Starting | on | no | no | safe, bootstrap pending |
| Held | on | no | no | not safe; `held` non-empty |
| Idle | on | no | yes | no `Runner.Worker` |
| Busy | on | no | yes | `Runner.Worker` present |
| Draining | off | yes | yes | |

Supervisor decision (pure function `ci_decide desired draining loaded safe idle2` returning one action; the first matching row wins):

| # | Condition | Action |
| --- | --- | --- |
| 1 | loaded and not safe | bootout, terminate UID, log `held: <reasons>` |
| 2 | draining and loaded and idle2 (two idle samples, 1 s apart) | bootout, terminate UID, remove `draining` |
| 3 | draining and loaded and not idle2 | wait |
| 4 | draining and not loaded | remove `draining` |
| 5 | desired on and safe and not loaded | `launchctl bootstrap system <support>/launchd/<label>.plist` |
| 6 | desired off and not draining and loaded | bootout, terminate UID (interrupt path) |
| 7 | otherwise | no-op |

`safe` = pf.ready fresh (age below 90 s, `boot_uuid` equals the current boot session) and pf-assert flags clear, and CI volume UUID equals the recorded one and is mounted at `<vol>` (no `<vol> 1`), and Data free at least 25 GiB, and no `gui/<uid>` domain, and the `instances.conf`/plist/state ownership chain intact and state files valid (a `draining` file with `desired=on` is invalid). Each failed term maps to exactly one `held` reason (`pf-not-ready`, `volume-locked` or `volume-mismatch`, `disk-low`, `gui-session`, `manifest-damaged`). `busy` = a process of that uid whose command name is exactly `Runner.Worker` (root `ps -U <uid> -o comm=`). `terminate_uid`: `sudo -u <ci_user> /bin/kill -TERM -1`, wait 10 s, `-KILL -1`, verify `ps -U <uid>` is empty; never pattern kills, never another uid. The supervisor never changes `desired`, and writes `supervisor.ts` after each pass.

**Error and refusal cases**: all codes in 2.1.4; additionally a damaged `instances.conf` makes every verb except `status` refuse with `host-policy-damaged`, and `status` return `held: [manifest-damaged]` for all known ids (or an empty list if ids are unknowable).

**Acceptance criteria**

1. Every verb produces output matching the WP0 fixtures; refusals have exit 2 and the specified reason; no refusal changes any state file.
2. Reboot with `desired=on`: nothing starts until pf.ready and the volume conditions hold; then the instance bootstraps without owner action.
3. `sudo -l -U <service-user>` shows exactly the rule in 3.1; `preflight --ioc` accepts it and rejects any broader rule (`ALL`, wildcards, extra commands, `SETENV`, other users).
4. Drain with a running job finishes the job, then bootout; a job assigned during drain is refused by the hook (verified in WP6/Q4).

**Required tests** (shell, offline, in `tests/run.sh`; functions extracted with the existing `fn` helper; system tools stubbed)

Positive: argv table accepts every valid verb/flag/target form; `ci_decide` returns the specified action for every row; each `held` reason is produced by its own failing term in isolation; `enable` on a lane returns one status per instance; `cancel-drain` while draining restores `on`; idempotency of repeated `enable`/`disable --drain`; atomic write (kill between temp write and `mv` leaves the old state); two parallel mutations serialise through the lock.
Negative (each asserts exit code, `reason`, and that the state directory is byte-identical afterwards): unknown verb; unknown flag; missing target; target with `../`, `;`, backtick, `$()`, newline, NUL, unicode, leading `-`, 33 characters, uppercase; target that is a path; unknown id; lane/id name collision; `--drain` and `--interrupt` together; `--lines 0`, `51`, non-numeric; `--caller` with spaces or 65 characters; `cancel-drain` when not draining; `enable` with stale supervisor (age 31 s) while `disable` still succeeds; lock held by another process for more than 10 s gives `lock-timeout`; damaged state file (`maybe\n`, empty, CRLF, extra line) gives `manifest-damaged` and no start; `instances.conf` with duplicate uid, uid equal to `owner_uid`, unknown key, quote, space, `..` in `runner_dir`; sudoers broader than allowed; `ci_decide` never returns a start action for any not-safe input (exhaustive over the boolean inputs); env contamination test (`LD_*`/`DYLD_*`/`PATH`/`BASH_ENV`/`IFS` set by the caller have no effect after `env -i` re-exec).
Instrument control: a planted variant of `ci-runnerctl` that skips target validation must make the `../` negative test fail (proves the table detects it).

---

### WP2. Skill host policy (6.5 LU, skill; sub-packages may run in parallel after WP2a)

All new config keys go in `examples/ci-runner.conf` with parser tests (negative: unknown key, overlapping UID ranges, `INSTANCES=0` or above 8, `RUNNER_MODE` not in `daemon|gui`, `CI_UID_BASE` below 501 or colliding with `OWNER_UID`, `TOOLCHAIN` not in `clt|xcode`). Default `RUNNER_MODE=gui` keeps v0.1 behaviour byte-compatible (the existing tests must still pass unchanged). Docs: update `references/DESIGN.md`, `RUNBOOK.md`, `PITFALLS.md`, `SKILL.md`, `CHANGELOG.md` (v0.2.0). All five sub-packages land as separate PRs.

#### WP2a. Daemon mode (2.0 LU)

Interfaces: `RUNNER_MODE=daemon`; runner plist per 2.1.5 placed in `<support>/launchd/`; `session_check` asks for `system/<label>` and `user/<uid>`, refuses on `gui/<uid>`; pf-assert's disk guard boots out whichever domain holds the runner; new RUNBOOK order without any GUI login: `host`, `harden-runner` (root verifies the runner tree), then `host-prep.sh register <id>`.

`register <id>`: root-run; reads the registration token from **stdin only** (never argv, env or a file), runs the root-owned `config.sh` as `<ci_user>` via `sudo -u`, then reads `agent_id` and name from `.runner` once and writes the record into `instances.conf`. If `config.sh` does not accept a piped token, fall back to a masked TTY prompt (recorded in PITFALLS as the Q0 outcome).

States: instance lifecycle `unregistered -> registered(off)`. Refusals: register on a non-hardened runner tree; unknown id; id already registered; empty or oversized token (more than 256 bytes); token containing whitespace or control characters; `RUNNER_MODE=gui`.

Acceptance: first bootstrap from `<support>/launchd/` works with `UserName` set and no login (**spike S-R3, first hour**: `launchctl bootstrap system <plist outside /Library/LaunchDaemons>` with `UserName` and `SessionCreate` runs the process as the dedicated uid; if not, stop and report: it changes the plist location decision).
Tests: config parser; plist renderer golden test; `session_check` decision table (system/user/gui combinations); register: token never in the stubbed `ps`/argv/env capture, rejected inputs leave `instances.conf` untouched; v0.1 `gui` mode golden outputs unchanged.

#### WP2b. Multi-instance (1.5 LU)

Interfaces: `INSTANCES`, `CI_USER_PREFIX`, `CI_UID_BASE`, `CI_GID_BASE`; instance `n` gets `<ci-user-prefix><n>`, uid and gid `base + n - 1`; per-instance runner dir, baseline, hooks rendered per instance, one shared encrypted volume with the quota/reserve keys from `ci-runner.conf` (quota is immutable after creation; values in section 6.1).

Refusals: any computed uid/gid in use, equal to the owner uid, or below 501; user exists but with a different home/shell/group (never reuse a foreign account); primary group `staff`; quota below the hook floor formula in the config comments; `INSTANCES` change after creation without `teardown`.

Tests: renderer golden files for N=1, 3, 4; uid/gid arithmetic table; collision negatives (existing account, owner uid, staff group); idempotent re-run; per-instance baseline isolation (instance 2's baseline untouched by instance 1's changes).

#### WP2c. pf self-only loopback (1.0 LU) and gate G2

Intent per instance (uid `U`, tag `CI<U>`):

```
pass  out quick on lo0 proto { tcp udp } all user U tag CI<U> keep state
block drop in quick on lo0 tagged CI<U> user != U
IPv6: only ::1 under the same self-only rule; every other IPv6 blocked; public IPv4 as v0.1
```

`pf-assert` writes `/var/run/<prefix>.pf.ready` on each successful pass and must run at least every 30 s (the current interval must be verified and shortened if longer); `ci-supervisor` and hooks require age below 90 s.
`qualify.sh root` gains the Q2 probes below, including the planted control.

**Gate G2 spike (first, 0.5 LU time-box, needs the owner's host for the pf live test; the anchor renderer and its tests do not).** Pass requires all, with positive and negative controls in section 4. The developer builds the renderer and the offline tests in parallel with the spike, but does not integrate `pf.ready` or the probes until G2 passes.

Tests: renderer golden text for N=1, 3; every rule contains exactly the tag and uid of its own instance (no cross-instance reference); negative: duplicate uid, uid 0, missing instance, an instance list containing the owner uid; `pf.ready` writer/reader: stale (91 s), wrong boot uuid, malformed, future timestamp, missing file all give `pf-not-ready`; fresh passes. Probe-script tests with stubbed `nc`/`lsof`: expected verdicts for the six Q2 probes, and a stub that "succeeds" on the CI-to-owner probe must make the script report FAIL.

#### WP2d. Hook trust, CLT mode, personal profile (1.5 LU)

Job-started hook (root-owned, rendered per instance) refusal order, first match wins; every refusal prints one `::error::` line with a stable code and exits non-zero before any repository code runs:

| Code | Refuse when |
| --- | --- |
| `draining` | `<support>/state/<id>.draining` exists, or `<id>.desired` is not `on` |
| `pf-stale` | `pf.ready` missing, stale, or wrong boot session |
| `gui-session` | `gui/<uid>` exists |
| `identity` / `volume` / `foreign-process` / `baseline` / `floor` | the existing v0.1 checks, unchanged |
| `event-missing` | the event file (below) is missing, unreadable, over 10 MiB, or not valid JSON |
| `event-repo` | `repository.full_name` is not exactly `repo` from `instances.conf` |
| `event-type` | event name is not in the allowlist |
| `event-fork` | event is `pull_request` and `pull_request.head.repo.full_name` differs from `repo`, or the head repo is null (deleted fork) |
| `event-mismatch` | event name and event JSON shape disagree (see below) |

Allowlist: `push`, `workflow_dispatch`, and `pull_request` from the same repository. Everything else is refused, including `pull_request_target`, `workflow_run`, `issue_comment`, `schedule`, `repository_dispatch`. The event file is read at the fixed path `<runner_dir>/_work/_temp/_github_workflow/event.json`; the path is not taken from the environment. The event name is taken from `GITHUB_EVENT_NAME` and cross-checked: a `pull_request` name requires a top-level `pull_request` object; `push` requires a top-level `ref` and no `pull_request`; `workflow_dispatch` requires no `pull_request`. JSON is read with `plutil -extract` (no `eval`, no shell interpolation of values; values are compared as quoted strings).

**Prerequisite check C-EV (first hour of this package):** with the pinned runner version, confirm that at job-started hook time the event file exists at that path and `GITHUB_EVENT_NAME` is set. If either is absent, stop and report. Pre-decided fallback (owner to confirm, section 6.2): allow only `push` and `workflow_dispatch`, refuse every pull-request event, until a better source is proven.

Other items: `TOOLCHAIN=clt` pins `DEVELOPER_DIR=/Library/Developer/CommandLineTools`, skips the Xcode re-own and App Store policy, and the hook verifies CLT ownership instead of Xcode; `HOST_PROFILE=personal` keeps sshd `DenyUsers` for all CI users, `PermitRootLogin no`, application firewall stealth, pf anchors with the dead-man switch, pf-assert, manual macOS updates; skips Screen Sharing changes, the owner-session AirPlay requirement, `ci-session-agents`; SMB and no-sleep are owner decisions (6.1), default not applied. Supervisor power assertion: `caffeinate -s` scoped to "any instance busy and on AC power", never held otherwise.

Tests (event verdict function `ci_event_verdict <event_name> <event.json>` over JSON fixtures): allow rows: same-repo push, dispatch, same-repo PR; refuse rows: fork PR, deleted-fork PR (`head.repo` null), `pull_request_target`, `workflow_run`, `issue_comment`, `schedule`, missing file, empty file, malformed JSON, JSON array instead of object, wrong repository (case-different `Repo/Name` too), `repository` missing, name/shape mismatch both ways, 11 MiB file, name with trailing newline, repository value containing shell metacharacters, symlinked event file (must refuse). Draining and `pf-stale` refusals with their positive twins. CLT mode: ownership check passes for root:wheel CLT, fails for a user-owned CLT. Power assertion: started only when busy and AC (stubbed `pmset -g ps`), never otherwise.

#### WP2e. Home and cache policy (0.5 LU)

`CI_HOME_DIRS` (pre-created, baseline-tracked as directories) and `CI_WIPE_DIRS` (emptied by job-completed) as config lists with path-safety parsing (relative to the CI home, no `..`, no absolute paths, no symlinks). `.env` sets `CARGO_HOME` and `RUSTUP_HOME` into the CI home. A root-installed, SHA-pinned `rustup` binary goes on the runner `PATH` (downloaded and verified by root at `host`, hash from config; hash mismatch refuses). Final lists are taken from the home diff of the first Q6 run (consumer-specific values live in the consumer's config, not in the skill defaults).

Tests: list parser negatives (`..`, absolute, empty element, symlink target, duplicate); baseline treats listed dirs as expected and any other new top-level home entry as `baseline` refusal (positive control and negative); job-completed leaves wipe dirs empty and leaves non-listed content untouched; pinned-hash mismatch refuses install.

---

### WP3. runner-control helper (2.5 LU, gen + rc) and gate G1

#### WP3a. Generator support for a bundled helper daemon target (1.0 LU, gen)

Interface: new optional key in the app config (for example `macos.helper_daemons: [{name, bundle_program, plist_name, mach_service, user_name, associated_bundle_identifiers}]`). The generator emits the helper executable target, copies the daemon plist to `Contents/Library/LaunchDaemons/`, embeds the helper at `Contents/MacOS/<name>`, signs it with the same team and hardened runtime, and keeps `Project.swift` generated. Absent key: output byte-identical to today (regression test).
Tests: golden `Project.swift` with and without the key; negative: duplicate names, mach service not reverse-DNS, `user_name` empty, `bundle_program` escaping the bundle, helper without hardened runtime.

#### WP3b. Helper (1.5 LU, rc)

Packaging: `Contents/Library/LaunchDaemons/<helper-plist>` with `BundleProgram=Contents/MacOS/RunnerControlCIHelper`, `MachServices { <mach-service>: true }`, `UserName=<service-user>`, `AssociatedBundleIdentifiers=[<app-id>]`, no `RunAtLoad`. Registered with `SMAppService.daemon(plistName:)`; needs the owner's one-time approval in System Settings, Login Items.

**Gate G1 spike (first, 0.5 LU time-box)**: pass criteria in section 4. Until G1 passes, nothing past the spike is merged.

Connection acceptance (all must hold, in this order; the first failure ends the connection without side effects):

1. OS-enforced code-signing requirement via `NSXPCConnection.setCodeSigningRequirement`:
   `anchor apple generic and certificate leaf[subject.OU] = "<team-id>" and (identifier "<app-id>" or identifier "<cli-id>") and certificate 1[field.1.2.840.113635.100.6.2.6] exists`
2. `connection.effectiveUserIdentifier == owner_uid` from `registry.conf`.
3. Per request: strict decode (secure coding, allowed classes only), size caps, protocol version, verb/field charset (2.1.8).
4. For `enable` when `require_auth_enable=true`: rebuild the `AuthorizationRef` from the 32-byte external form and call `AuthorizationCopyRights` for `<right>` **without** interaction; absent or denied gives `auth-required` or `auth-denied` and nothing runs. Other verbs need no authorization.
5. Execution: resolve `ctl` for the lane from the registry; validate its ownership chain (root:wheel, no group/other write on the file or any ancestor, no symlink, regular file); then `posix_spawn("/usr/bin/sudo", ["-n", ctl, <ctl verb>, <target>, <flag>, "--caller", <helper-built desc>])` with an empty environment, 30 s timeout, 64 KiB output cap, file-backed output (the existing `CommandExecutor` pattern). The `--caller` value is built by the helper from the verified signing identifier and pid, never from client data.
6. Output is parsed and validated against the `ci-runnerctl/1` schema (WP0 decoders) before being returned; anything else is `ctl-output-invalid`.

Other rules: the helper keeps no state, reads only `registry.conf` and the `ctl` file metadata, exits after 5 s without connections, reports `helperVersion` and `ctlSchema`; on mismatch the app shows "helper outdated" or "host policy older than app". It never writes outside its own process memory and never reads CI-owned files.

**Fallback FB1 if G1 fails**: the skill installs a root-owned, hash-pinned copy of the helper binary as a plain LaunchDaemon with `UserName=<service-user>`; helper updates then go through the skill by owner action. Adds about 1.0 LU to WP1/WP2 (spec estimate) and changes WP3b packaging. Root-plus-drop is rejected.

**Acceptance**: from `owner_uid` with the signed app and CLI, each verb round-trips; every negative below is refused with the named reason and leaves `<support>/state` unchanged; the helper process runs as `<service-user>` (not root) in the final build.

**Required tests** (Swift Testing; OS-level pieces behind protocols so they run offline):

- `ConnectionPolicy` pure function over (requirement-satisfied flag, euid, registry): accepts only (true, owner uid); negatives: other uid, owner uid with failed requirement, root uid 0, missing registry, `owner_uid` malformed.
- Requirement string: built from parameters; equals the expected literal for dummy inputs; compiles with `SecRequirementCreateWithString`; negative: a team id containing `"` or whitespace is refused at build time; a test asserts the string is generated from the single config source (no second Team ID literal in the sources).
- Request decoding: every field boundary (63/64/65 bytes, 31/32/33-byte auth data, empty strings, NUL, `../`, unicode, wrong protocol version, unknown verb, `instance` without `lane`, `lane` absent for `events` or `disableInterrupt`, `lines` 0 and 51). Each negative asserts the specific `HelperReason`; each has a positive twin one step inside the boundary.
- Authorization: `enable` without auth data, with 31 bytes, with a ref that the (stubbed) rights check denies, and with `require_auth_enable=false` (allowed); other verbs never invoke the rights check (assert call count 0).
- Execution layer with a fake spawner: argv equals exactly `["-n", ctl, verb, target, ...]`, empty env, no shell; ctl chain validator against a fake filesystem: group-writable ancestor, symlink in the path, non-root owner, wrong mode, ctl is a directory, ctl missing, ctl not the registry path; timeout; 64 KiB+1 output; output that is valid JSON but wrong schema string, extra field, wrong type, nested over-size `held_detail`; non-JSON; exit 2 mapped to `ctl-refused` with the ctl reason; exit 1 to `ctl-failed`.
- Multi-lane: lane A succeeds and lane B fails; both reported.
- Idle exit timer.
- Integration (manual script in WP6/Q5, listed for completeness): unsigned client, other-team client, ad-hoc re-signed copy of the app, uid mismatch.

---

### WP4. Core and UI (2.5 LU, rc)

#### WP4a. Core (1.5 LU)

Interfaces: `Runners.ControllerKind.dedicatedUser`; `PrivilegedRunnerService: RunnerServicing` calling the helper through `RunnerControlCIKit`; `CompositeRunnerService` merging its snapshots with the existing `LaunchAgentService`; `Snapshot` gains `localBusy: Bool?`, `draining: Bool`, `held: [HoldReason]`, `heldDetail`, and a service-level `helperState: approved | requiresApproval | notInstalled | outdated | hostPolicyMissing | unreachable | supervisorStale`. Definitions come from `helper.list()`, never from the catalog or discovery (discovery must not scan other users' homes; the catalog must never persist dedicated entries). GitHub observation reuses `GitHubRunnerObserver.match` with `remoteAgentID` from `agent_id` (local and remote signatures stay separate).

Row state derivation (pure function `RowState.derive`), first match wins:

| Order | Condition | Row state |
| --- | --- | --- |
| 1 | helper `unreachable` or `outdated`, or `hostPolicyMissing` | Unknown (never shown as Off) with the matching message |
| 2 | `requiresApproval` or `notInstalled` | Helper needs approval / Host not prepared |
| 3 | `supervisorStale` | "host supervisor not running" |
| 4 | `draining` | Draining |
| 5 | `desired=on` and `held` non-empty | Held (reason, `heldDetail` text) |
| 6 | `loaded` and `localBusy` | On busy |
| 7 | `loaded` | On idle |
| 8 | `desired=on` | Starting |
| 9 | otherwise | Off |

Invariants carried from the existing spec: a running runner is never shown as stopped; helper unreachable is `unknown`, not `off`; busy comes from the local `busy_local` first, GitHub only enriches (job name).

Tests (Swift Testing): `RowState.derive` full table, one positive per row and one negative per priority ("held outranks busy", "draining outranks held", "helper unreachable never yields Off" etc.); reducer transitions for each action (enable, drain, interrupt, cancel-drain, refresh) including failures (state unchanged on `auth-denied`); composite service: dedicated and owner-account runners keep independent snapshots; a helper failure does not disturb owner-account runners (negative); catalog and discovery never see dedicated ids; observer mapping by `agent_id`, never by name; stale remote data does not alter local state; text from `heldDetail` is stored as plain strings and never executed (a test greps the sources for any process-spawn path reachable from it).

#### WP4b. Menu, window, CLI (1.0 LU)

Menu: section "Isolated CI", one pool row per lane with a tumbler (on = enable all instances in the lane via one request, one authorization; off = drain all). Expanding shows instance rows per the derivation table. Action matrix:

| Row state | Actions |
| --- | --- |
| Off | Enable |
| Starting | none |
| On idle | Disable (a drain; immediate when idle) |
| On busy | Disable opens the dialog |
| Draining | Cancel drain, Interrupt now... (confirms) |
| Held | none; shows the remedy text as plain text only |
| Helper needs approval | "Open Login Items" (`SMAppService.openSystemSettingsLoginItems()`) |
| Host not prepared | link to the skill runbook |

Disable dialog: busy gives "Finish current job, then disable" (default), "Interrupt now" (destructive; names the job if known), "Leave on"; idle gives "Disable". "Disable all" covers both runner kinds and always drains dedicated ones; "Enable all" asks for one authorization. Quit and launch change nothing.
Window: read-only details panel (CI user, uid, runner dir, labels, group, last supervisor events via the `events` verb). No create or unregister flow; "Create runner..." explains that isolated runners are installed with the skill.
CLI parity: `runner-control ci list|status|on <id|lane>|off <id|lane> [--interrupt]|cancel-drain <id|lane>|events <id>`, with the existing `--json` and `--yes` conventions (`off --interrupt` requires `--yes` or a TTY confirmation; non-TTY without it refuses, as `runners off` does today). `on` triggers the same authorization prompt; headless with the right not already granted refuses (exit non-zero, message names the missing authorization). DTOs expose stable keys. `Scripts/tests/test_cli_parity.py` style: GUI action set equals CLI command set.

Tests: dialog decision function (busy/idle, known/unknown job name, offline) with a negative that interrupt is never the default and never chosen without confirmation; pool toggle issues exactly one enable request and one authorization prompt for N instances; "Disable all" never sends `disableInterrupt`; Held rows expose no executable action; CLI argument tables (positive and negative: unknown id, `--interrupt` with `on`, missing target, non-TTY without `--yes`); JSON DTO key stability; offline: toggles still work against a stubbed helper while GitHub is unreachable; Quit does not call the helper.

---

### WP5. Release (1.0 LU, rc)

Scope: sign the helper with Developer ID and hardened runtime, notarize with the app, keep the Sparkle path working, and extend release preflight.
Tests (Python `unittest` in `Scripts/tests`, plus Swift constants test): helper plist keys equal expected (`BundleProgram` exists in the built bundle, `UserName` equals the registry default, `MachServices` key equals the Swift constant, `AssociatedBundleIdentifiers` contains the app id); helper and app share the team id from `ios-app-manager.json`; `codesign` verification on the built artifact (script test, SKIP not PASS when no built artifact); constants parity between Swift, plist and config (like `test_cli_parity.py`); negative: unsigned helper, helper without hardened runtime, plist referencing a missing binary, helper team id different from the app, mach service name mismatch each fail preflight with a specific message. Manual (recorded in the PR): update the app over an approved install via Sparkle test feed and confirm no re-approval prompt and the helper still runs as `<service-user>`. No release is cut before gate G1 passes or FB1 is merged.

---

### WP6. Host qualification (1.0 LU, owner + agent)

Run Q0-Q9 from `DESIGN.md` section 7.5 on the target host; each row needs its positive control and its negative control or planted variant to produce the intended result (a skipped or unrelated failure is not a pass). Evidence per row: commands, exit codes, tool versions, timestamps, the exact skill and app versions. `MACOS_SELF_HOSTED` stays unset until all pass. Q2 and Q5 reuse the WP2c and WP3b probe scripts. Failures are filed against the owning WP, not worked around.

---

## 3. Security model as testable invariants

### 3.1 Authority chain

| Actor | Allowed |
| --- | --- |
| Owner uid (`owner_uid`) running the signed app or CLI | call the helper with the closed verb set |
| Any other local user, unsigned or other-team binary, ad-hoc re-signed copy | nothing (connection refused) |
| `<service-user>` (helper) | exactly `sudo -n <ctl> ...` |
| root: `ci-runnerctl`, `ci-supervisor` | the only code that changes desired/drain state, and (supervisor only) the only code that bootstraps or boots out runners |
| CI users | read `<support>/state/*.draining`; nothing else privileged |

Sudoers drop-in, exactly two lines (no other content, no includes):

```
Defaults:<service-user> !setenv, env_reset
<service-user> ALL=(root) NOPASSWD: <support>/sbin/ci-runnerctl
```

Because a sudoers command without an argument list allows any arguments, the argument validation in `ci-runnerctl` (2.1.4) is the control; it is tested as such.

### 3.2 Invariants

| ID | Invariant | Positive test | Negative test | Where |
| --- | --- | --- | --- | --- |
| I1 | Only a client satisfying the code-signing requirement for `<team-id>` and `<app-id>`/`<cli-id>` can connect | signed app and CLI | unsigned, other team, ad-hoc copy, right team wrong identifier | WP3b unit (policy, requirement string), WP6 Q5 |
| I2 | Only `owner_uid` may call | owner | uid 0, other uids, owner with failed requirement | WP3b, Q5 |
| I3 | `enable` requires a fresh session-owner authorization (password or Touch ID); no credential reuse | right granted | absent, short, denied, replayed ref | WP3b, Q5 |
| I4 | `disable`, drain, interrupt, status, list, events need no authorization | each works | (the same calls never invoke the rights check) | WP3b |
| I5 | A request carries only verb, lane, instance, authorization data, small integers; never a path, command, user, label, signal, or environment | valid shapes | any extra or over-size field refused by decoder and by `ci-runnerctl` | WP0, WP1, WP3b |
| I6 | The helper executes only `/usr/bin/sudo -n <registry ctl> ...` with an empty environment; ctl chain is root-owned, tamper-free | clean chain | group-writable ancestor, symlink, wrong owner, wrong path | WP3b |
| I7 | `ci-runnerctl` validates verb and target against root config itself, whatever the helper sent | valid argv | WP1 negative table, fuzz | WP1, Q5 |
| I8 | The sudoers rule allows exactly one command to exactly one account | `sudo -l` | broader rules rejected by `preflight --ioc` | WP1, Q5 |
| I9 | The helper never runs as root and holds no state | process owner check | n/a in unit; Q5 `ps` check | WP3b, Q5 |
| I10 | Only the supervisor starts or stops runners; it never changes desired state | decision table | `ci_decide` never starts when not safe | WP1 |
| I11 | pf: a CI uid reaches loopback only on its own sockets, never LAN, tailnet or global IPv6 | CI to own 127.0.0.1 and ::1 | CI to owner, root service, other CI instance; planted rule removal flips CI-to-owner to success | WP2c, Q2 |
| I12 | The job-started hook refuses fork PRs, disallowed events, missing or malformed event data, wrong repository, draining, stale pf | allowed events pass | refusal table in WP2d | WP2d, Q3 |
| I13 | Desired state and drain survive app quit, Sparkle update, helper exit and reboot | state files persist | Quit never calls the helper | WP1, WP4b, Q4 |
| I14 | "Unknown" is never rendered as "Off"; a running runner is never shown as stopped | table | helper unreachable case | WP4a |
| I15 | The app never executes remedy text from the host | n/a | static check, held rows have no action | WP4a/WP4b |
| I16 | No secrets in repositories, logs, argv or env; registration token only via stdin | token capture stub | token never in `ps`/env in tests and Q0 | WP2a, Q0 |
| I17 | Every verb call is audited, refusals included | log line present | refusals also logged, log not writable by non-root | WP1 |

---

## 4. Known risks and go/no-go gates

### Gate G1: launchd honours `UserName` for an SMAppService daemon (owner of the spike: WP3b)

Why: if launchd ignores `UserName` for a bundled daemon, the helper would run as root and a compromised runner-control release becomes root-equivalent on every approved host.

Spike (a throwaway app, never merged, same signing class as the release): register a daemon with `UserName=<service-user>` and a debug-only `whoami` verb; owner approves in Login Items.
Pass: (1) process euid is `<service-user>`'s uid, not 0 (checked from outside with `ps`); (2) a negative control plist naming a non-existent user fails to start, proving `UserName` is read; (3) after replacing the app bundle with a newer signed build, the daemon still runs as `<service-user>` with no re-approval; (4) unregister removes it.
No-go: any of (1)-(3) fails. Result: nothing past the spike merges and no release is cut.
Fallback: FB1 (root-owned, hash-pinned helper copy installed by the skill as a plain LaunchDaemon with `UserName=<service-user>`, helpers updated by owner action). Fallback 2 (root plus privilege drop) is rejected.
Owner decision triggered: accept FB1's update path (helper updates through the skill, extra about 1.0 LU), or stop the feature.

### Gate G2: pf loopback self-only tagging on the target macOS (owner of the spike: WP2c)

Why: curator-class test suites need loopback TCP/UDP and IPv6 `::1`; the v0.1 anchor blocks all of it. Opening loopback by port is unsafe because the owner's tools listen on loopback without auth.
Spike pass (all on the target host, with the pf dead-man switch): CI to own listener on `127.0.0.1` and `::1` works; CI to a listener owned by the owner uid refused; CI to a root service (for example sshd on 22) refused; CI instance 1 to instance 2 refused; owner to owner loopback unaffected; LAN, tailnet and global IPv6 refused; and the planted control: with the block rule removed, CI to owner **succeeds** (proving the probe sees the intended write). Also record whether pf tags survive the `out`/`in` passes on `lo0` and whether `user` resolves on the inbound pass.
No-go: any positive fails or any negative succeeds. Stop the line: persist the constraint, evidence and options in the repository's task flow; nothing that depends on loopback ships.
Fallbacks and the owner decision (one of): (1) run the macOS CI in Apple Virtualization VMs (at most 2 concurrent, about 40-60 GiB disk each, bound by the same disk limit); (2) keep macOS CI on hosted runners; (3) self-hosted for loopback-free jobs only (not supported by typical skip-class gates). WP1, WP3, WP4, WP5 remain valid mechanisms but the owner decides whether to keep spending on them.

### Other risks (no hard gate)

| ID | Risk | Check (when) | Fallback / decision |
| --- | --- | --- | --- |
| R3 | launchd bootstrap of a plist outside `/Library/LaunchDaemons` with `UserName` | spike S-R3, WP2a first hour | move plist location (design change, owner informed) |
| R4 | `config.sh` does not read a piped token | WP2a / Q0 | masked TTY paste, recorded in PITFALLS |
| R5 | event file or `GITHUB_EVENT_NAME` absent at hook time | C-EV, WP2d first hour | allow only `push` and `workflow_dispatch` (owner confirms) |
| R6 | model A lacks a per-user service some tests need | Q1 | switch that lane to a per-user Background launchd agent; do not weaken model A |
| R7 | one `AuthorizationRef` may not satisfy several requests with no reuse | WP4b | the "enable all" request is a single helper request (lane absent), so one check; do not rely on reuse across requests |
| R8 | rustup tolerates a read-only home | WP2e (optimisation only) | per-job install into the wiped home |
| R9 | disk floors | owner action before `host` | owner decision (6.1 item 1) |

---

## 5. Ordering, critical path and parallel width

```
t=0   WP0 (0.5) || WP3a (1.0) || G2 spike (0.5, needs host) || G1 spike (0.5, after WP3a not required: throwaway app)
      WP2a (2.0) after WP0 || WP4a (1.5) after WP0
      then in parallel after WP2a:  WP1 (1.5)   WP2c (1.0)   WP2d (1.5)   WP2b (1.5) -> WP2e (0.5)
      WP3b (1.5) after WP0 + WP3a (+ G1 pass);  WP4b (1.0) after WP4a
      WP6 (1.0) after WP1, WP2*, WP3b, WP4b;  WP5 (1.0) after WP3b, WP4b, released after WP6 passes
```

- Parallel width: **3 lanes** (skill A: WP2a, WP1, WP2c; skill B: WP2b, WP2d, WP2e; runner-control: WP3a, WP3b, WP4a, WP4b, WP5). A fourth worker is useful only for the gate spikes.
- Critical path: WP0 (0.5) -> WP2a (2.0) -> WP1 or WP2d (1.5, lane A/B in parallel; lane B also carries WP2b 1.5 -> WP2e 0.5, about 2.0) -> WP6 (1.0) -> WP5 release (1.0) = about **7 LU**. The runner-control lane (WP3a/WP0 -> WP3b -> WP4b, about 3.5-4.5 LU) is shorter and has slack.
- Gate spikes G1 and G2 must start at t=0. A failed gate cancels the dependent work described in section 4.
- CLI-only milestone: after WP0, WP2a-d and WP1 (about 5 LU in), the owner can toggle through `sudo <support>/sbin/ci-runnerctl` without the app.
- Non-development latency, reported separately: owner frees disk (6.1 item 1); owner decisions 6.1; about 2 hours at the target Mac for `host` (Terminal with Full Disk Access) and approvals (Login Items, authorization prompts); the consumer repository owner landing its routing change; stop-the-line decision if G2 fails. None of this is counted in LU.

---

## 6. Open owner decisions

### 6.1 Copied from `DESIGN.md` section 13 (generic wording)

1. **Disk:** free the shortfall on the Data volume before setup and choose the quota (48 GiB for 3 instances or 56 GiB for 4; minimum 32 GiB for 1; the quota cannot be changed after creation). Data free needed before `host`: about 110 GiB (N=3), 120 GiB (N=4), 92 GiB (N=1). The host-specific shortfall is computed by `preflight` (set `MIN_CONTAINER_FREE_AFTER_BYTES` accordingly), not stated in this spec.
2. **pf fallback** if G2 fails: VM lane, hosted runners, or no self-hosted macOS CI.
3. **Laptop sleep:** busy-on-AC power assertion (recommended), `pmset` no-sleep on AC, or nothing.
4. **CI volume unlock after reboot:** manual (default, strongest) or boot unlock from the System keychain.
5. **SMB off** on the host (v0.1 default): yes or no.
6. **Authorization on enable:** `authenticate-session-owner` with no reuse (default) or a short timeout.
7. **Policy exception:** persistent CI runners on the owner's own machine, versus the platform guidance that candidate-code execution belongs on isolated ephemeral runners on another machine.

### 6.2 Added by this spec (owner acknowledgement needed)

1. `events` verb and `--caller` argument, `supervisor.ts` heartbeat, `.lock` file, `held_detail` (needed to deliver the details panel, the remedy lines, `supervisor_age_s` and audit caller without widening the helper's authority).
2. `enable` on a draining instance equals `cancel-drain`.
3. Fallback for hook-time event data (R5): allow only `push` and `workflow_dispatch` until proven.
4. `lane` absent means "all lanes" in helper requests, so "Enable all" costs one authorization.
5. Estimate for FB1 (about 1.0 LU) is the spec author's, not from the design.

---

## 7. Handoff rules for the developer

1. **Public repositories.** `runner-control` and `skill-macos-ci-runner` are public. Everything committed (code, tests, fixtures, docs, commit messages, PR text, CI logs) stays generic: no host names, real usernames or uids, team-internal agent or lane names, IP addresses, internal repository names, local paths such as `/Users/<name>`, Matrix IDs, or screenshots of the host. Use the parameters in 1.3 and dummy values. Host-specific values from `DESIGN.md` (account names and ids, disk figures, repository names) are configuration, supplied by the owner at install time and never committed. Public identifiers already in the repository's own config (bundle id, Team ID in `ios-app-manager.json`) stay there as the single source.
2. **Flow.** Start from the current remote default branch (fetch, fast-forward, verify equal) and make a feature branch per WP or sub-package. Open a PR per branch; the owner reviews and an independent reviewer reads the full remote diff; fix rounds update the same branch; land only after review accepts the exact head and all required checks are green. Never push to the default branch directly, never force it, never bypass checks, and use only the repositories' approved fast-forward landing method so reviewed signed commits are preserved.
3. **Commits.** Every commit and tag is signed with the configured author's key (`git commit -S`, `git tag -s`); verify with `git log --format=%G?` before publishing. Keep the configured human author and committer unchanged. Add a `Co-authored-by` trailer for each distinct system and model that wrote the change with the verified address from the owner's attribution table; never put session links or IDs in commit messages, PR bodies or tags.
4. **No secrets.** No tokens, passphrases, registration tokens, private keys, Sparkle private keys or signing identities in the repository, tests, fixtures, logs or PR text. Registration tokens only via stdin in scripts. Test fixtures use obviously fake values.
5. **Scope.** One WP per PR; do not edit generated files by hand (`Project.swift`, `Package.swift` come from the generator); do not weaken a refusal or a negative test to get green; changes to section 2.1 (the contract) go through the owner. If a gate fails or a prerequisite check (C-EV, S-R3) fails, stop, write the evidence and options into the repository's task or documentation flow, and report; do not improvise a workaround.
6. **No host side effects in tests.** Tests never touch the real host: stub system tools, use scratch directories with absolute physical paths, and run nothing as root. Anything that needs the target host (G1, G2, Q0-Q9) is performed by or with the owner and recorded as evidence, not simulated. Never kill processes by pattern; stop only PIDs you started.
7. **Definition of done per WP:** acceptance criteria met; all listed positive and negative tests present with their one-line claim comments; instrument controls demonstrated where specified; docs and `CHANGELOG` updated; PR reviewed, checks green, landed; the PR body lists commands run, exit codes, tool versions and anything that could not be run (reported as not run, never as passed).
