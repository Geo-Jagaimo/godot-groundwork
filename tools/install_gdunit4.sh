#!/usr/bin/env bash
# Installs gdUnit4 (test framework, dev-only) into addons/gdUnit4.
# gdUnit4 v5.x supports Godot 4.3 - 4.4.x; use v6.x for Godot 4.5+.
set -euo pipefail

VERSION="${GDUNIT4_VERSION:-v5.1.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/addons/gdUnit4"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git clone --quiet --depth 1 --branch "$VERSION" https://github.com/MikeSchulze/gdUnit4.git "$TMP/gdUnit4"
rm -rf "$DEST"
cp -R "$TMP/gdUnit4/addons/gdUnit4" "$DEST"
rm -rf "$DEST/test"
echo "gdUnit4 $VERSION installed to $DEST"
