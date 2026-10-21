#!/usr/bin/env bash
# §4 + §10.2 — build PHP for one (minor, target).
#
#   unix (macos/linux): static-php-cli — clone the pinned spc ref, apply the §3
#     curl.php patch, download, build CLI + FPM, (macOS) ad-hoc sign
#         -> $SPC_DIR/buildroot/bin/{php,php-fpm}
#   windows: NOT spc — repackage the official windows.php.net NTS build into a
#     directory bundle (§W in config.sh); delegates to repackage-windows.sh
#         -> $WIN_OUT/php/{php.exe,php-cgi.exe,php8.dll,ext/,...}
# Packaging is a separate step.
#
# usage: build-target.sh <minor> <os> [php-version]
#   php-version (full x.y.z) is REQUIRED for windows (the exact windows.php.net
#   build to fetch) and ignored for unix (spc resolves the latest patch itself).
#   CI passes the resolved matrix.php; scripts/build-local.sh resolves it locally.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

MINOR="${1:?usage: build-target.sh <minor> <os> [php-version]}"
OS="${2:?usage: build-target.sh <minor> <os> [php-version]}"
PHP_VER="${3:-}"

# --- Windows leg — repackage, not spc (see §W in config.sh) -------------------
# Windows uses a completely different model, so it branches out here before any
# static-php-cli machinery runs.
if [ "$OS" = "windows" ]; then
  [ -n "$PHP_VER" ] || { echo "FATAL: windows needs the full php version as arg 3 (e.g. 8.4.24) — CI passes matrix.php; use scripts/build-local.sh locally"; exit 1; }
  WIN_OUT="${WIN_OUT:-$PWD/winbuild}"
  bash "$here/repackage-windows.sh" "$PHP_VER" x86_64 "$WIN_OUT"
  echo "build-target: $MINOR/$OS complete -> $WIN_OUT/php"
  exit 0
fi

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

# ALL CHANNELS — pin OpenLDAP to 2.6.14 in config/source.json BEFORE `spc download`
# reads it. spc sources ldap as an unpinned `filelist`, so it rolled onto OpenLDAP
# 2.7.0 the day upstream published it; 2.7.0's tls_o.c declares variables after a
# case label, which gcc rejects under its default -std=gnu17 and which broke every
# Linux leg. ldap can't be avoided by trimming EXTENSIONS — it's a lib-suggests of
# both postgresql and krb5, and we build --with-suggested-libs. Fails loud if it
# no-ops. See the script header for the full rationale.
bash "$here/apply-ldap-pin-patch.sh" "$SPC_DIR"

# ALL CHANNELS — pin swoole to v6.2.2 in config/source.json, same reason: spc
# sources it as an unpinned `ghtar` ("v6\.+"), so it rolled onto 6.2.3, whose new
# non-Linux futex fallback calls an undeclared sw_usleep() and broke every macOS
# leg. Fails loud if it no-ops. See the script header for the full rationale.
bash "$here/apply-swoole-pin-patch.sh" "$SPC_DIR"

# LEGACY ONLY — two source-level pins applied to the fresh spc checkout BEFORE any
# spc command reads its config. EOL minors need both; stable is unaffected and
# left untouched. Each patch fails loud if it no-ops (an spc refactor must be
# caught, not silently skipped).
#   1. -std=gnu17: 7.4/8.0/8.1 bundle K&R-style libbcmath that won't compile
#      under the compiler's new C23 default. Patches config/env.ini. On macOS it
#      also appends -Wno-error=incompatible-function-pointer-types, demoting the
#      clang default-error from 7.4/8.0's non-const libxml2 error handler (const
#      since libxml2 2.12) back to the warning Linux gcc already tolerates.
#   2. libxml2 -> 2.13.x + libxslt -> 1.1.43: 2.14 dropped the ATTRIBUTE_UNUSED
#      macro that 7.4/8.0's ext/libxml/libxml.c relies on, and spc's libxslt
#      requires libxml2 >= 2.15.1 so it must drop back in lockstep. Patches
#      config/source.json — MUST precede `spc download` so the pins are fetched.
if [ "${CHANNEL:-stable}" = "legacy" ]; then
  bash "$here/apply-legacy-cflags-patch.sh" "$SPC_DIR" "$OS"
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
#   spc-patch-legacy-zend-string-asm.php — route clang to the memcmp
#       zend_string_equal_val fallback instead of PHP's x86_64 inline asm, which
#       Xcode clang miscompiles into a stack-smash at module startup (arm64 and
#       Linux gcc are unaffected; self-gates on the asm guard being present).
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
  for p in spc-patch-legacy-intl-cxx17.php spc-patch-legacy-gd-linktest.php spc-patch-legacy-zend-string-asm.php; do
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
