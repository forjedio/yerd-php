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

# static-php-cli is a Composer project: a git checkout has no vendor/, so bin/spc
# can't autoload until its deps are installed. (The gnu-docker wrapper installs
# deps inside the container, but the native bin/spc runs on the host and needs
# this.) Canonical setup step — must run before any bin/spc invocation.
composer install --no-dev --no-interaction --optimize-autoloader

# LEGACY ONLY — two source-level pins applied to the fresh spc checkout BEFORE any
# spc command reads its config. EOL minors need both; stable is unaffected and
# left untouched. Each patch fails loud if it no-ops (an spc refactor must be
# caught, not silently skipped).
#   1. -std=gnu17: 7.4/8.0/8.1 bundle K&R-style libbcmath that won't compile
#      under the compiler's new C23 default. Patches config/env.ini.
#   2. libxml2 -> 2.13.x + libxslt -> 1.1.43: 2.14 dropped the ATTRIBUTE_UNUSED
#      macro that 7.4/8.0's ext/libxml/libxml.c relies on, and spc's libxslt
#      requires libxml2 >= 2.15.1 so it must drop back in lockstep. Patches
#      config/source.json — MUST precede `spc download` so the pins are fetched.
if [ "${CHANNEL:-stable}" = "legacy" ]; then
  bash "$here/apply-legacy-cflags-patch.sh" "$SPC_DIR"
  bash "$here/apply-legacy-libxml-patch.sh" "$SPC_DIR"
fi

# Effective extension set for THIS minor — never $EXTENSIONS directly (an EOL
# minor may reject a member the rest of the channel keeps, e.g. opcache on 7.4).
EXTS="$(extensions_for_minor "$MINOR")"

# --- Build pipeline (§4) ------------------------------------------------------
"$CMD" doctor --auto-fix
"$CMD" download --with-php="$MINOR" --for-extensions="$EXTS" --prefer-pre-built --retry=5

# §3 — MUST run after download, before build. Fails the build if it no-ops.
"$here/apply-curl-patch.sh" "$SPC_DIR"

# --with-suggested-libs still pulls libcares in (swoole needs it); harmless
# because §3 forced ENABLE_ARES=OFF so curl never uses it.
#
# LEGACY ONLY — inject php-src source backports for EOL minors via spc's
# --with-added-patch hook (each fires at before-php-buildconf and self-gates on the
# PHP version, so higher minors / stable are untouched):
#   spc-patch-legacy-intl-cxx17.php  (PHP < 8.1) — force ext/intl to C++17 so it
#       compiles against spc's modern ICU (>= 75 needs C++17).
#   spc-patch-legacy-gd-linktest.php (PHP < 8.0) — make 7.4's PHP_TEST_BUILD
#       link-only (AC_RUN_IFELSE -> AC_LINK_IFELSE, as 8.0 did) so the GD build
#       test doesn't execute a probe that segfaults on the macOS runner.
#
# The Linux build runs spc INSIDE the gnu-docker container, which mounts only
# $SPC_DIR/{config,src,source,...} -> /app/*; the repo's scripts/ dir is NOT
# mounted, so a host path to a patch is invisible in-container (spc aborts:
# "Additional patch script file ... not found"). Copy each script into the mounted
# config/ dir and reference it by the path valid for THIS runtime — an absolute
# host path for native macOS, the in-container /app path for Linux docker.
# build_args is an array so the empty-stable case is safe under `set -u` on the
# macOS runner's bash 3.2.
build_args=(build --build-cli --build-fpm "$EXTS" --with-suggested-libs)
if [ "${CHANNEL:-stable}" = "legacy" ]; then
  case "$OS" in
    macos) patch_base="$SPC_DIR/config" ;;
    linux) patch_base="/app/config" ;;   # docker mount of $SPC_DIR/config
  esac
  for p in spc-patch-legacy-intl-cxx17.php spc-patch-legacy-gd-linktest.php; do
    cp "$here/$p" "$SPC_DIR/config/$p"
    build_args+=(--with-added-patch="$patch_base/$p")
  done
fi
"$CMD" "${build_args[@]}"

for b in buildroot/bin/php buildroot/bin/php-fpm; do
  [ -f "$b" ] || { echo "FATAL: expected artifact $b missing after build"; exit 1; }
done

# --- macOS ad-hoc signing (§4) — MANDATORY on Apple Silicon, BOTH binaries ----
if [ "$OS" = "macos" ]; then
  "$here/sign-macos.sh" buildroot/bin/php buildroot/bin/php-fpm
fi

echo "build-target: $MINOR/$OS complete -> $SPC_DIR/buildroot/bin/{php,php-fpm}"
