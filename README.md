# PublishDev

`publish dev` — a macOS development companion for [Publish](https://github.com/JohnSundell/Publish). Save Markdown, resources, or Swift source; PublishDev regenerates the website and refreshes the browser after a successful build.

Publish has no plugin hook for new commands, so PublishDev installs a small shim in front of the Publish CLI rather than forking it. `publish dev` runs PublishDev; every other command reaches the unmodified Publish CLI. Your website's Swift code is untouched.

## Requirements

- macOS 15 or newer.
- Swift 6.2 or newer, with an Xcode toolchain that can build your website.
- Python 3, the same requirement `publish run` already has.
- A Swift package with an executable that generates `Output/index.html`.

There are no Swift package dependencies.

## Install

```sh
make install
```

The installer prints every change it will make outside the project and waits for you to agree. It:

1. Builds `publish-dev` in release configuration and installs it to `/usr/local/bin/publish-dev`.
2. Moves an existing `/usr/local/bin/publish` to `/usr/local/bin/publish-cli`, the name Publish's own build uses. If Publish is not installed at all, it builds Publish 0.9.0 in a temporary checkout and installs `publish-cli` for you.
3. Writes a shell shim at `/usr/local/bin/publish` that runs `publish-dev` for `publish dev` and `publish-cli` for everything else.

`publish` with no arguments still prints Publish's own help, with `dev` added to the list. Use `PREFIX=~/.local make install` for a different location, and `make uninstall` to remove the shim and put the Publish CLI back as `publish`.

## Update an existing installation

To install changes from this checkout, stop your preview and run `make install` again. Use the same `PREFIX` if you originally installed somewhere other than `/usr/local`. Existing installations need this manual update once to receive the release updater.

```sh
publish dev --version
publish dev update --check  # Check GitHub without installing
publish dev update          # Confirm, build, and install a newer release
publish dev update --yes    # Explicitly approve installation without an update prompt
```

An installed copy checks for a newer stable GitHub release before starting an interactive preview, at most once per 24 hours. It shows the available version and release link, then asks `Update now? [y/N]`. Return skips the update for that day. Accepting builds and installs the release, then restarts your original preview command with the new version. Manual `update` commands always check GitHub immediately.

Checks have a three-second network timeout. Offline checks and API errors do not prevent previewing. Use `publish dev --no-update-check` or set `PUBLISH_DEV_NO_UPDATE_CHECK=1` to disable automatic checks. Development checkouts and noninteractive previews do not check automatically. The last check time is stored in `~/Library/Caches/PublishDev/update-check.json`.

Updates require Git and a Swift toolchain capable of building the selected release. PublishDev downloads the exact release tag from this repository into a temporary directory, builds it, and checks its reported version. It then stages the new executable beside the installed one and renames it into place. A failed download, build, or verification leaves the existing executable working. Updates preserve your install location, Publish CLI, shim, and website files, and only one update per user and install location can run at a time.

Run the updater as your normal user. If the install directory requires administrator access, only the final installation uses `sudo`; the source build runs as you. Noninteractive updates need `--yes` and pre-authorized installation permissions. Drafts, prereleases, and tags other than stable `vMAJOR.MINOR.PATCH` (or `MAJOR.MINOR.PATCH`) are not installed.

## Run

From a website directory:

```sh
publish dev
```

Open `http://localhost:8000` and keep the terminal running. Save an input to rebuild. **Press Return or Ctrl+C to stop the server and exit.** The reminder appears at startup and after every build, including failures. Ctrl+D also stops the session.

```sh
publish dev --port 8080 --product MyWebsite --site /path/to/website
```

`--site` defaults to the current directory. `--product` is required when the website declares more than one executable product. Use `publish dev --help` for all options.

The tool uses the `swift` and `python3` commands on your PATH and inherits your environment, including `DEVELOPER_DIR`.

## Stopping and restarting

Return, Ctrl+C, Ctrl+D, SIGTERM, and terminal hangup all stop the server and cancel an active build. Shutdown waits for child-process cleanup before releasing the website and port locks. Python also watches its parent, so force-killing PublishDev does not leave the preview server occupying its port.

When another verified PublishDev session owns the website or port, an interactive terminal offers to stop it and restart here. The prompt shows the website, port, and process ID; Return defaults to **no**. Replacement checks the process owner, executable path, and start time again before sending SIGTERM, then waits up to 10 seconds for the session to release its lock. An older or unverifiable session must be stopped in its own terminal.

If an unrelated application occupies the port, PublishDev offers an available port among the next 100 port numbers. It never terminates an unknown port owner. The printed preview address reflects the selected port. Noninteractive runs report conflicts and exit without prompting or replacing another session.

Force-killing PublishDev bypasses its normal build and temporary-file cleanup. The Python watchdog still frees the preview port; an active compiler or custom build subprocess may need separate cleanup. A later session removes the stale preview directory. Use Return or Ctrl+C when possible.

## Inputs from a larger workspace

By default, PublishDev watches `Content`, `Resources`, `Sources`, `Package.swift`, and `Package.resolved`. Add other inputs with repeatable `--watch` arguments. Relative watch paths are resolved against the website directory. Missing files remain watched so creating them triggers a build.

For an Otuli-style workspace with release metadata outside the website:

```sh
publish dev --site /path/to/otuli/website \
  --watch ../assets/app-store-connect/current-release.json \
  --watch ../app/OtuliShared/shared.xcconfig \
  --watch ../assets/otuli-screenshots.butterkit/Document.json
```

`Output`, `.build`, `.publish`, `.git`, and `.swiftpm` directories are excluded from watching. Avoid watching the whole app repository; list the files that affect the website. Directory symlinks are not traversed during input polling; explicitly watch the target if its contents affect generation.

## How it works

1. Start Python’s `http.server` module, bound to `127.0.0.1`, on a preview directory in your temporary folder. A small wrapper adds a parent watchdog and a readiness notification. It shows a waiting page until the first successful build.
2. Poll input metadata every 250 ms. Combine bursts of changes after a short quiet period.
3. Identify the website's executable, then run `swift run PRODUCT` in its package directory. Builds run serially; a save during a build queues another build.
4. Copy `Output` into a staging directory beside the served one, inject the reload script into every page, write the new revision, then exchange the two directories in a single step. The preview only ever changes once a build has been staged completely.
5. The browser checks `/__publish_dev/revision.txt` every 750 ms and refreshes when it changes.

Build errors appear in the terminal. The server continues serving the previous successful preview and retries after the next input change. An already-open page reconnects automatically after the tool restarts.

The reload script is never written to `Output`; it only exists in the preview copy. Normal website generation and deployment do not depend on PublishDev. Like running the website yourself, development generation writes the website's usual `Output`, `.build`, and `.publish` files. If your custom pipeline has other side effects, it will still run those steps on every rebuild.

Two PublishDev sessions cannot generate the same website at the same time. This does not coordinate with independent builds from Xcode, `swift run`, or `publish generate`; use one generation workflow at a time.

## Proof-of-concept limits

- Full site generation and full page refresh. Browser form values and other page state are not preserved.
- Swift changes include compilation time; Markdown and resources still incur SwiftPM's build check.
- Input detection uses modification time, size, and inode. Changes that preserve all three may require touching a watched file to trigger generation.
- Each build copies `Output` into the preview directory, so generation costs one extra pass over the generated files.
- A site's own `404.html` is not served for missing paths; Python's standard 404 page is, exactly as with `publish run`.
- Output symlinks are rejected. Copy those resources into the output instead.
- Python's server sends no cache-control headers and answers `If-Modified-Since` at whole-second resolution, so staged files are dated ahead of the build they replace to keep revalidation honest.
- `__publish_dev` is reserved for development endpoints. A site's Content Security Policy or service worker can interfere with script loading/polling; those setups have not been integrated.
- The server binds `127.0.0.1` only. HTTPS, LAN access, and production hosting are outside this version's scope.
- There is no SwiftPM command plugin. The shim proves the workflow before adding plugin sandbox and build coordination requirements.

## Verification

```sh
make test          # or: swift test
make test-session  # terminal, replacement, and shutdown integration checks
make lint
```

The Swift tests cover preview staging and injection, failure retention, symlink rejection, server readiness, input changes, option parsing, child command execution, and stale session locks. The terminal checks use a deterministic build fixture with real Python serving, pseudo-terminals, signals, and process cleanup. See [VALIDATION.md](VALIDATION.md) for the integration results.

The **Validate changes** workflow runs on branch pushes and pull requests, and can be started manually. It runs the tests, formatting checks, release build, and terminal checks on the same macOS and Swift toolchain as release validation, without creating a tag or publishing a release. When troubleshooting CI, push the fix as a normal commit and wait for this check before releasing.

## Publishing a release

Commit your code and release notes as usual, then release with one command:

```sh
make release VERSION=1.0.0
```

This command:

1. Checks the branch, working tree, remote, and existing tags before changing the version.
2. Updates `ReleaseVersion.current` in `Sources/PublishDev/ReleaseVersion.swift` and commits it as `Release 1.0.0`. An already-prepared version bump is also accepted; an already-committed version needs no extra commit.
3. Creates the matching annotated tag.
4. Pushes the current branch and tag to `origin` together with an atomic push. Both arrive, or neither does.

You do not need to push the branch first, tag manually, or create a GitHub Release. The command pushes any existing commits on the current branch too. Only the version bump is committed automatically: staged, unstaged, or untracked changes to other files must be committed first. Edits elsewhere in the version file must also be committed first. Existing Git hooks still run.

If a commit or push fails, the command keeps local progress and prints a retry command. Fix the reported issue and rerun the same `make release VERSION=...`; a local tag is reused only when it points at the current, clean, matching commit. Existing remote tags are never overwritten. Behind or diverged branches must be reconciled first, and remotes without atomic push support fail without a partial push.

The preparation and check commands remain available as optional local steps:

```sh
make prepare-release VERSION=1.0.0  # prompts to edit the version only; release-version is an alias
make check-release VERSION=1.0.0   # checks the source without committing or publishing
```

After the tag is pushed, the **Validate and publish release** GitHub Actions workflow:

1. Checks out that exact tag and rejects a source-version mismatch with an explanation and repair command.
2. Runs the release-tool tests, Swift formatting checks, and Swift tests.
3. Builds the release executable, verifies its `--version` output matches the tag, and runs the terminal session checks.
4. Confirms the remote tag still points to the tested commit, then publishes a GitHub Release with generated release notes. An existing release is left unchanged.

A failed check prevents this workflow from publishing. Both `1.0.0` and `v1.0.0` tag styles work. Use an unused stable version; prerelease tags are rejected. Once the workflow publishes successfully, installed copies can discover it through `publish dev update`. No binary release assets are needed because the updater builds the tagged source on each user's Mac.

**Use `make release` and let the workflow publish it.** Creating a release manually through GitHub publishes it before validation runs. The workflow also checks manually published or edited releases, but it cannot prevent that initial publication or automatically retract it. If a bad release is already public, unpublish it and release a fresh version rather than moving a published tag.

The workflow and helper must be committed into the release's tagged source. Older tags that predate the workflow are not retroactively protected. The workflow requests `contents: write` only for its publishing job; repository or organization policies must allow that permission. Its read-only validation job uses Xcode 26.2 on `macos-15` for Swift 6.2 support. The Actions **Run workflow** form can validate an existing tag without publishing anything.

Run `make test-release` to exercise the release helper locally. The source version is still the single release-version authority; fixing it before tagging keeps the tag and the updater's built-version check consistent.
