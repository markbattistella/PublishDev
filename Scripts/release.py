#!/usr/bin/env python3
"""Prepare the compiled version or validate it against a stable release tag."""

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
    matches = list(VERSION_PATTERN.finditer(text))
    if len(matches) != 1:
        raise ReleaseError(f"Could not find exactly one ReleaseVersion.current declaration in {VERSION_FILE}.")
    match = matches[0]
    return text, match, tuple(int(match[name]) for name in ("major", "minor", "patch"))


def check(root, tag, binary=None):
    expected = parse_version(tag)
    _, _, actual = read_version(root)
    if actual != expected:
        raise ReleaseError(
            f"Release {tag} would fail to update: its source reports {version_text(actual)}, "
            f"but the tag requires {version_text(expected)}.\n"
            f"Run make prepare-release VERSION={version_text(expected)}, commit the change, "
            "then tag that commit. Use a new version if the incorrect release is already public."
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
    text, match, current = read_version(root)
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
        print(f"Updated source version to {version_text(requested)}.")
    else:
        print(f"Source already reports {version_text(requested)}.")
    print("Review and commit your changes, including release notes, before tagging.")
    print(f"Then run: git tag {tag}")
    print(f"          git push origin {tag}")
    print("GitHub will validate the tagged commit and publish the release only if all checks pass.")


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
    check_parser = commands.add_parser("check", help="Fail if the source or compiled version differs from the tag")
    check_parser.add_argument("version")
    check_parser.add_argument("--binary", type=pathlib.Path, help="Also verify this built publish-dev executable")
    arguments = parser.parse_args()
    try:
        if arguments.command == "prepare":
            prepare(ROOT, arguments.version, arguments.yes)
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
