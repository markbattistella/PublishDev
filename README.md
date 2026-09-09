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

## Run

From a website directory:

```sh
publish dev
```

Open `http://localhost:8000` and keep the terminal running. Save an input to rebuild. **Press ENTER to stop the server and exit**, the same as `publish run`. Control-C also works.

```sh
publish dev --port 8080 --product MyWebsite --site /path/to/website
```

`--site` defaults to the current directory. `--product` is required when the website declares more than one executable product. Use `publish dev --help` for all options.

The tool uses the `swift` and `python3` commands on your PATH and inherits your environment, including `DEVELOPER_DIR`.

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

1. Start `python3 -m http.server PORT --bind 127.0.0.1 --directory PREVIEW`, the same web server `publish run` uses, on a preview directory in your temporary folder. It shows a waiting page until the first successful build.
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
make test    # or: swift test
make lint
```

The tests cover preview staging and injection, failure retention, symlink rejection, end-to-end serving through Python, input changes, option parsing, and child command execution. See [VALIDATION.md](VALIDATION.md) for the integration results.
