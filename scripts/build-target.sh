#!/usr/bin/env bash
# §4 + §10.2 — build CLI+FPM for one (minor, target) with static-php-cli.
#
# Clones the pinned spc ref, applies the §3 curl.php patch, downloads sources,
# builds, and (on macOS) ad-hoc signs both binaries. Leaves the two binaries at
# $SPC_DIR/buildroot/bin/{php,php-fpm}. Packaging is a separate step (§1 shape).
#
# usage: build-target.sh <minor> <os>
#   <os> selects the spc wrapper (bin/spc on macOS, bin/spc-gnu-docker on Linux).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

MINOR="${1:?usage: build-target.sh <minor> <os>}"
OS="${2:?usage: build-target.sh <minor> <os>}"

SPC_DIR="${SPC_DIR:-$PWD/static-php-cli}"
case "$OS" in
  macos) CMD="bin/spc" ;;
  linux) CMD="bin/spc-gnu-docker" ;;   # glibc container, NOT musl (§1 hard req)
  *) echo "FATAL: unknown os '$OS'"; exit 1 ;;
esac

# --- Obtain the pinned static-php-cli checkout --------------------------------
if [ ! -d "$SPC_DIR/.git" ]; then
  git clone --depth 1 --branch "$SPC_REF" "$SPC_REPO" "$SPC_DIR"
else
  git -C "$SPC_DIR" fetch --depth 1 origin "$SPC_REF"
  git -C "$SPC_DIR" checkout -f FETCH_HEAD
  git -C "$SPC_DIR" clean -fdx src   # drop any prior .bak / patch residue
fi

cd "$SPC_DIR"

# --- Build pipeline (§4) ------------------------------------------------------
"$CMD" doctor --auto-fix
"$CMD" download --with-php="$MINOR" --for-extensions="$EXTENSIONS" --prefer-pre-built --retry=5

# §3 — MUST run after download, before build. Fails the build if it no-ops.
"$here/apply-curl-patch.sh" "$SPC_DIR"

# --with-suggested-libs still pulls libcares in (swoole needs it); harmless
# because §3 forced ENABLE_ARES=OFF so curl never uses it.
"$CMD" build --build-cli --build-fpm "$EXTENSIONS" --with-suggested-libs

for b in buildroot/bin/php buildroot/bin/php-fpm; do
  [ -f "$b" ] || { echo "FATAL: expected artifact $b missing after build"; exit 1; }
done

# --- macOS ad-hoc signing (§4) — MANDATORY on Apple Silicon, BOTH binaries ----
if [ "$OS" = "macos" ]; then
  "$here/sign-macos.sh" buildroot/bin/php buildroot/bin/php-fpm
fi

echo "build-target: $MINOR/$OS complete -> $SPC_DIR/buildroot/bin/{php,php-fpm}"
