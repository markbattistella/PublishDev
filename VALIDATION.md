# Validation

## Preview caching and release diagnostics — 25 September 2026

GitHub run [36059443937](https://github.com/markbattistella/PublishDev/actions/runs/36059443937) passed version validation, release-tool tests, and formatting, but failed `servesTheStagedWebsiteWithPython`: the second request returned the first page and revision after a rebuild. The original test passed locally on Swift 6.4; the CI runner used Swift 6.2, so the exact stale-response failure was not reproduced locally.

- Added `Cache-Control: no-store` to preview responses, including pages, assets, reload endpoints, and errors. This prevents clients from storing responses for reuse, as defined in [HTTP Caching, section 5.2.2.5](https://www.rfc-editor.org/rfc/rfc9111.html#section-5.2.2.5).
- The strengthened regression test failed on missing headers before the server change and passed afterward. It keeps client caching enabled and verifies page, CSS, and revision updates across three consecutive rebuilds. Server readiness is awaited before making requests.
- All 23 Swift tests, the release build, and strict formatting lint passed locally. Builds used a clean temporary scratch directory because the checkout's existing build directory had code-signing metadata errors.
- All terminal session checks passed against the release executable, including Return, signals, terminal closure, replacement, port conflicts, and descendant cleanup.
- Parsed the workflow YAML and exercised its failure-summary script for version, Swift test, terminal session, checkout, and manually published release failures. Summaries identify the failed stage and only show version-repair advice when that check fails.

The updated workflow has not run on GitHub yet. A new release tag must include the fix; rerunning the old tag still checks its original source.

## One-command releases — 25 September 2026

- All 30 release-tool tests passed, including publication to isolated local bare Git repositories. No real remote was pushed.
- Verified version edits and already-prepared bumps are committed, existing matching commits need no empty commit, and remote branch/tag versions agree after publication.
- Verified unfinished work, edits outside the version declaration, detached HEAD, behind branches, downgrades, and conflicting local or remote tags stop publication.
- Verified atomic pushes leave the remote branch unchanged when a tag is rejected or atomic push support is unavailable. Retrying after a failed push reuses the matching local tag and commit.
- Verified failed commit hooks and changes made by hooks stop publication, separate push URLs are checked, and `push.followTags` cannot publish unrelated tags.
- Swift formatting lint, workflow YAML parsing, Make target dry runs, and `git diff --check` passed. The existing uncommitted source version of `1.0.0` was preserved.

The real GitHub workflow was not triggered. Commit these tooling changes before using `make release VERSION=x.y.z`; GitHub publication still requires its validation job to succeed.

## Release publication checks — 24 September 2026

- All 14 release-tool tests passed: source/tag and binary/version mismatches, stable tag parsing, interactive approval and decline, explicit noninteractive approval, downgrade rejection, CLI exit codes, and GitHub error annotations.
- The local source and the existing release executable both passed `Scripts/release.py check 0.1.0 --binary ...`.
- `actionlint` 1.7.12 accepted the GitHub Actions workflow. Its downloaded archive was checked against the publisher's SHA-256 checksums before use.
- The workflow's publication scripts were exercised with a fake GitHub CLI: lightweight tags and annotated tags pointing to the tested commit passed; a moved tag failed; an existing release was not changed. The publishing job depends on successful validation and runs only for tag pushes.
- Strict Swift formatting lint and `git diff --check` passed. The only Swift change is a comment pointing maintainers to the preparation command.

The GitHub-hosted workflow and real release publication have not been run from this checkout. Commit the workflow and helper into the release commit before pushing its tag. Publishing manually through GitHub remains possible and makes the release visible before its validation run.

## Release updater — 24 September 2026

Validated with Xcode 27.1 beta (Swift 6.4) and Python 3.14.7 on Apple silicon macOS.

- All 23 Swift tests passed, including parameterized stable-version parsing and numerical comparison, GitHub response handling, daily check throttling, manual refresh, offline failures, corrupt-cache recovery, skipped prompts, failed downloads/builds/version checks, cancellation, concurrent-update exclusion, and atomic replacement failure.
- A real local Git tag was fetched into a fresh checkout, built with Swift in release configuration, checked for its expected version, and installed into a temporary prefix. This exercised the source updater without publishing a test release or changing the real installation.
- Update fixtures with spaces in their paths preserved both the Publish CLI and the shim.
- The release build reported `PublishDev 0.1.0`; update help and invalid-argument handling passed.
- The installer was run twice against an isolated custom prefix with spaces, using the already-built release executable. Both runs preserved the existing Publish CLI, and `publish dev --version` worked through the installed shim.
- The full terminal lifecycle harness passed against the release binary after moving signal handling to cover both updates and previews.
- The public repository endpoint returned HTTP 200 and its latest-release endpoint returned HTTP 404: no stable release is published yet.
- The release binary's `publish-dev update --check` succeeded against live GitHub and reported that no stable release is available. The checker uses macOS's built-in curl with a three-second limit; Foundation networking timed out in this environment while curl succeeded.

The tests exercise unprivileged atomic installation. The administrator password flow is implemented but was not exercised with real sudo credentials. A live upgrade from a published GitHub release and automatic restart into that published version remain untested until a newer release exists. The minimum Swift and macOS versions were not separately tested.

## Session lifecycle update — 24 September 2026

Validated with Xcode 27.1 beta (Swift 6.4) and Python 3.14.7 on Apple silicon macOS. The package’s minimum supported toolchain and OS were not separately tested.

Passed:

- All 10 Swift tests, including stale-lock recovery, lock symlink rejection, and readiness that cannot be satisfied by an unrelated listener.
- Strict Swift formatting lint and `git diff --check`.
- Release build.
- `Scripts/test-session.py` against the release executable: Return, Ctrl+C, Ctrl+D, SIGTERM, SIGHUP, closing the controlling pseudo-terminal, and SIGKILL all released the preview port.
- The stop hint appeared after successful and failed builds.
- Same-site and same-port replacement, default decline, and Ctrl+C during the replacement question.
- Replacement waited for an active build and its descendants to stop before the new session built the website.
- Unrelated port owners remained running while the new session used an offered alternative port.
- Noninteractive conflicts exited promptly without replacing the original session.
- Unverifiable session metadata did not authorize termination.
- Return and terminal closure during a build cleaned up a descendant that had created its own process group.

The terminal harness uses a deterministic fake `swift` command; Python serving, locks, process identities, pseudo-terminals, signals, and cancellation are real. Existing Swift tests also cover child command execution and HTTP serving. No real Publish website or browser UI was exercised in this update.

Tests used a clean build directory (`swift test --scratch-path /tmp/publishdev-session-build`) after the existing `.build` test bundle failed code signing because of filesystem metadata. The clean run passed. Release validation used the same scratch directory and the executable reported by `swift build -c release --show-bin-path` for that directory.

The Python parent watchdog handles abrupt parent death. SIGKILL cannot run PublishDev’s normal cleanup for build subprocesses or temporary files; the next session removes its stale preview directory.

## Earlier proof-of-concept validation

Validated on 9 September 2026 using stable Xcode 26.6 and Swift 6.3.3 on an Apple silicon Mac, with Python 3.14.7. The package requires Swift 6.2 and macOS 15; the minimum supported versions were not separately tested.

The HTTP layer was replaced after the first round of validation: FlyingFox is gone, and the preview is now served by `python3 -m http.server`, the same web server `publish run` starts. The sections below say which results were produced against the current design and which have not been re-run.

### Automated checks

`swift test` covers eight tests:

- Stage a build into the preview directory, inject the reload client into each page, and leave the website's own `Output` byte-for-byte unchanged.
- Keep the last successful preview when a build produces no `Output/index.html`, then pick up the recovery build and drop pages that were deleted.
- Reject an `Output` symlink and keep the previous preview.
- Serve the staged website end to end through Python: the revision endpoint, an injected page, a directory URL, a stylesheet's content type, the reload script, and a rebuild changing the served page and revision. This test also asserts that a second bind to the live port fails.
- Detect edits, atomic saves, renames, deletions, and additional watched inputs while excluding generated directories.
- Resolve relative watch paths against the website regardless of argument order.
- Preserve literal child-process arguments and report nonzero exit statuses.
- Cancel a child process and its descendant even when that descendant creates its own process group.

Swift formatting is checked with `swift format lint --strict --recursive Package.swift Sources Tests`.

### Session behaviour

Driven against a synthetic website package through a pseudo-terminal, so the ENTER handling is exercised the way a real terminal drives it. Passed checks:

- A browser opening before the first build finishes gets the waiting page, with the reload client and a working revision endpoint, so it refreshes by itself once the site is ready.
- Initial generation, local serving, directory redirects (`/help` → `/help/`), and a 404 for a missing path.
- Saving Markdown rebuilt the site, changed the served page, and changed the revision.
- The website's `Output/index.html` contained no injected script at any point.
- A Swift compilation failure left the previous preview serving the last good page, and the terminal reported the failure.
- ENTER stopped the session with exit status 0, leaving no `publish-dev` or `python3 -m http.server` process behind.
- Python's request log goes to a file in the preview directory rather than the terminal. This matters: the reload client polls several times a second, and an earlier build that inherited the terminal filled the pipe and wedged the server.

### Installer

Run against a sandbox `PREFIX`, never `/usr/local`:

- The plan is printed before anything is written, and answering anything but yes changes nothing.
- An existing `publish` binary is moved to `publish-cli` and the shim is written in its place.
- `publish` with no arguments prints the Publish CLI's own help with `dev` appended; `publish generate` reaches the CLI with its arguments intact; `publish dev --help` reaches PublishDev.
- Re-running the installer detects its own shim and the adopted `publish-cli`, and replaces only the shim.
- `make uninstall` removes the shim, moves `publish-cli` back to `publish`, and removes `publish-dev`.

### Not re-run in the earlier validation

- Integration with a real Publish 0.8.0 website. The earlier round used an isolated copy of the Otuli website and passed, but it exercised the FlyingFox server; the generation, watching, and process handling paths are unchanged, and the serving path is not.
- WebKit auto-refresh in an actual browser. The revision endpoint and reload script are covered by the tests above, but no real browser was driven after the change.
- The installer's bootstrap path, which clones and builds Publish 0.9.0 when no Publish CLI is present. It needs network access and a full Publish build.
- Timings. The snapshot step was replaced by a directory copy and exchange, so the numbers from the previous round no longer describe this build.
