#!/bin/sh
#
# Project: PublishDev
# Author: Mark Battistella
# Website: https://markbattistella.com
#

# Removes the shim and puts the Publish CLI back where it was.
set -eu

PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
MARKER="publish-dev-shim: 1"
ASSUME_YES="${PUBLISH_DEV_YES:-0}"
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

SUDO=""
[ -d "$BINDIR" ] && [ ! -w "$BINDIR" ] && SUDO="sudo"

is_shim() { [ -f "$1" ] && grep -q "$MARKER" "$1" 2>/dev/null; }

RESTORE=0
if is_shim "$BINDIR/publish" && [ -x "$BINDIR/publish-cli" ]; then RESTORE=1; fi

echo "PublishDev uninstall plan"
echo "-------------------------"
if is_shim "$BINDIR/publish"; then
    echo "  1. Remove the PublishDev shim at $BINDIR/publish."
elif [ -e "$BINDIR/publish" ]; then
    echo "  1. Leave $BINDIR/publish alone; it is not a PublishDev shim."
else
    echo "  1. Nothing to remove at $BINDIR/publish."
fi
if [ "$RESTORE" = 1 ]; then
    echo "  2. MOVE $BINDIR/publish-cli back to $BINDIR/publish, so the"
    echo "     Publish CLI answers to 'publish' again."
else
    echo "  2. Leave $BINDIR/publish-cli alone."
fi
if [ -e "$BINDIR/publish-dev" ]; then
    echo "  3. Remove $BINDIR/publish-dev."
else
    echo "  3. Nothing to remove at $BINDIR/publish-dev."
fi
[ -n "$SUDO" ] && echo && echo "  $BINDIR is not writable, so sudo is used for the steps above."
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

if is_shim "$BINDIR/publish"; then $SUDO rm -f "$BINDIR/publish"; fi
if [ "$RESTORE" = 1 ]; then $SUDO mv "$BINDIR/publish-cli" "$BINDIR/publish"; fi
$SUDO rm -f "$BINDIR/publish-dev"
echo
echo "Done."
