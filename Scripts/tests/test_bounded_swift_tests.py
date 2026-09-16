"""Bounded hosted Swift tests: wiring and helper behavior.

Production entry points:
- .github/workflows/ci.yml step "Core unit tests (no UI tests or production
  runners)" invokes Scripts/run-bounded-swift-tests.sh with a wall-clock bound.
- Scripts/run-bounded-swift-tests.sh runs the fixed full-suite
  `swift test --package-path ... --scratch-path ...` with live output,
  enforces the timeout, captures owned-process diagnostics on timeout,
  terminates owned processes, and propagates the test exit status.

Wiring tests prove the workflow bounds execution, selects the Xcode 26
toolchain, prints versions, invokes the helper, and carries no
test-selection bypass or credential/runner operations. Behavioral tests
execute the production helper with stubbed swift/toolchain tools and prove
success/failure/timeout paths, live output, cleanup, and argv preservation.
Composed-step tests extract the actual workflow run fields and execute them
under Actions-equivalent bash -e -o pipefail, proving the caller propagates
helper refusal instead of discarding it.
"""
import os
import re
import select
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
import unittest

WORKFLOW = Path(__file__).parents[2] / '.github' / 'workflows' / 'ci.yml'
SCRIPT = Path(__file__).parents[1] / 'run-bounded-swift-tests.sh'

TOOLCHAIN_STEP = 'Select Xcode 26 toolchain and show versions'
CORE_STEP = 'Core unit tests (no UI tests or production runners)'
METADATA_STEP = 'Release metadata tests'

SWIFT_STUB = '''#!/bin/bash
if [ "$1" = "--version" ]; then
  echo "SWIFT-VERSION-STUB-6.3.3"
  exit 0
fi
if [ "$1" = "test" ]; then
  if [ -n "${SWIFT_ARGS_LOG:-}" ]; then
    printf '%s\\n' "$*" >> "$SWIFT_ARGS_LOG"
  fi
  if [ -n "${SWIFT_PID_FILE:-}" ]; then
    printf '%s\\n' "$$" > "$SWIFT_PID_FILE"
  fi
  mode="${SWIFT_MODE:-pass}"
  case "$mode" in
    pass)
      echo "Test run started."
      echo "SWIFT-TEST-LINE-1"
      echo "Test run with 2 tests passed."
      exit 0
      ;;
    fail1)
      echo "Test run started."
      echo "SWIFT-TEST-FAILURE-MARKER"
      exit 1
      ;;
    fail2)
      echo "SWIFT-TEST-FAIL2-MARKER"
      exit 2
      ;;
    hang)
      echo "SWIFT-HANG-STARTED"
      sleep 30
      exit 0
      ;;
    hang_with_child)
      sleep 30 &
      if [ -n "${SWIFT_CHILD_PID_FILE:-}" ]; then
        printf '%s\\n' "$!" > "$SWIFT_CHILD_PID_FILE"
      fi
      echo "SWIFT-HANG-WITH-CHILD-STARTED"
      sleep 30
      exit 0
      ;;
    term_ignoring_child)
      # F1 attack shape: TERM-responsive parent (default action), one
      # descendant that ignores SIGTERM. Group TERM kills the parent, the
      # descendant is reparented (ppid 1) but keeps the owned pgid, so only
      # group KILL reaps it. Tree rediscovery alone loses it. The descendant
      # holds no copy of the helper's stdout pipe, so the harness observes
      # helper exit (and the survivor) instead of blocking on an open pipe.
      python3 -c 'import signal,time,os; signal.signal(signal.SIGTERM,signal.SIG_IGN); f=os.environ.get("SWIFT_CHILD_PID_FILE"); open(f,"w").write(str(os.getpid())) if f else None; time.sleep(60)' >/dev/null 2>&1 &
      echo "SWIFT-TERM-RESPONSIVE-PARENT-STARTED"
      sleep 30
      exit 0
      ;;
    live)
      echo "LIVE-MARKER-IMMEDIATE"
      sleep 5
      echo "LIVE-MARKER-LATE"
      exit 0
      ;;
  esac
fi
echo "swift stub: unexpected args $*" >&2
exit 99
'''

XCODE_SELECT_STUB = '''#!/bin/bash
if [ "$1" = "-p" ]; then
  echo "/Applications/Xcode_26.3.app/Contents/Developer"
  exit 0
fi
echo "XCODE-SELECT-STUB: $*"
exit 0
'''

XCODEBUILD_STUB = '''#!/bin/bash
echo "XCODEBUILD-VERSION-STUB-26.3"
exit 0
'''

SAMPLE_STUB = '''#!/bin/bash
echo "SAMPLE-STUB pid=$1 duration=$2"
exit 0
'''

SUDO_STUB = '''#!/bin/bash
if [ -n "${SUDO_LOG:-}" ]; then
  printf '%s\\n' "$*" >> "$SUDO_LOG"
fi
exec "$@"
'''


def blocks(text):
    starts = [m.start() for m in re.finditer(r'^      - ', text, re.M)]
    return [text[s:e] for s, e in zip(starts, starts[1:] + [len(text)])]


def block_named(all_blocks, name):
    found = [b for b in all_blocks if b.splitlines()[0].endswith(f'- name: {name}')]
    assert len(found) == 1, name
    return found[0]


def write_exe(path, content):
    path.write_text(content)
    path.chmod(0o755)


def step_run_command(name, text=None):
    """Extract the actual run field of a workflow step.

    Reads the production workflow file (not a hardcoded command) so a
    call-site mutant that keeps the script token but discards its exit status
    changes what the composed-step tests execute. Supports both inline and
    block-scalar run fields.
    """
    raw = WORKFLOW.read_text() if text is None else text
    block = block_named(blocks(raw), name)
    lines = block.splitlines()
    run_idx = None
    run_value = None
    for i, line in enumerate(lines):
        matched = re.match(r'\s*run:\s*(.*)$', line)
        if matched:
            run_idx = i
            run_value = matched.group(1).strip()
            break
    assert run_idx is not None, f'{name} run field missing'
    if run_value in ('|', '>', '|-', '|+', '>-', '>+'):
        run_indent = len(lines[run_idx]) - len(lines[run_idx].lstrip())
        collected = []
        for line in lines[run_idx + 1:]:
            if line.strip() == '':
                collected.append('')
                continue
            indent = len(line) - len(line.lstrip())
            if indent <= run_indent:
                break
            collected.append(line)
        non_empty = [entry for entry in collected if entry.strip() != '']
        assert non_empty, 'empty block-scalar run field'
        floor = min(len(entry) - len(entry.lstrip()) for entry in non_empty)
        dedented = [entry[floor:] if entry.strip() != '' else '' for entry in collected]
        while dedented and dedented[-1] == '':
            dedented.pop()
        command = '\n'.join(dedented)
        assert command.strip() != '', 'empty run command'
        return command
    value = run_value
    if len(value) >= 2 and ((value[0] == '"' and value[-1] == '"')
                            or (value[0] == "'" and value[-1] == "'")):
        value = value[1:-1]
    assert value.strip() != '', 'empty run command'
    return value


def helper_timeout_secs(command):
    matched = re.search(r'--timeout-secs[=\s]+(\d+)', command)
    assert matched, 'helper --timeout-secs missing from Core step'
    return int(matched.group(1))


def job_timeout_secs(text):
    matched = re.search(r'timeout-minutes:\s*(\d+)', text)
    assert matched, 'job timeout-minutes missing'
    return int(matched.group(1)) * 60


class CiWorkflowWiringTests(unittest.TestCase):
    def test_job_has_bounded_timeout_minutes(self):
        text = WORKFLOW.read_text()
        matched = re.search(r'timeout-minutes:\s*(\d+)', text)
        self.assertIsNotNone(matched, 'job timeout-minutes missing')
        minutes = int(matched.group(1))
        self.assertGreaterEqual(minutes, 10, 'bound too tight for hosted build')
        self.assertLessEqual(minutes, 20, 'bound too loose; hang must fail fast')
        self.assertLess(text.index('timeout-minutes:'), text.index('steps:'))

    def test_toolchain_step_selects_xcode26_and_prints_versions(self):
        block = block_named(blocks(WORKFLOW.read_text()), TOOLCHAIN_STEP)
        self.assertIn('Xcode_26.3', block)
        self.assertIn('xcode-select -s', block)
        self.assertIn('sudo', block)
        self.assertIn('swift --version', block)
        self.assertIn('xcodebuild -version', block)
        self.assertIn('xcode-select -p', block)

    def test_toolchain_selection_failure_propagates(self):
        command = step_run_command(TOOLCHAIN_STEP)
        self.assertIn('xcode-select -s', command)
        for line in command.splitlines():
            if 'xcode-select -s' in line:
                self.assertNotIn('|| true', line)
                self.assertNotIn('||:', line)

    def test_core_step_invokes_bounded_helper_with_bound(self):
        block = block_named(blocks(WORKFLOW.read_text()), CORE_STEP)
        self.assertIn('Scripts/run-bounded-swift-tests.sh', block)
        self.assertIn('--timeout-secs', block)
        self.assertIn('--package-path', block)
        self.assertIn('--scratch-path', block)
        self.assertTrue(SCRIPT.exists(), 'production helper missing')
        self.assertTrue(os.access(SCRIPT, os.X_OK), 'helper must be executable')
        secs = helper_timeout_secs(block)
        self.assertGreaterEqual(secs, 60)
        self.assertLessEqual(secs, 840)

    def test_helper_timeout_within_job_timeout(self):
        text = WORKFLOW.read_text()
        core_command = step_run_command(CORE_STEP)
        helper_secs = helper_timeout_secs(core_command)
        job_secs = job_timeout_secs(text)
        self.assertLessEqual(helper_secs + 120, job_secs,
                             'helper bound must leave room for diagnostics and metadata tests')

    def test_no_test_selection_bypass_in_workflow_or_helper(self):
        for label, text in (('workflow', WORKFLOW.read_text()),
                            ('helper', SCRIPT.read_text())):
            for token in ('--skip', '--filter', '--disable-', '--only-testing',
                          '--skip-testing', '--skip-build'):
                self.assertNotIn(token, text, f'{token} in {label}')
        body = SCRIPT.read_text()
        self.assertIn('swift test --package-path "$package_path" --scratch-path "$scratch_path"',
                      body)

    def test_no_credential_or_runner_operations_in_workflow_or_helper(self):
        for label, text in (('workflow', WORKFLOW.read_text()),
                            ('helper', SCRIPT.read_text())):
            for token in ('GH_TOKEN', 'GITHUB_TOKEN', 'NOTARY', 'printenv',
                          'security find-identity', 'security unlock', 'gh auth',
                          'launchctl', 'osascript'):
                self.assertNotIn(token, text, f'{token} in {label}')

    def test_step_order_toolchain_before_core_before_metadata(self):
        text = WORKFLOW.read_text()
        positions = [text.index(f'- name: {name}')
                     for name in (TOOLCHAIN_STEP, CORE_STEP, METADATA_STEP)]
        self.assertEqual(positions, sorted(positions))

    def test_helper_preserves_exact_swift_command(self):
        body = SCRIPT.read_text()
        invocations = [line for line in body.splitlines()
                       if line.strip().startswith('swift test ')]
        self.assertEqual(len(invocations), 1)
        self.assertIn('--package-path', invocations[0])
        self.assertIn('--scratch-path', invocations[0])


class BoundedHelperHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        scripts = root / 'Scripts'
        scripts.mkdir()
        target = scripts / 'run-bounded-swift-tests.sh'
        shutil.copy(SCRIPT, target)
        target.chmod(0o755)
        self.helper = target
        self.pkg = root / 'FakePkg'
        self.pkg.mkdir()
        self.bindir = root / 'bin'
        self.bindir.mkdir()
        write_exe(self.bindir / 'swift', SWIFT_STUB)
        write_exe(self.bindir / 'xcode-select', XCODE_SELECT_STUB)
        write_exe(self.bindir / 'xcodebuild', XCODEBUILD_STUB)
        write_exe(self.bindir / 'sample', SAMPLE_STUB)
        self.root = root
        self.args_log = root / 'swift-args.log'
        self.pid_file = root / 'swift.pid'
        self.child_pid_file = root / 'swift-child.pid'

    def tearDown(self):
        self.tmp.cleanup()

    def run_helper(self, *extra, timeout_secs='10', mode='pass', env_extra=None):
        env = dict(os.environ)
        env['PATH'] = str(self.bindir) + os.pathsep + env['PATH']
        env['SWIFT_MODE'] = mode
        env['SWIFT_ARGS_LOG'] = str(self.args_log)
        env['SWIFT_PID_FILE'] = str(self.pid_file)
        env['SWIFT_CHILD_PID_FILE'] = str(self.child_pid_file)
        if env_extra:
            env.update(env_extra)
        argv = ['bash', str(self.helper), '--timeout-secs', str(timeout_secs),
               '--package-path', str(self.pkg),
               '--scratch-path', str(self.root / 'scratch')] + list(extra)
        return subprocess.run(argv, capture_output=True, text=True, timeout=60,
                              env=env, cwd=self.tmp.name)

    @staticmethod
    def pid_alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    @classmethod
    def force_kill_pid_file(cls, pid_file):
        """SIGKILL whatever a pid file names; mutant runs must not leak strays."""
        try:
            pid = int(Path(pid_file).read_text().strip())
        except (OSError, ValueError):
            return
        try:
            os.kill(pid, 9)
        except (ProcessLookupError, PermissionError):
            pass


class BoundedHelperBehaviorTests(BoundedHelperHarness):
    def test_success_propagates_zero_and_streams_output(self):
        r = self.run_helper(mode='pass')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('SWIFT-TEST-LINE-1', r.stdout)
        self.assertIn('Test run with 2 tests passed.', r.stdout)
        self.assertIn('SWIFT-VERSION-STUB', r.stdout)
        self.assertIn('XCODEBUILD-VERSION-STUB', r.stdout)

    def test_failure_exit_1_propagates_no_false_green(self):
        r = self.run_helper(mode='fail1')
        self.assertEqual(r.returncode, 1, f'stdout={r.stdout!r} stderr={r.stderr!r}')
        self.assertIn('SWIFT-TEST-FAILURE-MARKER', r.stdout)

    def test_failure_exit_2_propagates(self):
        r = self.run_helper(mode='fail2')
        self.assertEqual(r.returncode, 2, f'stdout={r.stdout!r} stderr={r.stderr!r}')
        self.assertIn('SWIFT-TEST-FAIL2-MARKER', r.stdout)

    def test_timeout_fails_124_with_diagnostics_and_cleanup(self):
        r = self.run_helper(timeout_secs='2', mode='hang')
        self.assertEqual(r.returncode, 124, f'stdout={r.stdout!r} stderr={r.stderr!r}')
        self.assertIn('TIMEOUT', r.stderr)
        self.assertIn('owned-process ps', r.stderr)
        self.assertIn('SAMPLE-STUB', r.stderr)
        self.assertIn('SWIFT-HANG-STARTED', r.stdout)
        self.assertTrue(self.pid_file.exists())
        pid = int(self.pid_file.read_text().strip())
        deadline = time.time() + 10
        while self.pid_alive(pid) and time.time() < deadline:
            time.sleep(0.2)
        self.assertFalse(self.pid_alive(pid), 'owned swift stub survived timeout cleanup')

    def test_timeout_terminates_descendants(self):
        r = self.run_helper(timeout_secs='2', mode='hang_with_child')
        self.assertEqual(r.returncode, 124, r.stderr)
        self.assertTrue(self.child_pid_file.exists())
        child = int(self.child_pid_file.read_text().strip())
        deadline = time.time() + 10
        while self.pid_alive(child) and time.time() < deadline:
            time.sleep(0.2)
        self.assertFalse(self.pid_alive(child), 'owned descendant survived timeout cleanup')
        parent = int(self.pid_file.read_text().strip())
        deadline = time.time() + 10
        while self.pid_alive(parent) and time.time() < deadline:
            time.sleep(0.2)
        self.assertFalse(self.pid_alive(parent), 'owned parent survived timeout cleanup')

    def test_timeout_kills_term_ignoring_descendant_after_parent_exit(self):
        """F1 regression: group KILL reaps the reparented TERM-ignoring class.

        Production call site: run-bounded-swift-tests.sh timeout block via
        signal_owned KILL (owned process group + enumerated-tree sweep).
        The stub parent dies on group TERM, so the descendant is reparented
        and only reachable through the owned pgid. Tree rediscovery alone
        (rev1 behavior) loses it; the M4 mutant proves this test covers it.
        """
        try:
            r = self.run_helper(timeout_secs='2', mode='term_ignoring_child')
            self.assertEqual(r.returncode, 124,
                             f'stdout={r.stdout!r} stderr={r.stderr!r}')
            self.assertIn('TIMEOUT', r.stderr)
            self.assertIn('SWIFT-TERM-RESPONSIVE-PARENT-STARTED', r.stdout)
            self.assertTrue(self.child_pid_file.exists())
            child = int(self.child_pid_file.read_text().strip())
            deadline = time.time() + 10
            while self.pid_alive(child) and time.time() < deadline:
                time.sleep(0.2)
            self.assertFalse(
                self.pid_alive(child),
                'TERM-ignoring reparented descendant survived timeout cleanup')
            parent = int(self.pid_file.read_text().strip())
            deadline = time.time() + 10
            while self.pid_alive(parent) and time.time() < deadline:
                time.sleep(0.2)
            self.assertFalse(self.pid_alive(parent),
                             'owned parent survived timeout cleanup')
        finally:
            self.force_kill_pid_file(self.child_pid_file)
            self.force_kill_pid_file(self.pid_file)

    def test_output_streams_live_before_completion(self):
        env = dict(os.environ)
        env['PATH'] = str(self.bindir) + os.pathsep + env['PATH']
        env['SWIFT_MODE'] = 'live'
        env['SWIFT_ARGS_LOG'] = str(self.args_log)
        env['SWIFT_PID_FILE'] = str(self.pid_file)
        env['SWIFT_CHILD_PID_FILE'] = str(self.child_pid_file)
        argv = ['bash', str(self.helper), '--timeout-secs', '10',
               '--package-path', str(self.pkg),
               '--scratch-path', str(self.root / 'scratch')]
        start = time.time()
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, env=env, cwd=self.tmp.name)
        try:
            found_at = None
            output = []
            while True:
                ready, _, _ = select.select([proc.stdout], [], [], 8)
                self.assertTrue(ready, 'no live output within 8s; output is buffered or hung')
                line = proc.stdout.readline()
                if line == '':
                    break
                output.append(line)
                if 'LIVE-MARKER-IMMEDIATE' in line:
                    found_at = time.time()
                    break
            self.assertIsNotNone(found_at, f'immediate marker missing: {output!r}')
            self.assertLess(found_at - start, 4.0,
                            'immediate marker arrived late; output is not live')
            self.assertIsNone(proc.poll(), 'helper exited before live marker could stream')
            rest, _ = proc.communicate(timeout=30)
            output.append(rest)
            self.assertEqual(proc.returncode, 0, ''.join(output))
            self.assertIn('LIVE-MARKER-LATE', ''.join(output))
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=10)

    def test_no_secret_leak_in_output(self):
        secret = 'SECRET-UNIQUE-260916-2r3xoz-9f8e7d'
        r = self.run_helper(mode='pass', env_extra={'FAKE_SECRET_TOKEN_XYZ': secret})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(secret, r.stdout)
        self.assertNotIn(secret, r.stderr)

    def test_usage_errors_refused(self):
        env = dict(os.environ)
        env['PATH'] = str(self.bindir) + os.pathsep + env['PATH']
        base = ['bash', str(self.helper)]
        cases = [
            [],
            ['--timeout-secs', '10'],
            ['--timeout-secs', '0', '--package-path', str(self.pkg),
             '--scratch-path', 'x'],
            ['--timeout-secs', 'abc', '--package-path', str(self.pkg),
             '--scratch-path', 'x'],
            ['--timeout-secs', '10', '--package-path', str(self.pkg),
             '--scratch-path', 'x', '--unknown-flag'],
            ['--timeout-secs', '10', '--package-path', str(self.root / 'missing'),
             '--scratch-path', 'x'],
        ]
        for argv in cases:
            with self.subTest(argv=argv):
                r = subprocess.run(base + argv, capture_output=True, text=True,
                                   timeout=30, env=env, cwd=self.tmp.name)
                self.assertEqual(r.returncode, 2, f'{argv}: {r.stdout!r} {r.stderr!r}')

    def test_missing_option_values_rejected_without_hang(self):
        """F2 regression: a trailing value-taking option is refused exit 2.

        Production call site: run-bounded-swift-tests.sh argument parser,
        need_value guard per option. Each case carries its own timeout so a
        parser-loop regression (rev1: bare `shift 2`) fails instead of
        hanging the suite; the M5 mutant proves each case covers its class.
        """
        env = dict(os.environ)
        env['PATH'] = str(self.bindir) + os.pathsep + env['PATH']
        base = ['bash', str(self.helper)]
        cases = [
            ['--timeout-secs'],
            ['--timeout-secs', '10', '--package-path'],
            ['--timeout-secs', '10', '--package-path', str(self.pkg),
             '--scratch-path'],
        ]
        for argv in cases:
            with self.subTest(argv=argv):
                r = subprocess.run(base + argv, capture_output=True, text=True,
                                   timeout=10, env=env, cwd=self.tmp.name)
                self.assertEqual(r.returncode, 2,
                                 f'{argv}: {r.stdout!r} {r.stderr!r}')
                self.assertIn('requires a value', r.stderr)

    def test_swift_argv_has_no_selection_bypass(self):
        r = self.run_helper(mode='pass')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.args_log.exists())
        recorded = self.args_log.read_text().strip().splitlines()[-1]
        self.assertTrue(recorded.startswith('test --package-path '), recorded)
        self.assertIn('--scratch-path', recorded)
        for token in ('--skip', '--filter', '--disable-', '--only-testing',
                      '--skip-testing'):
            self.assertNotIn(token, recorded)

    def test_toolchain_versions_printed(self):
        r = self.run_helper(mode='pass')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('toolchain versions', r.stdout)
        self.assertIn('SWIFT-VERSION-STUB', r.stdout)
        self.assertIn('XCODEBUILD-VERSION-STUB', r.stdout)
        self.assertIn('Xcode_26.3', r.stdout)


class CiComposedStepTests(unittest.TestCase):
    """Execute the actual workflow run fields (call-site regression).

    Production call sites: .github/workflows/ci.yml steps "Core unit tests
    (no UI tests or production runners)" and "Select Xcode 26 toolchain and
    show versions", run fields, executed as Actions does with
    bash -e -o pipefail. Kills the call-site narrowing mutant
    `./Scripts/run-bounded-swift-tests.sh ... || true`, which preserves the
    searched token while discarding refusal.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        scripts = root / 'Scripts'
        scripts.mkdir()
        target = scripts / 'run-bounded-swift-tests.sh'
        shutil.copy(SCRIPT, target)
        target.chmod(0o755)
        (root / 'Packages' / 'RunnerControlCore').mkdir(parents=True)
        bindir = root / 'bin'
        bindir.mkdir()
        write_exe(bindir / 'swift', SWIFT_STUB)
        write_exe(bindir / 'xcode-select', XCODE_SELECT_STUB)
        write_exe(bindir / 'xcodebuild', XCODEBUILD_STUB)
        write_exe(bindir / 'sample', SAMPLE_STUB)
        write_exe(bindir / 'sudo', SUDO_STUB)
        self.root = root
        self.bindir = bindir
        self.args_log = root / 'swift-args.log'
        self.pid_file = root / 'swift.pid'
        self.child_pid_file = root / 'swift-child.pid'
        self.sudo_log = root / 'sudo.log'

    def tearDown(self):
        self.tmp.cleanup()

    def base_env(self, mode):
        env = dict(os.environ)
        env['PATH'] = str(self.bindir) + os.pathsep + env['PATH']
        env['SWIFT_MODE'] = mode
        env['SWIFT_ARGS_LOG'] = str(self.args_log)
        env['SWIFT_PID_FILE'] = str(self.pid_file)
        env['SWIFT_CHILD_PID_FILE'] = str(self.child_pid_file)
        env['SUDO_LOG'] = str(self.sudo_log)
        env['RUNNER_TEMP'] = str(self.root / 'runner-temp')
        (self.root / 'runner-temp').mkdir(exist_ok=True)
        return env

    def test_composed_core_step_accepts_helper_success(self):
        command = step_run_command(CORE_STEP)
        self.assertIn('run-bounded-swift-tests.sh', command)
        r = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', command],
                           capture_output=True, text=True, timeout=60,
                           env=self.base_env('pass'), cwd=self.tmp.name)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('SWIFT-TEST-LINE-1', r.stdout)

    def test_composed_core_step_propagates_helper_failure(self):
        command = step_run_command(CORE_STEP)
        self.assertIn('run-bounded-swift-tests.sh', command)
        r = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', command],
                           capture_output=True, text=True, timeout=60,
                           env=self.base_env('fail1'), cwd=self.tmp.name)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('SWIFT-TEST-FAILURE-MARKER', r.stdout)

    def test_composed_toolchain_step_selects_xcode_and_prints_versions(self):
        command = step_run_command(TOOLCHAIN_STEP)
        self.assertIn('Xcode_26.3', command)
        r = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', command],
                           capture_output=True, text=True, timeout=60,
                           env=self.base_env('pass'), cwd=self.tmp.name)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.sudo_log.exists())
        self.assertIn('xcode-select -s /Applications/Xcode_26.3.app',
                      self.sudo_log.read_text())
        self.assertIn('SWIFT-VERSION-STUB', r.stdout)
        self.assertIn('XCODEBUILD-VERSION-STUB', r.stdout)


if __name__ == '__main__':
    unittest.main()
