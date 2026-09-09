# Proof-of-concept validation

Validated on 9 September 2026 using stable Xcode 26.6 and Swift 6.3.3 on an Apple silicon Mac, with Python 3.14.7. The package requires Swift 6.2 and macOS 15; the minimum supported versions were not separately tested.

The HTTP layer was replaced after the first round of validation: FlyingFox is gone, and the preview is now served by `python3 -m http.server`, the same web server `publish run` starts. The sections below say which results were produced against the current design and which have not been re-run.

## Automated checks

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

## Session behaviour

Driven against a synthetic website package through a pseudo-terminal, so the ENTER handling is exercised the way a real terminal drives it. Passed checks:

- A browser opening before the first build finishes gets the waiting page, with the reload client and a working revision endpoint, so it refreshes by itself once the site is ready.
- Initial generation, local serving, directory redirects (`/help` → `/help/`), and a 404 for a missing path.
- Saving Markdown rebuilt the site, changed the served page, and changed the revision.
- The website's `Output/index.html` contained no injected script at any point.
- A Swift compilation failure left the previous preview serving the last good page, and the terminal reported the failure.
- ENTER stopped the session with exit status 0, leaving no `publish-dev` or `python3 -m http.server` process behind.
- Python's request log goes to a file in the preview directory rather than the terminal. This matters: the reload client polls several times a second, and an earlier build that inherited the terminal filled the pipe and wedged the server.

## Installer

Run against a sandbox `PREFIX`, never `/usr/local`:

- The plan is printed before anything is written, and answering anything but yes changes nothing.
- An existing `publish` binary is moved to `publish-cli` and the shim is written in its place.
- `publish` with no arguments prints the Publish CLI's own help with `dev` appended; `publish generate` reaches the CLI with its arguments intact; `publish dev --help` reaches PublishDev.
- Re-running the installer detects its own shim and the adopted `publish-cli`, and replaces only the shim.
- `make uninstall` removes the shim, moves `publish-cli` back to `publish`, and removes `publish-dev`.

## Not re-run against the current design

- Integration with a real Publish 0.8.0 website. The earlier round used an isolated copy of the Otuli website and passed, but it exercised the FlyingFox server; the generation, watching, and process handling paths are unchanged, and the serving path is not.
- WebKit auto-refresh in an actual browser. The revision endpoint and reload script are covered by the tests above, but no real browser was driven after the change.
- The installer's bootstrap path, which clones and builds Publish 0.9.0 when no Publish CLI is present. It needs network access and a full Publish build.
- Timings. The snapshot step was replaced by a directory copy and exchange, so the numbers from the previous round no longer describe this build.
