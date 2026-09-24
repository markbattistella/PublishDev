"""Release mistakes should fail before a GitHub release can become an update."""

import contextlib
import importlib.util
import io
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release", ROOT / "Scripts/release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="PublishDev release test ")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.source = self.root / release.VERSION_FILE
        self.source.parent.mkdir(parents=True)
        self.original = (
            "// Preserve this comment.\n"
            "struct ReleaseVersion {\n"
            "    static let current = ReleaseVersion(major: 0, minor: 1, patch: 0)\n"
            "}\n"
        )
        self.source.write_text(self.original)
        self.output = io.StringIO()
        redirect = contextlib.redirect_stdout(self.output)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)

    def binary(self, message, status=0):
        binary = self.root / "publish-dev"
        binary.write_text(f"#!/bin/sh\nprintf '%s\\n' '{message}'\nexit {status}\n")
        binary.chmod(0o755)
        return binary

    def test_stable_tags_with_and_without_v(self):
        for tag in ("0.1.0", "v0.1.0"):
            release.check(self.root, tag)

    def test_invalid_tags_are_rejected(self):
        for tag in ("", "main", "1.2", "1.2.3-rc.1", "01.2.3", "1.2.3\n", "1.2.3;touch bad", "999999999999999999999.0.0"):
            with self.subTest(tag=tag), self.assertRaises(release.ReleaseError):
                release.check(self.root, tag)

    def test_mismatch_explains_how_to_fix_it_before_building(self):
        with self.assertRaisesRegex(release.ReleaseError, r"source reports 0\.1\.0.*tag requires 0\.1\.1") as error:
            release.check(self.root, "0.1.1", self.root / "binary-that-does-not-exist")
        self.assertIn("make prepare-release VERSION=0.1.1", str(error.exception))
        self.assertIn("commit the change", str(error.exception))

    def test_matching_source_and_binary_pass(self):
        release.check(self.root, "v0.1.0", self.binary("PublishDev 0.1.0"))

    def test_incorrect_compiled_version_is_rejected(self):
        with self.assertRaisesRegex(release.ReleaseError, "built executable reports"):
            release.check(self.root, "0.1.0", self.binary("PublishDev 9.9.9"))

    def test_failed_version_command_is_rejected(self):
        with self.assertRaisesRegex(release.ReleaseError, "exit 1"):
            release.check(self.root, "0.1.0", self.binary("PublishDev 0.1.0", status=1))

    def test_preparation_changes_only_the_version_after_confirmation(self):
        with mock.patch("sys.stdin.isatty", return_value=True), mock.patch("builtins.input", return_value="yes"):
            release.prepare(self.root, "v0.1.2")
        self.assertEqual(self.source.read_text(), self.original.replace("patch: 0", "patch: 2"))
        release.check(self.root, "0.1.2")
        self.assertIn("commit your changes", self.output.getvalue())
        self.assertIn("git tag v0.1.2", self.output.getvalue())

    def test_declining_keeps_the_source_unchanged(self):
        with mock.patch("sys.stdin.isatty", return_value=True), mock.patch("builtins.input", return_value=""):
            release.prepare(self.root, "0.1.2")
        self.assertEqual(self.source.read_text(), self.original)

    def test_noninteractive_preparation_requires_explicit_yes(self):
        with mock.patch("sys.stdin.isatty", return_value=False), self.assertRaisesRegex(release.ReleaseError, "--yes"):
            release.prepare(self.root, "0.1.2")
        self.assertEqual(self.source.read_text(), self.original)
        release.prepare(self.root, "0.1.2", assume_yes=True)
        release.check(self.root, "0.1.2")

    def test_downgrade_is_rejected(self):
        with self.assertRaisesRegex(release.ReleaseError, "already reports"):
            release.prepare(self.root, "0.0.9", assume_yes=True)
        self.assertEqual(self.source.read_text(), self.original)

    def test_existing_version_needs_no_edit_or_prompt(self):
        with mock.patch("builtins.input") as prompt:
            release.prepare(self.root, "0.1.0")
        prompt.assert_not_called()
        self.assertEqual(self.source.read_text(), self.original)

    def test_ambiguous_source_is_never_edited(self):
        self.source.write_text(self.original + self.original)
        with self.assertRaisesRegex(release.ReleaseError, "exactly one"):
            release.prepare(self.root, "0.1.2", assume_yes=True)
        self.assertEqual(self.source.read_text(), self.original + self.original)

    def test_cli_failure_and_explicit_fix(self):
        script = self.root / "Scripts/release.py"
        script.parent.mkdir()
        shutil.copyfile(ROOT / "Scripts/release.py", script)
        command = [sys.executable, "-B", str(script)]
        failed = subprocess.run(command + ["check", "0.1.2"], capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1)
        self.assertIn("Release check failed", failed.stderr)
        fixed = subprocess.run(command + ["prepare", "0.1.2", "--yes"], capture_output=True, text=True)
        self.assertEqual(fixed.returncode, 0, fixed.stderr)
        checked = subprocess.run(command + ["check", "0.1.2"], capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_github_annotation_escapes_control_characters(self):
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}), contextlib.redirect_stderr(io.StringIO()):
            release.report_error("Mismatch\nDetails 100%")
        self.assertIn("::error file=", self.output.getvalue())
        self.assertIn("Mismatch%0ADetails 100%25", self.output.getvalue())


if __name__ == "__main__":
    unittest.main()
