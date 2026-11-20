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
case "$OS" in macos|linux) : ;; *) echo "FATAL: unknown os '$OS'"; exit 1 ;; esac

# --- Obtain the pinned static-php-cli checkout --------------------------------
# init + fetch rather than `clone --branch`: SPC_REF is a tag for v2 but a commit
# SHA for v3 (no v3 tags yet), and `clone --branch` can't take a SHA. checkout -f
# also reverts every tracked file a previous run patched (config/, src/).
if [ ! -d "$SPC_DIR/.git" ]; then
  git init -q "$SPC_DIR"
  git -C "$SPC_DIR" remote add origin "$SPC_REPO"
fi
git -C "$SPC_DIR" fetch --depth 1 origin "$SPC_REF"
git -C "$SPC_DIR" checkout -q -f FETCH_HEAD
git -C "$SPC_DIR" clean -fdx src   # drop any prior .bak / patch residue

cd "$SPC_DIR"

# static-php-cli is a Composer project: a git checkout has no vendor/, so bin/spc
# can't autoload until its deps are installed. (The v2 gnu-docker wrapper installs
# deps inside the container, but the native bin/spc runs on the host and needs
# this.) Canonical setup step — must run before any bin/spc invocation. v3 needs
# PHP >= 8.4 on the host (CI's setup-php provides 8.4).
composer install --no-dev --no-interaction --optimize-autoloader

# Effective extension set for THIS minor — never $EXTENSIONS directly (an EOL
# minor may reject a member the rest of the channel keeps, e.g. opcache on 7.4).
EXTS="$(extensions_for_minor "$MINOR")"

# --- spc v3 (stable channel) --------------------------------------------------
# See SPC_REF_V3 in config.sh. All yerd patches live in apply-spc-v3-patches.sh;
# v3's build:php downloads what it needs itself (no separate `spc download`), and
# its php-src cache is keyed on the requested minor, so switching minors in one
# checkout re-fetches rather than silently rebuilding the old version.
if [ "$SPC_GEN" = "3" ]; then
  bash "$here/apply-spc-v3-patches.sh" "$SPC_DIR" "$OS" "$MINOR"

  # Linux: glibc, NOT musl (§1 hard req). v3's zig toolchain targets glibc 2.17 —
  # the same floor the 2.x gnu-docker (CentOS 7) image produced.
  if [ "$OS" = "linux" ]; then
    case "$(uname -m)" in
      x86_64|amd64)  SPC_TARGET="x86_64-linux-gnu.2.17" ;;
      aarch64|arm64) SPC_TARGET="aarch64-linux-gnu.2.17" ;;
      *) echo "FATAL: unsupported linux arch $(uname -m)"; exit 1 ;;
    esac
    export SPC_TARGET
    # glibc 2.17 has no epoll_pwait2 (glibc >= 2.35), but PHP 8.6's new
    # main/poll/poll_backend_epoll.c uses it when HAVE_EPOLL_PWAIT2. configure's
    # link probe correctly fails, then falls back to a DECLARATION check, which
    # passes because zig's multi-version glibc headers declare it regardless of
    # the target version -> "ld.lld: undefined symbol: epoll_pwait2" at the final
    # link. Force both cache vars off. SPC_EXTRA_PHP_VARS is passed to php's
    # configure (v3 unix.php; ZigToolchain prepends its avx512 vars to ours).
    # No-op before 8.6 (no such check).
    export SPC_EXTRA_PHP_VARS="ac_cv_func_epoll_pwait2=no ac_cv_have_decl_epoll_pwait2=no${SPC_EXTRA_PHP_VARS:+ $SPC_EXTRA_PHP_VARS}"
    # llvm-objcopy with --set-symbols-visibility (LLVM >= 19) for the yerd#252
    # archive-symbol hiding — see spc-v3-linux-hide-archive-syms.php. zig's own
    # objcopy can't change visibility. Check the CAPABILITY, not mere presence:
    # the ubuntu-24.04-arm runner ships llvm-objcopy-16/17/18, none of which has
    # it (x86 ubuntu-latest happens to ship 22). Ubuntu 24.04's default `llvm` is
    # 18, so install the versioned llvm-19 (in the noble archive).
    objcopy_can_hide() {
      local c
      for c in llvm-objcopy /usr/bin/llvm-objcopy-*; do
        command -v "$c" >/dev/null 2>&1 || continue
        "$c" --help 2>/dev/null | grep -q -- '--set-symbols-visibility' && return 0
      done
      return 1
    }
    if ! objcopy_can_hide; then
      SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
      $SUDO apt-get update -qq && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq llvm-19
      objcopy_can_hide || { echo "FATAL: no llvm-objcopy with --set-symbols-visibility even after installing llvm-19"; exit 1; }
    fi
  fi

  # v3 SYMLINKS ext sources into php-src/ext (ext/apcu -> source/ext-apcu) and
  # keeps source/ext-* across runs, so in a reused checkout (local builds; CI is
  # fresh per job) one minor's ext source — or a per-minor pin such as the 8.6
  # phpredis commit — leaks into the next minor's build. Clear the extracted
  # sources when the minor changes; downloads/ stays, so re-extracting is cheap.
  stamp="$SPC_DIR/.yerd-last-minor"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" != "$MINOR" ]; then
    echo "build-target: minor changed ($(cat "$stamp") -> $MINOR); clearing extracted php-src + ext sources"
    rm -rf source/php-src source/ext-*
    # Artifacts whose SOURCE differs per minor (apply-spc-v3-patches.sh #9): v3
    # doesn't invalidate a cache entry when the source TYPE changes (url -> pie),
    # so 8.5 after 8.6 would silently reuse the 8.6 phpredis pin. Drop the entry.
    php -r '$f = "downloads/.cache.json"; if (!is_file($f)) exit;
      $c = json_decode(file_get_contents($f), true) ?: [];
      foreach (["ext-redis"] as $a) unset($c[$a]);
      file_put_contents($f, json_encode($c, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));'
  fi
  rm -f "$stamp"

  bin/spc doctor --auto-fix
  # --with-suggests is v3's merge of v2's --with-suggested-libs/-exts; §5.2 of
  # verify-artifact.sh asserts the resulting module set.
  bin/spc build:php "$EXTS" --build-cli --build-fpm --with-suggests \
    --dl-with-php="$MINOR" --dl-prefer-binary --dl-retry=5

  for b in buildroot/bin/php buildroot/bin/php-fpm; do
    [ -f "$b" ] || { echo "FATAL: expected artifact $b missing after build"; exit 1; }
  done
  echo "$MINOR" > "$stamp"
  if [ "$OS" = "macos" ]; then
    "$here/sign-macos.sh" buildroot/bin/php buildroot/bin/php-fpm
  fi
  echo "build-target: $MINOR/$OS complete (spc v3) -> $SPC_DIR/buildroot/bin/{php,php-fpm}"
  exit 0
fi

# --- spc v2 (legacy channel) --------------------------------------------------
case "$OS" in
  macos) CMD="bin/spc" ;;
  linux) CMD="bin/spc-gnu-docker" ;;   # glibc container, NOT musl (§1 hard req)
esac

# ALL CHANNELS — pin OpenLDAP to 2.6.14 in config/source.json BEFORE `spc download`
# reads it. spc sources ldap as an unpinned `filelist`, so it rolled onto OpenLDAP
# 2.7.0 the day upstream published it; 2.7.0's tls_o.c declares variables after a
# case label, which gcc rejects under its default -std=gnu17 and which broke every
# Linux leg. ldap can't be avoided by trimming EXTENSIONS — the `ldap` ext requests
# it directly (yerd#235), and it's also a lib-suggests of both postgresql and krb5
# under --with-suggested-libs. Fails loud if it
# no-ops. See the script header for the full rationale.
bash "$here/apply-ldap-pin-patch.sh" "$SPC_DIR"

# ALL CHANNELS — pin swoole to v6.2.2 in config/source.json, same reason: spc
# sources it as an unpinned `ghtar` ("v6\.+"), so it rolled onto 6.2.3, whose new
# non-Linux futex fallback calls an undeclared sw_usleep() and broke every macOS
# leg. Fails loud if it no-ops. See the script header for the full rationale.
bash "$here/apply-swoole-pin-patch.sh" "$SPC_DIR"

# ALL CHANNELS — build swoole with --disable-swoole-stdext (spc passes --enable-
# for swoole >= 6.1). stdext installs user opcode handlers at MINIT, which makes
# OPcache disable the JIT (yerd-php#4). No-op on legacy (no swoole). Fails loud
# if it no-ops. See the script header for the full rationale.
bash "$here/apply-swoole-stdext-patch.sh" "$SPC_DIR"

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

# --- Build pipeline (§4) ------------------------------------------------------
"$CMD" doctor --auto-fix
"$CMD" download --with-php="$MINOR" --for-extensions="$EXTS" --prefer-pre-built --retry=5

# §3 — MUST run after download, before build. Fails the build if it no-ops.
"$here/apply-curl-patch.sh" "$SPC_DIR"

# ALL CHANNELS — PHP 8.4.27 / 8.5.12 ship a stray ext/imap/tests/ dir, which trips
# spc's "imap is bundled (< 8.4), skip ext-imap" check and leaves no config.m4.
# Only skip when config.m4 is really there. Fails the build if it no-ops; see
# the script header for the full rationale.
"$here/apply-imap-extract-patch.sh" "$SPC_DIR"

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
# ALL CHANNELS, Linux only — link php/php-fpm with -Wl,--exclude-libs,ALL so libs
# dlopened via FFI (libvips) don't bind to PHP's static libpng/libxml2/... copies.
# Fires at before-php-make; see the script header. /app/config = docker mount.
if [ "$OS" = "linux" ]; then
  cp "$here/spc-patch-linux-exclude-libs.php" "$SPC_DIR/config/spc-patch-linux-exclude-libs.php"
  build_args+=(--with-added-patch="/app/config/spc-patch-linux-exclude-libs.php")
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
