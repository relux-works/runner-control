"""Blackbox subprocess tests for the built runner-control binary.

Each test execs the dev CLI built by ./Scripts/build.sh, encoding the
reviewers' subprocess reproductions (PATH invocation, JSON envelopes, exit
codes). The suite is live-state safe by construction:

- no test signs out, registers, unregisters, or touches runners;
- login-gated paths run under a throwaway HOME (no identity there);
- launch-at-login is status-only (on/off mutate login items);
- network use is read-only (local-defaults assertions preferred).

Skipped with an explicit reason when the dev binary is absent.
"""

import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest

# Canonical: the CLI reports its process-image path fully resolved, so a
# checkout under a symlinked parent (/tmp -> /private/tmp) must compare
# resolved against resolved.
REPO = os.path.realpath(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
DEV_APP = os.path.join(REPO, ".temp", "products", "RunnerControl.app")
DEV_CLI = os.path.join(DEV_APP, "Contents", "Helpers", "runner-control")
HAS_BINARY = os.path.isfile(DEV_CLI) and os.access(DEV_CLI, os.X_OK)

SKIP_REASON = "dev CLI not built (run ./Scripts/build.sh first)"


def run_cli(args, env=None, cwd=None, timeout=120):
    merged = dict(os.environ)
    if env:
        merged.update(env)
    return subprocess.run(
        [DEV_CLI] + args,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=merged,
        cwd=cwd or REPO,
    )


def single_json_doc(stdout):
    """stdout must be exactly one JSON document (no trailing garbage)."""
    return json.loads(stdout)


@unittest.skipUnless(HAS_BINARY, SKIP_REASON)
class HelpContract(unittest.TestCase):
    def test_help_exits_zero_with_overview(self):
        proc = run_cli(["--help"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(proc.stdout.startswith("OVERVIEW:"))
        self.assertEqual(proc.stderr, "")

    def test_help_subcommand_is_target_aware(self):
        proc = run_cli(["help", "runners"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("OVERVIEW:", proc.stdout)
        self.assertIn("runners", proc.stdout.lower())

    def test_nested_help_exits_zero(self):
        proc = run_cli(["runners", "list", "--help"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("OVERVIEW:", proc.stdout)


@unittest.skipUnless(HAS_BINARY, SKIP_REASON)
class ErrorEnvelope(unittest.TestCase):
    def test_unknown_subcommand_is_usage_with_envelope(self):
        proc = run_cli(["runners", "bogus", "--json"])
        self.assertEqual(proc.returncode, 1, proc.stderr)
        doc = single_json_doc(proc.stdout)
        self.assertEqual(doc["status"], "error")
        self.assertTrue(doc["error"])

    def test_unknown_subcommand_text_keeps_native_usage(self):
        proc = run_cli(["runners", "bogus"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Usage:", proc.stderr)
        self.assertEqual(proc.stdout, "")

    def test_json_before_subcommand_is_usage_with_envelope(self):
        # --json is per-command, not global: misplaced flag must still be
        # exit 1 with a single JSON doc, never 64/empty.
        proc = run_cli(["--json", "runners", "list"])
        self.assertEqual(proc.returncode, 1, proc.stderr)
        doc = single_json_doc(proc.stdout)
        self.assertEqual(doc["status"], "error")

    def test_bad_flag_value_is_usage_with_envelope(self):
        proc = run_cli(["app", "launch-at-login", "bogus", "--json"])
        self.assertEqual(proc.returncode, 1, proc.stderr)
        doc = single_json_doc(proc.stdout)
        self.assertEqual(doc["status"], "error")

    def test_transport_failure_is_failed_with_envelope(self):
        # Skeleton app copy whose SUFeedURL refuses connections: the
        # URLError must surface as exit 2 with a JSON envelope.
        work = tempfile.mkdtemp(prefix="rc-feed-")
        self.addCleanup(shutil.rmtree, work, True)
        helpers = os.path.join(work, "Fake.app", "Contents", "Helpers")
        os.makedirs(helpers)
        shutil.copy(DEV_CLI, os.path.join(helpers, "runner-control"))
        with open(os.path.join(work, "Fake.app", "Contents", "Info.plist"), "wb") as fh:
            plistlib.dump({"SUFeedURL": "http://127.0.0.1:1/feed.xml"}, fh)
        proc = subprocess.run(
            [os.path.join(helpers, "runner-control"), "app", "check-updates", "--json"],
            capture_output=True,
            text=True,
            timeout=120,
            cwd=work,
        )
        self.assertEqual(proc.returncode, 2, proc.stderr)
        doc = single_json_doc(proc.stdout)
        self.assertEqual(doc["status"], "error")
        self.assertTrue(doc["error"])

    def test_needs_login_is_three_with_envelope(self):
        # Throwaway HOME => no session identity => deterministic 3 without
        # touching the live login.
        home = tempfile.mkdtemp(prefix="rc-nohome-")
        self.addCleanup(shutil.rmtree, home, True)
        proc = run_cli(["auth", "installations", "--json"], env={"HOME": home})
        self.assertEqual(proc.returncode, 3, proc.stderr)
        doc = single_json_doc(proc.stdout)
        self.assertEqual(doc["status"], "error")
        self.assertIn("Not signed in", doc["error"])


@unittest.skipUnless(HAS_BINARY, SKIP_REASON)
class PathInvocation(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="rc-path-")
        self.addCleanup(shutil.rmtree, self.work, True)
        self.bindir = os.path.join(self.work, "bin")
        self.cwd = os.path.join(self.work, "cwd")
        self.linkdir = os.path.join(self.work, "link")
        os.makedirs(self.bindir)
        os.makedirs(self.cwd)
        os.makedirs(self.linkdir)
        os.symlink(DEV_CLI, os.path.join(self.bindir, "runner-control"))
        self.path_env = {"PATH": self.bindir + ":/usr/bin:/bin"}

    def test_version_reports_real_binary_from_foreign_cwd(self):
        # Direct symlink invocation from an unrelated cwd: cli must be the
        # resolved binary, never "$CWD/runner-control".
        proc = subprocess.run(
            [os.path.join(self.bindir, "runner-control"), "app", "version", "--json"],
            capture_output=True,
            text=True,
            timeout=120,
            cwd=self.cwd,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        doc = single_json_doc(proc.stdout)
        self.assertEqual(doc["data"]["cli"], DEV_CLI)
        self.assertEqual(doc["data"]["bundle"], DEV_APP)

    def test_version_reports_real_binary_via_path_lookup(self):
        proc = subprocess.run(
            ["runner-control", "app", "version", "--json"],
            capture_output=True,
            text=True,
            timeout=120,
            env={**os.environ, **self.path_env},
            cwd=self.cwd,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        doc = single_json_doc(proc.stdout)
        self.assertEqual(doc["data"]["cli"], DEV_CLI)

    def test_install_via_path_creates_working_link(self):
        link = os.path.join(self.linkdir, "runner-control")
        proc = subprocess.run(
            ["runner-control", "app", "install-cli", "--location", link, "--json"],
            capture_output=True,
            text=True,
            timeout=120,
            env={**os.environ, **self.path_env},
            cwd=self.cwd,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(os.path.islink(link))
        self.assertTrue(os.path.exists(link), "link must not dangle")
        self.assertEqual(os.path.realpath(link), DEV_CLI)

    def test_uninstall_via_path_removes_own_link(self):
        link = os.path.join(self.linkdir, "runner-control")
        os.symlink(DEV_CLI, link)
        proc = subprocess.run(
            ["runner-control", "app", "uninstall-cli", "--location", link, "--json"],
            capture_output=True,
            text=True,
            timeout=120,
            env={**os.environ, **self.path_env},
            cwd=self.cwd,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(os.path.lexists(link))


@unittest.skipUnless(HAS_BINARY, SKIP_REASON)
class JsonContract(unittest.TestCase):
    def test_toggle_booleans_are_real(self):
        proc = run_cli(["app", "auto-check", "status", "--json"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        doc = single_json_doc(proc.stdout)
        self.assertIsInstance(doc["data"]["enabled"], bool)

    def test_launch_at_login_status_shape(self):
        # Read-only: last-known state, never a mutation or prompt.
        # Optional keys are omitted (never null) by this toolchain.
        proc = run_cli(["app", "launch-at-login", "status", "--json"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        doc = single_json_doc(proc.stdout)
        data = doc["data"]
        enabled = data.get("enabled")
        self.assertTrue(enabled is None or isinstance(enabled, bool))
        self.assertIsInstance(data["pending"], bool)


if __name__ == "__main__":
    unittest.main()
