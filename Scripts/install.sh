#!/bin/sh
#
# Project: PublishDev
# Author: Mark Battistella
# Website: https://markbattistella.com
#

# Installs `publish dev` by putting a small shim in front of the Publish CLI.
set -eu

PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
PUBLISH_REPO="${PUBLISH_REPO:-https://github.com/JohnSundell/Publish.git}"
PUBLISH_VERSION="${PUBLISH_VERSION:-0.9.0}"
MARKER="publish-dev-shim: 1"
ASSUME_YES="${PUBLISH_DEV_YES:-0}"
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SUDO=""
[ -d "$BINDIR" ] && [ ! -w "$BINDIR" ] && SUDO="sudo"

is_shim() { [ -f "$1" ] && grep -q "$MARKER" "$1" 2>/dev/null; }

# Work out what has to happen before touching anything.
BOOTSTRAP_PUBLISH=0
ADOPT_PUBLISH=0
if [ ! -x "$BINDIR/publish-cli" ]; then
    if is_shim "$BINDIR/publish"; then
        BOOTSTRAP_PUBLISH=1
    elif [ -e "$BINDIR/publish" ]; then
        ADOPT_PUBLISH=1
    else
        BOOTSTRAP_PUBLISH=1
    fi
fi

echo "PublishDev install plan"
echo "-----------------------"
echo "This changes files outside the project. Nothing is written until you agree."
echo
echo "  1. Build publish-dev in release configuration from $ROOT."
echo "  2. Install it as $BINDIR/publish-dev."
if [ "$ADOPT_PUBLISH" = 1 ]; then
    echo "  3. MOVE your existing Publish CLI:"
    echo "       $BINDIR/publish  ->  $BINDIR/publish-cli"
    echo "     This is the same binary, under the name Publish's own build uses."
elif [ "$BOOTSTRAP_PUBLISH" = 1 ]; then
    echo "  3. The Publish CLI is not installed, so build Publish $PUBLISH_VERSION from"
    echo "     $PUBLISH_REPO in a temporary checkout and install it as"
    echo "       $BINDIR/publish-cli"
else
    echo "  3. Keep the Publish CLI already at $BINDIR/publish-cli."
fi
if is_shim "$BINDIR/publish"; then
    echo "  4. Replace the PublishDev shim already at $BINDIR/publish."
else
    echo "  4. Write a shell shim at $BINDIR/publish that runs publish-dev for"
    echo "     \`publish dev\` and publish-cli for every other command."
fi
[ -n "$SUDO" ] && echo && echo "  $BINDIR is not writable, so sudo is used for the steps above."
echo
echo "Undo all of this with: make uninstall"
echo

if [ "$ASSUME_YES" != 1 ]; then
    printf "Proceed? [y/N] "
    read -r reply </dev/tty || reply=""
    case "$reply" in
    [yY] | [yY][eE][sS]) ;;
    *)
        echo "Cancelled. Nothing was changed."
        exit 1
        ;;
    esac
fi

echo
echo "==> Building publish-dev"
swift build --package-path "$ROOT" -c release
BUILD_BIN=$(swift build --package-path "$ROOT" -c release --show-bin-path)
$SUDO mkdir -p "$BINDIR"
$SUDO install "$BUILD_BIN/publish-dev" "$BINDIR/publish-dev"
echo "    Installed $BINDIR/publish-dev"

if [ "$ADOPT_PUBLISH" = 1 ]; then
    echo "==> Moving your Publish CLI to $BINDIR/publish-cli"
    $SUDO mv "$BINDIR/publish" "$BINDIR/publish-cli"
elif [ "$BOOTSTRAP_PUBLISH" = 1 ]; then
    echo "==> Building the Publish CLI $PUBLISH_VERSION"
    CHECKOUT=$(mktemp -d)
    trap 'rm -rf "$CHECKOUT"' EXIT
    git clone --depth 1 --branch "$PUBLISH_VERSION" "$PUBLISH_REPO" "$CHECKOUT/Publish"
    swift build --package-path "$CHECKOUT/Publish" -c release
    $SUDO install "$CHECKOUT/Publish/.build/release/publish-cli" "$BINDIR/publish-cli"
    echo "    Installed $BINDIR/publish-cli"
fi

echo "==> Writing the publish shim"
SHIM=$(mktemp)
cat >"$SHIM" <<'SHIM_BODY'
#!/bin/sh
# publish — installed by PublishDev. Routes `publish dev` to publish-dev and
# every other command to publish-cli, the unmodified Publish CLI.
# publish-dev-shim: 1
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "${1:-}" = "dev" ]; then
    shift
    exec "$DIR/publish-dev" "$@"
fi

if [ ! -x "$DIR/publish-cli" ]; then
    echo "publish: the Publish CLI is missing from $DIR/publish-cli." >&2
    echo "publish: only \`publish dev\` is available. Reinstall it with PublishDev's 'make install'." >&2
    exit 1
fi

if [ $# -eq 0 ]; then
    "$DIR/publish-cli"
    cat <<'EXTRA'
- dev: Generate and run a local server for the website in the current
       folder, rebuilding and refreshing the browser whenever an input
       changes. Use "--help" for its options. Added by PublishDev.
EXTRA
    exit 0
fi

exec "$DIR/publish-cli" "$@"
SHIM_BODY
chmod 755 "$SHIM"
$SUDO install -m 755 "$SHIM" "$BINDIR/publish"
rm -f "$SHIM"

echo
echo "Done."
echo "  $BINDIR/publish      shim"
echo "  $BINDIR/publish-cli  Publish CLI ($("$BINDIR/publish-cli" 2>/dev/null | head -1 || echo "installed"))"
echo "  $BINDIR/publish-dev  $("$BINDIR/publish-dev" --version)"
echo "Future releases: publish dev update"
echo
case ":$PATH:" in
*":$BINDIR:"*) echo "Try it: cd to a website and run 'publish dev'." ;;
*) echo "Note: $BINDIR is not on your PATH. Add it, then run 'publish dev'." ;;
esac
