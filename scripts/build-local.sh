#!/usr/bin/env bash
# Local one-shot: build + verify + package PHP for ONE (minor, os, arch) on THIS
# machine, into ./dist. The "rebuild PHP per version per OS so we can test it
# first" entrypoint — it runs the same three steps CI runs per matrix entry
# (build-target -> verify-artifact -> package-artifacts), just for the host.
#
#   unix (macos/linux): static-php-cli build -> cli + fpm single-file tarballs
#   windows           : repackage official NTS build -> one directory bundle
#
# usage: scripts/build-local.sh <minor> [os] [arch]
#   os   defaults to the host os   (macos|linux|windows)
#   arch defaults to the host arch (windows is x86_64-only)
#   PHP_VERSION=x.y.z pins the exact patch (windows); default = latest for <minor>.
#
# Examples:
#   scripts/build-local.sh 8.4                 # host os/arch, latest 8.4 patch
#   scripts/build-local.sh 8.4 windows         # windows bundle, latest 8.4 patch
#   PHP_VERSION=8.4.24 scripts/build-local.sh 8.4 windows
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

MINOR="${1:?usage: build-local.sh <minor> [os] [arch]}"

detect_os()   { case "$(uname -s)" in Darwin) echo macos;; Linux) echo linux;; MINGW*|MSYS*|CYGWIN*|Windows_NT) echo windows;; *) echo unknown;; esac; }
detect_arch() { case "$(uname -m)" in arm64|aarch64) echo aarch64;; x86_64|amd64) echo x86_64;; *) echo unknown;; esac; }
OS="${2:-$(detect_os)}"
ARCH="${3:-$(detect_arch)}"
[ "$OS" = windows ] && ARCH=x86_64      # windows is x86_64-only (§1)
if [ "$OS" = unknown ] || [ "$ARCH" = unknown ]; then
  echo "FATAL: could not detect os/arch (got '$OS'/'$ARCH') — pass them explicitly"; exit 1
fi

# Resolve the latest patch for a minor from php.net without jq (grep-only), so a
# bare Windows box can run this. Used to name/fetch the exact windows build.
resolve_latest() {
  curl -fsSL --retry 5 "https://www.php.net/releases/?json&version=$1" \
    | grep -oE '"version":"[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

REV="${REV:-0}"        # the §7 revision machinery is a release concern; local = 0
mkdir -p "$PWD/dist"

if [ "$OS" = windows ]; then
  PHP_VER="${PHP_VERSION:-$(resolve_latest "$MINOR")}"
  [ -n "$PHP_VER" ] || { echo "FATAL: could not resolve latest patch for $MINOR"; exit 1; }
  WIN_OUT="${WIN_OUT:-$PWD/winbuild}"; export WIN_OUT
  echo "== [1/3] build $PHP_VER windows-$ARCH (repackage) =="
  bash "$here/build-target.sh" "$MINOR" windows "$PHP_VER"
  TREE="$WIN_OUT/php"
  BIN="$TREE/php.exe"; SAPI2="$TREE/php-cgi.exe"; PKG_DIR="$TREE"
else
  SPC_DIR="${SPC_DIR:-$PWD/static-php-cli}"; export SPC_DIR
  echo "== [1/3] build $MINOR $OS-$ARCH (static-php-cli) =="
  bash "$here/build-target.sh" "$MINOR" "$OS"
  BIN="$SPC_DIR/buildroot/bin/php"; SAPI2="$SPC_DIR/buildroot/bin/php-fpm"; PKG_DIR="$SPC_DIR/buildroot/bin"
  [ -f "$BIN" ] || { echo "FATAL: build produced no $BIN"; exit 1; }
  PHP_VER="$("$BIN" -r 'echo PHP_VERSION;')"
fi

echo "== [2/3] verify =="
bash "$here/verify-artifact.sh" "$BIN" "$SAPI2" "$MINOR" "$OS" "$ARCH"

echo "== [3/3] package -> ./dist =="
bash "$here/package-artifacts.sh" "$PHP_VER" "$REV" "$OS" "$ARCH" "$PKG_DIR" "$PWD/dist"

echo
echo "== done: $PHP_VER (rev $REV) $OS-$ARCH =="
ls -la "$PWD/dist"
