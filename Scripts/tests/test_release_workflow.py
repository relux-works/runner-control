"""Release workflow wiring and tag-trust behavior.

The workflow delegates tag trust to the production script
Scripts/validate-release-tag.sh. Wiring tests prove the workflow invokes that
script before any work and preserves gate order and publish gating. Behavioral
tests execute the production script with stubbed git/gh and prove it accepts a
trusted tag while refusing malformed tags, HEAD/tag mismatch, non-main
ancestry, existing releases, and unknown lookup failures (fail closed).
Composed-step tests extract the actual Validate trusted release tag run field
from release.yml and execute it under Actions-equivalent bash -e -o pipefail,
proving the caller propagates refusal instead of discarding it.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

WORKFLOW = Path(__file__).parents[2] / '.github' / 'workflows' / 'release.yml'
SCRIPT = Path(__file__).parents[1] / 'validate-release-tag.sh'
ORDER = ['Validate trusted release tag', 'Release prerequisites', 'Unit tests',
         'Build, notarize, staple and sign appcast', 'Publish complete GitHub Release']

GIT_STUB = '''#!/bin/bash
printf '%s\\n' "$*" >> "$GIT_LOG"
if [ "$1" = "rev-parse" ] && [ "$2" = "HEAD" ]; then
  printf '%s\\n' "${HEAD_SHA:-abc123}"
  exit 0
fi
if [ "$1" = "rev-parse" ]; then
  printf '%s\\n' "${TAG_SHA:-abc123}"
  exit 0
fi
if [ "$1" = "merge-base" ]; then
  exit "${ANCESTRY_EXIT:-0}"
fi
exit 0
'''

GH_STUB = '''#!/bin/bash
printf '%s\\n' "$*" >> "$GH_LOG"
if [ "${GH_MODE:-absent}" = "exists" ]; then
  exit 0
fi
if [ -n "${GH_TEXT:-}" ]; then
  printf '%s\\n' "$GH_TEXT" >&2
fi
exit 1
'''


def blocks(text):
    starts = [m.start() for m in re.finditer(r'^      - ', text, re.M)]
    return [text[s:e] for s, e in zip(starts, starts[1:] + [len(text)])]


def block_named(blocks, name):
    found = [b for b in blocks if b.splitlines()[0].endswith(f'- name: {name}')]
    assert len(found) == 1, name
    return found[0]


def write_exe(path, content):
    path.write_text(content)
    path.chmod(0o755)


def trust_run_command(text=None):
    """Extract the actual Validate trusted release tag run field.

    Reads the production workflow file (not a hardcoded command) so a
    call-site mutant that keeps the script token but discards its exit status
    changes what the composed-step tests execute. Supports both inline and
    block-scalar run fields.
    """
    raw = WORKFLOW.read_text() if text is None else text
    block = block_named(blocks(raw), 'Validate trusted release tag')
    lines = block.splitlines()
    run_idx = None
    run_value = None
    for i, line in enumerate(lines):
        matched = re.match(r'\s*run:\s*(.*)$', line)
        if matched:
            run_idx = i
            run_value = matched.group(1).strip()
            break
    assert run_idx is not None, 'Validate trusted release tag run field missing'
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


class ReleaseWorkflowTests(unittest.TestCase):
    def test_gates_precede_packaging_precedes_publish(self):
        text = WORKFLOW.read_text()
        positions = [text.index(f'- name: {name}') for name in ORDER]
        self.assertEqual(positions, sorted(positions))

    def test_only_log_preservation_overrides_success_gating(self):
        gated = set()
        for block in blocks(WORKFLOW.read_text()):
            name = block.splitlines()[0]
            if any(re.match(r'\s*if\s*:', line) for line in block.splitlines()[1:]):
                gated.add(name)
        self.assertEqual(len(gated), 1)
        self.assertTrue(next(iter(gated)).endswith('- name: Preserve release logs'))

    def test_workflow_invokes_trust_script_before_any_work(self):
        block = block_named(blocks(WORKFLOW.read_text()), 'Validate trusted release tag')
        self.assertIn('Scripts/validate-release-tag.sh', block)
        self.assertTrue(SCRIPT.exists(), 'production trust script missing')
        self.assertTrue(os.access(SCRIPT, os.X_OK), 'trust script must be executable')
        body = SCRIPT.read_text()
        for token in (r'^v[0-9]+\.[0-9]+\.[0-9]+$', 'git rev-parse',
                      'merge-base --is-ancestor', 'gh release view',
                      'release not found', 'Could not verify'):
            self.assertIn(token, body)


class ReleaseTagTrustBehaviorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        scripts = root / 'Scripts'
        scripts.mkdir()
        shutil.copy(SCRIPT, scripts / 'validate-release-tag.sh')
        bindir = root / 'bin'
        bindir.mkdir()
        write_exe(bindir / 'git', GIT_STUB)
        write_exe(bindir / 'gh', GH_STUB)
        self.root = root
        self.bindir = bindir
        self.git_log = root / 'git.log'
        self.gh_log = root / 'gh.log'

    def tearDown(self):
        self.tmp.cleanup()

    def run_trust(self, tag='v1.2.0', head='abc123def', tag_sha='abc123def',
                  ancestry_exit=0, gh_mode='absent',
                  gh_text='release not found', unset_tag=False):
        env = dict(os.environ)
        env['PATH'] = str(self.bindir) + os.pathsep + env['PATH']
        if unset_tag:
            env.pop('RELEASE_TAG', None)
        else:
            env['RELEASE_TAG'] = tag
        env['HEAD_SHA'] = head
        env['TAG_SHA'] = tag_sha
        env['ANCESTRY_EXIT'] = str(ancestry_exit)
        env['GH_MODE'] = gh_mode
        env['GH_TEXT'] = gh_text
        env['GIT_LOG'] = str(self.git_log)
        env['GH_LOG'] = str(self.gh_log)
        return subprocess.run(['bash', str(self.root / 'Scripts' / 'validate-release-tag.sh')],
                              capture_output=True, text=True, timeout=60,
                              env=env, cwd=self.tmp.name)

    def test_trusted_tag_accepted(self):
        r = self.run_trust()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Trusted release tag v1.2.0 verified', r.stdout)

    def test_non_main_ancestry_refused(self):
        r = self.run_trust(ancestry_exit=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('not on origin/main ancestry', r.stderr)
        self.assertNotIn('Trusted release tag', r.stdout)

    def test_head_tag_mismatch_refused(self):
        r = self.run_trust(head='aaa111', tag_sha='bbb222')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('does not match tag commit', r.stderr)
        self.assertNotIn('Trusted release tag', r.stdout)

    def test_malformed_tags_refused_before_any_git_work(self):
        for tag in ['v1.2', 'v1.2.3.4', 'main', '1.2.0', 'v1.2.0 ',
                    'v1.2.0;echo', 'v1.2.0\nv9.9.9']:
            if self.git_log.exists():
                self.git_log.unlink()
            if self.gh_log.exists():
                self.gh_log.unlink()
            r = self.run_trust(tag=tag)
            self.assertNotEqual(r.returncode, 0, tag)
            self.assertIn('must be vMAJOR.MINOR.PATCH', r.stderr, tag)
            self.assertNotIn('Trusted release tag', r.stdout, tag)
            self.assertFalse(self.git_log.exists(), f'git reached for {tag!r}')
            self.assertFalse(self.gh_log.exists(), f'gh reached for {tag!r}')

    def test_missing_release_tag_refused(self):
        r = self.run_trust(unset_tag=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('RELEASE_TAG', r.stderr)
        self.assertFalse(self.git_log.exists())

    def test_existing_release_refused(self):
        r = self.run_trust(gh_mode='exists')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Release already exists', r.stderr)
        self.assertNotIn('Trusted release tag', r.stdout)

    def test_gh_lookup_failure_fails_closed_not_absent(self):
        for text in ['Error: HTTP 500 from the GitHub API',
                     "GraphQL: Could not resolve to a Repository with the name 'x/y'."]:
            r = self.run_trust(gh_text=text)
            self.assertNotEqual(r.returncode, 0, text)
            self.assertIn('Could not verify release absence', r.stderr, text)
            self.assertIn(text.split(':')[0] if ':' in text else text[:20], r.stderr, text)
            self.assertNotIn('Trusted release tag', r.stdout, text)
            self.assertNotIn('Release already exists', r.stderr, text)

    def test_gh_empty_error_fails_closed(self):
        r = self.run_trust(gh_text='')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Could not verify release absence', r.stderr)
        self.assertNotIn('Trusted release tag', r.stdout)


class ReleaseWorkflowComposedStepTests(unittest.TestCase):
    """Execute the actual workflow trust run field (rev2 F1 regression).

    Production call site: .github/workflows/release.yml step Validate trusted
    release tag, run field, executed as Actions does with bash -e -o pipefail.
    Reuses the git/gh fixtures above. Kills the call-site narrowing mutant
    run: ./Scripts/validate-release-tag.sh || true, which preserves the
    searched token while discarding refusal.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        scripts = root / 'Scripts'
        scripts.mkdir()
        target = scripts / 'validate-release-tag.sh'
        shutil.copy(SCRIPT, target)
        target.chmod(0o755)
        bindir = root / 'bin'
        bindir.mkdir()
        write_exe(bindir / 'git', GIT_STUB)
        write_exe(bindir / 'gh', GH_STUB)
        self.root = root
        self.bindir = bindir
        self.git_log = root / 'git.log'
        self.gh_log = root / 'gh.log'

    def tearDown(self):
        self.tmp.cleanup()

    def run_workflow_trust_step(self, tag='v1.2.0', head='abc123def',
                                tag_sha='abc123def', ancestry_exit=0,
                                gh_mode='absent', gh_text='release not found'):
        command = trust_run_command()
        self.assertIn('validate-release-tag.sh', command)
        env = dict(os.environ)
        env['PATH'] = str(self.bindir) + os.pathsep + env['PATH']
        env['RELEASE_TAG'] = tag
        env['HEAD_SHA'] = head
        env['TAG_SHA'] = tag_sha
        env['ANCESTRY_EXIT'] = str(ancestry_exit)
        env['GH_MODE'] = gh_mode
        env['GH_TEXT'] = gh_text
        env['GIT_LOG'] = str(self.git_log)
        env['GH_LOG'] = str(self.gh_log)
        return subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', command],
                              capture_output=True, text=True, timeout=60,
                              env=env, cwd=self.tmp.name)

    def test_workflow_trust_step_accepts_trusted_tag(self):
        r = self.run_workflow_trust_step()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Trusted release tag v1.2.0 verified', r.stdout)

    def test_workflow_trust_step_refuses_non_main_ancestry(self):
        r = self.run_workflow_trust_step(ancestry_exit=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('not on origin/main ancestry', r.stderr)
        self.assertNotIn('Trusted release tag', r.stdout)
        self.assertTrue(self.git_log.exists())


if __name__ == '__main__':
    unittest.main()
