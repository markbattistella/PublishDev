#!/usr/bin/env python3
"""Prepare, publish, or validate a stable PublishDev release."""

import argparse
import os
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSION_FILE = pathlib.Path("Sources/PublishDev/ReleaseVersion.swift")
VERSION_PATTERN = re.compile(
    r"(?m)^(?P<prefix>[ \t]*static let current = ReleaseVersion\(major: )"
    r"(?P<major>[0-9]+), minor: (?P<minor>[0-9]+), patch: (?P<patch>[0-9]+)\)(?P<suffix>[ \t]*)$"
)
TAG_PATTERN = re.compile(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", re.ASCII)


class ReleaseError(Exception):
    pass


def parse_version(tag):
    match = TAG_PATTERN.fullmatch(tag)
    if not match or any(len(value) > 19 for value in match.groups()):
        raise ReleaseError("Use a stable release version such as 0.1.2 or v0.1.2.")
    parts = tuple(int(value) for value in match.groups())
    if any(value > 2**63 - 1 for value in parts):
        raise ReleaseError("Release version components must fit in a Swift Int.")
    return parts


def version_text(parts):
    return ".".join(str(part) for part in parts)


def read_version(root):
    text = (root / VERSION_FILE).read_text(encoding="utf-8")
    return parse_source(text)


def parse_source(text):
    matches = list(VERSION_PATTERN.finditer(text))
    if len(matches) != 1:
        raise ReleaseError(f"Could not find exactly one ReleaseVersion.current declaration in {VERSION_FILE}.")
    match = matches[0]
    return text, match, tuple(int(match[name]) for name in ("major", "minor", "patch"))


def write_version(root, requested):
    text, match, _ = read_version(root)
    replacement = (f"{match['prefix']}{requested[0]}, minor: {requested[1]}, "
                   f"patch: {requested[2]}){match['suffix']}")
    updated = text[:match.start()] + replacement + text[match.end():]
    path = root / VERSION_FILE
    descriptor, temporary = tempfile.mkstemp(prefix=".release-version-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(updated)
        os.chmod(temporary, path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        pathlib.Path(temporary).unlink(missing_ok=True)


def check(root, tag, binary=None):
    expected = parse_version(tag)
    _, _, actual = read_version(root)
    if actual != expected:
        raise ReleaseError(
            f"Release {tag} would fail to update: its source reports {version_text(actual)}, "
            f"but the tag requires {version_text(expected)}.\n"
            f"Commit your code changes, then run make release VERSION={version_text(expected)} "
            "to commit the version and push the matching tag. "
            "Choose a new unused version if the incorrect tag is already on origin."
        )
    if binary is not None:
        result = subprocess.run([str(binary.resolve()), "--version"], capture_output=True,
                                text=True, timeout=10, check=False)
        reported = result.stdout.strip()
        required = f"PublishDev {version_text(expected)}"
        if result.returncode != 0 or reported != required:
            raise ReleaseError(
                f"Release {tag} would fail to update: the built executable reports {reported!r} "
                f"(exit {result.returncode}); expected {required!r}. Rebuild from the tagged commit."
            )
    print(f"Release {tag}: source version matches" + (" and built executable matches." if binary else "."))


def prepare(root, tag, assume_yes=False):
    requested = parse_version(tag)
    _, _, current = read_version(root)
    if requested < current:
        raise ReleaseError(f"Cannot prepare {version_text(requested)}: the source already reports {version_text(current)}.")
    if requested != current:
        print(f"Requested release: {version_text(requested)}")
        print(f"Source currently reports: {version_text(current)}")
        if not assume_yes:
            if not sys.stdin.isatty():
                raise ReleaseError("Run this command in a terminal, or pass --yes to explicitly approve the version change.")
            try:
                answer = input(f"Update {VERSION_FILE} to {version_text(requested)}? [y/N] ")
            except EOFError:
                answer = ""
            if answer.strip().lower() not in ("y", "yes"):
                print("Cancelled. No files changed.")
                return
        write_version(root, requested)
        print(f"Updated source version to {version_text(requested)}.")
    else:
        print(f"Source already reports {version_text(requested)}.")
    print("This only prepares the file; it has not committed, pushed, or tagged anything.")
    print("Review and commit your changes other than the version bump, including release notes.")
    print(f"Then run: make release VERSION={tag}")
    print("That command commits the version and pushes the branch and tag together.")


def git(root, *arguments, allow_failure=False):
    result = subprocess.run(["git", *arguments], cwd=root, capture_output=True, text=True, check=False)
    if result.returncode and not allow_failure:
        raise ReleaseError(f"git {' '.join(arguments)} failed:\n{result.stderr.strip() or result.stdout.strip()}")
    return result


def changed_paths(root):
    # NUL separators preserve spaces and newlines in filenames; inspect both index and worktree.
    paths = set()
    for arguments in (("diff", "--name-only", "-z", "HEAD"),
                      ("diff", "--cached", "--name-only", "-z"),
                      ("ls-files", "--others", "--exclude-standard", "-z")):
        paths.update(filter(None, git(root, *arguments).stdout.split("\0")))
    return paths


def publish(root, tag):
    requested = parse_version(tag)
    branch = git(root, "symbolic-ref", "--quiet", "--short", "HEAD", allow_failure=True).stdout.strip()
    if not branch:
        raise ReleaseError("Check out a branch before releasing; detached HEAD cannot be published.")
    for marker in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"):
        path = pathlib.Path(git(root, "rev-parse", "--git-path", marker).stdout.strip())
        if (root / path).exists():
            raise ReleaseError("Finish the current merge, rebase, cherry-pick, or revert before releasing.")
    other_changes = changed_paths(root) - {str(VERSION_FILE)}
    if other_changes:
        raise ReleaseError("Commit your other changes before releasing. Only the version bump is committed automatically:\n"
                           + "\n".join(sorted(other_changes)))
    text, match, current = read_version(root)
    committed_text, committed_match, committed_version = parse_source(
        git(root, "show", f"HEAD:{VERSION_FILE}").stdout)
    if text[:match.start()] + text[match.end():] != (
            committed_text[:committed_match.start()] + committed_text[committed_match.end():]):
        raise ReleaseError(f"Commit edits to {VERSION_FILE} other than its version number before releasing.")
    if requested < max(current, committed_version):
        raise ReleaseError("The requested release is older than the source version. Choose a newer version.")
    git(root, "cat-file", "-e", "HEAD:.github/workflows/release.yml")
    upstream = git(root, "rev-parse", "--abbrev-ref", "@{upstream}", allow_failure=True).stdout.strip()
    if upstream and upstream != f"origin/{branch}":
        raise ReleaseError(f"This branch tracks {upstream}, not origin/{branch}. Check out your release branch first.")
    # Check the push destination itself, including repositories with a distinct push URL.
    destination = git(root, "remote", "get-url", "--push", "--all", "origin").stdout.splitlines()
    if len(destination) != 1:
        raise ReleaseError("Release requires exactly one push URL for origin.")
    remote = destination[0]
    canonical = version_text(requested)
    aliases = (canonical, f"v{canonical}")
    remote_refs = git(root, "ls-remote", "--refs", remote,
                      f"refs/heads/{branch}", *(f"refs/tags/{name}" for name in aliases)).stdout
    refs = dict(line.split("\t", 1)[::-1] for line in remote_refs.splitlines())
    for name in aliases:
        if f"refs/tags/{name}" in refs:
            raise ReleaseError(f"Tag {name} already exists on origin. Check its GitHub Actions run; "
                               "use a new version for another release. No tag was moved.")
    if f"refs/heads/{branch}" in refs:
        git(root, "fetch", "--no-tags", remote, f"refs/heads/{branch}")
        if git(root, "merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD", allow_failure=True).returncode:
            raise ReleaseError("Your branch is behind or diverged from origin. Pull and reconcile changes, then retry.")
    head = git(root, "rev-parse", "HEAD").stdout.strip()
    resume = False
    for name in aliases:
        existing = git(root, "rev-parse", "--verify", f"refs/tags/{name}", allow_failure=True)
        if existing.returncode == 0:
            target = git(root, "rev-parse", f"refs/tags/{name}^{{commit}}").stdout.strip()
            if name != tag or target != head or current != requested or changed_paths(root):
                raise ReleaseError(f"Local tag {name} already exists and cannot be reused for this release. "
                                   "No tag was moved. Choose a new version.")
            resume = True
    print(f"Releasing {tag} from {branch} to origin.", flush=True)
    try:
        if not resume:
            if current != requested:
                write_version(root, requested)
            if git(root, "diff", "HEAD", "--", str(VERSION_FILE)).stdout:
                git(root, "add", "--", str(VERSION_FILE))
                git(root, "commit", "-m", f"Release {tag}", "--only", "--", str(VERSION_FILE))
            # Hooks may modify files or reject a commit. Never tag uncommitted source.
            if changed_paths(root):
                raise ReleaseError("The working tree changed during release preparation. Review and commit it before retrying.")
            if parse_source(git(root, "show", f"HEAD:{VERSION_FILE}").stdout)[2] != requested:
                raise ReleaseError("The committed version does not match the requested release. No tag was created.")
            git(root, "tag", "-a", tag, "-m", f"PublishDev {canonical}")
        # Explicit refs avoid push.default / push.followTags publishing unrelated branches or tags.
        # Both refs update or neither does. Never force, and never fall back to separate pushes.
        git(root, "-c", "push.followTags=false", "push", "--atomic", "origin",
            f"HEAD:refs/heads/{branch}", f"refs/tags/{tag}:refs/tags/{tag}")
    except ReleaseError as error:
        raise ReleaseError(f"{error}\nLocal progress was kept. Resolve the error, then rerun "
                           f"make release VERSION={tag}. No tags are force-moved.") from error
    print(f"Pushed the commit and tag {tag}. GitHub Actions will validate and publish the release.")
    print("The update becomes available once that workflow succeeds. No manual GitHub release is needed.")


def report_error(message):
    print(f"Release check failed: {message}", file=sys.stderr)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        escaped = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error file={VERSION_FILE},title=Release validation failed::{escaped}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare", help="Offer to update the source version before you commit and tag")
    prepare_parser.add_argument("version")
    prepare_parser.add_argument("--yes", action="store_true", help="Approve the source version edit without a prompt")
    release_parser = commands.add_parser("release", help="Commit the version and push the branch and tag for automatic publication")
    release_parser.add_argument("version")
    check_parser = commands.add_parser("check", help="Fail if the source or compiled version differs from the tag")
    check_parser.add_argument("version")
    check_parser.add_argument("--binary", type=pathlib.Path, help="Also verify this built publish-dev executable")
    arguments = parser.parse_args()
    try:
        if arguments.command == "prepare":
            prepare(ROOT, arguments.version, arguments.yes)
        elif arguments.command == "release":
            publish(ROOT, arguments.version)
        else:
            check(ROOT, arguments.version, arguments.binary)
    except (ReleaseError, OSError, subprocess.TimeoutExpired) as error:
        report_error(str(error))
        return 1
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
