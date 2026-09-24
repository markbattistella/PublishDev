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
        self.assertIn("make release VERSION=0.1.1", str(error.exception))
        self.assertIn("commit the version", str(error.exception))

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
        self.assertIn("has not committed, pushed, or tagged", self.output.getvalue())
        self.assertIn("make release VERSION=v0.1.2", self.output.getvalue())
        self.assertNotIn("git tag", self.output.getvalue())

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


class ReleasePublicationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="PublishDev publication test ")
        self.addCleanup(self.directory.cleanup)
        base = pathlib.Path(self.directory.name)
        self.remote = base / "origin.git"
        self.root = base / "checkout"
        self.root.mkdir()
        self.run_git("init", "--bare", str(self.remote))
        self.run_git("init", "-b", "main")
        for key, value in (("user.name", "Release Test"), ("user.email", "release@example.invalid"),
                           ("core.hooksPath", str(base / "hooks")), ("commit.gpgsign", "false"),
                           ("tag.gpgsign", "false")):
            self.run_git("config", key, value)
        self.source = self.root / release.VERSION_FILE
        self.source.parent.mkdir(parents=True)
        self.source.write_text("// Keep this comment.\nstatic let current = ReleaseVersion(major: 0, minor: 1, patch: 0)\n")
        workflow = self.root / ".github/workflows/release.yml"
        workflow.parent.mkdir(parents=True)
        workflow.write_text("name: fixture\n")
        self.run_git("add", ".")
        self.run_git("commit", "-m", "Initial")
        self.run_git("remote", "add", "origin", str(self.remote))
        self.run_git("push", "-u", "origin", "main")
        self.initial = self.run_git("rev-parse", "HEAD")
        self.output = io.StringIO()
        redirect = contextlib.redirect_stdout(self.output)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)

    def run_git(self, *args):
        result = subprocess.run(["git", *args], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def remote_git(self, *args):
        return self.run_git("--git-dir", str(self.remote), *args)

    def assert_unpublished(self):
        self.assertEqual(self.remote_git("rev-parse", "refs/heads/main"), self.initial)
        self.assertEqual(self.remote_git("tag", "--list"), "")

    def test_one_command_commits_version_and_pushes_matching_branch_and_tag(self):
        release.publish(self.root, "v0.1.2")
        commit = self.run_git("rev-parse", "HEAD")
        self.assertNotEqual(commit, self.initial)
        self.assertEqual(self.remote_git("rev-parse", "refs/heads/main"), commit)
        self.assertEqual(self.remote_git("rev-parse", "refs/tags/v0.1.2^{commit}"), commit)
        self.assertIn("patch: 2", self.remote_git("show", f"v0.1.2:{release.VERSION_FILE}"))
        self.assertEqual(self.run_git("status", "--porcelain"), "")
        self.assertIn("No manual GitHub release is needed", self.output.getvalue())

    def test_existing_prepared_version_is_committed(self):
        release.write_version(self.root, (0, 1, 2))
        self.run_git("add", str(release.VERSION_FILE))
        release.publish(self.root, "0.1.2")
        self.assertIn("patch: 2", self.remote_git("show", f"0.1.2:{release.VERSION_FILE}"))
        self.assertEqual(self.run_git("rev-list", "--count", "HEAD"), "2")

    def test_already_committed_version_does_not_create_empty_commit(self):
        release.publish(self.root, "0.1.0")
        self.assertEqual(self.remote_git("rev-parse", "0.1.0^{commit}"), self.initial)

    def test_untracked_and_staged_unrelated_changes_block_release(self):
        other = self.root / "unfinished work.txt"
        other.write_text("Do not publish")
        for staged in (False, True):
            if staged:
                self.run_git("add", other.name)
            with self.assertRaisesRegex(release.ReleaseError, "Commit your other changes"):
                release.publish(self.root, "0.1.2")
            self.assertEqual(release.read_version(self.root)[2], (0, 1, 0))
            self.assert_unpublished()

    def test_nonversion_edits_in_version_file_are_not_committed(self):
        self.source.write_text(self.source.read_text().replace("Keep this", "Edited"))
        with self.assertRaisesRegex(release.ReleaseError, "other than its version number"):
            release.publish(self.root, "0.1.2")
        self.assert_unpublished()

    def test_detached_head_is_rejected(self):
        self.run_git("checkout", "--detach")
        with self.assertRaisesRegex(release.ReleaseError, "detached HEAD"):
            release.publish(self.root, "0.1.2")
        self.assert_unpublished()

    def test_existing_remote_alias_is_rejected_before_edit(self):
        self.run_git("tag", "v0.1.2")
        self.run_git("push", "origin", "v0.1.2")
        with self.assertRaisesRegex(release.ReleaseError, "already exists on origin"):
            release.publish(self.root, "0.1.2")
        self.assertEqual(release.read_version(self.root)[2], (0, 1, 0))

    def test_local_tag_at_wrong_version_is_not_moved(self):
        self.run_git("tag", "0.1.2")
        with self.assertRaisesRegex(release.ReleaseError, "Local tag 0.1.2 already exists"):
            release.publish(self.root, "0.1.2")
        self.assertEqual(self.run_git("rev-parse", "0.1.2"), self.initial)
        self.assert_unpublished()

    def test_remote_ahead_is_rejected_before_version_edit(self):
        self.run_git("commit", "--allow-empty", "-m", "Remote advance")
        self.run_git("push", "origin", "main")
        self.run_git("reset", "--hard", self.initial)
        with self.assertRaisesRegex(release.ReleaseError, "behind or diverged"):
            release.publish(self.root, "0.1.2")
        self.assertEqual(release.read_version(self.root)[2], (0, 1, 0))
        self.assertEqual(self.run_git("tag", "--list"), "")

    def test_failed_atomic_push_keeps_remote_unchanged_and_can_resume(self):
        self.remote_git("config", "receive.denyNonFastForwards", "true")
        self.remote_git("config", "receive.advertiseAtomic", "false")
        with self.assertRaisesRegex(release.ReleaseError, "Local progress was kept"):
            release.publish(self.root, "0.1.2")
        self.assert_unpublished()
        prepared = self.run_git("rev-parse", "HEAD")
        self.assertNotEqual(prepared, self.initial)
        self.assertEqual(self.run_git("rev-parse", "0.1.2^{commit}"), prepared)
        self.remote_git("config", "receive.advertiseAtomic", "true")
        release.publish(self.root, "0.1.2")
        self.assertEqual(self.remote_git("rev-parse", "main"), prepared)
        self.assertEqual(self.remote_git("rev-parse", "0.1.2^{commit}"), prepared)
        self.assertEqual(self.run_git("rev-list", "--count", "HEAD"), "2")

    def test_tag_rejection_does_not_push_branch(self):
        hooks = self.remote / "release-test-hooks"
        hooks.mkdir()
        self.remote_git("config", "core.hooksPath", str(hooks))
        hook = hooks / "update"
        hook.write_text('#!/bin/sh\ncase "$1" in refs/tags/*) exit 1;; esac\nexit 0\n')
        hook.chmod(0o755)
        with self.assertRaisesRegex(release.ReleaseError, "Local progress was kept"):
            release.publish(self.root, "0.1.2")
        self.assert_unpublished()

    def test_commit_hook_failure_does_not_tag_or_push(self):
        hooks = pathlib.Path(self.run_git("config", "core.hooksPath"))
        hooks.mkdir()
        hook = hooks / "pre-commit"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        with self.assertRaisesRegex(release.ReleaseError, "Local progress was kept"):
            release.publish(self.root, "0.1.2")
        self.assert_unpublished()
        self.assertEqual(self.run_git("tag", "--list"), "")
        self.assertEqual(release.read_version(self.root)[2], (0, 1, 2))
        hook.unlink()
        release.publish(self.root, "0.1.2")
        self.assertIn("patch: 2", self.remote_git("show", f"0.1.2:{release.VERSION_FILE}"))

    def test_unrelated_tags_are_not_pushed_with_follow_tags_enabled(self):
        self.run_git("config", "push.followTags", "true")
        self.run_git("tag", "-a", "unrelated", "-m", "Unrelated")
        release.publish(self.root, "0.1.2")
        self.assertEqual(self.remote_git("tag", "--list"), "0.1.2")

    def test_checks_push_destination_when_it_differs_from_fetch_remote(self):
        destination = self.remote.parent / "push destination.git"
        self.run_git("clone", "--bare", str(self.remote), str(destination))
        self.run_git("--git-dir", str(destination), "tag", "v0.1.2", self.initial)
        self.run_git("config", "remote.origin.pushurl", str(destination))
        with self.assertRaisesRegex(release.ReleaseError, "already exists on origin"):
            release.publish(self.root, "0.1.2")
        self.assertEqual(release.read_version(self.root)[2], (0, 1, 0))
        self.assert_unpublished()

    def test_hook_changes_are_not_silently_tagged(self):
        hooks = pathlib.Path(self.run_git("config", "core.hooksPath"))
        hooks.mkdir()
        hook = hooks / "post-commit"
        hook.write_text("#!/bin/sh\nprintf 'hook edit\\n' > generated.txt\n")
        hook.chmod(0o755)
        with self.assertRaisesRegex(release.ReleaseError, "working tree changed"):
            release.publish(self.root, "0.1.2")
        self.assert_unpublished()
        self.assertEqual(self.run_git("tag", "--list"), "")

    def test_downgrade_cannot_hide_behind_uncommitted_version_edit(self):
        release.write_version(self.root, (0, 0, 1))
        with self.assertRaisesRegex(release.ReleaseError, "older than the source"):
            release.publish(self.root, "0.0.2")
        self.assertEqual(self.run_git("rev-parse", "HEAD"), self.initial)
        self.assert_unpublished()


if __name__ == "__main__":
    unittest.main()
