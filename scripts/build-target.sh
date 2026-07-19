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
# DIAGNOSTIC (remove with the scaffold below): keep the symbol table on the failing
# macOS x86_64 target so a crash backtrace names the faulting MINIT function instead
# of a stripped `.LL31` local. Scoped to this one target — it never ships (it fails);
# arm64 still ships stripped.
if [ "$OS" = "macos" ] && [ "$(uname -m)" = "x86_64" ]; then
  build_args+=(--no-strip)
fi
# DIAGNOSTIC SCAFFOLD (remove once the macOS x86_64 startup crash is fixed) —
# spc's own CLI sanity check runs `php -n -r 'echo "hello";'` but DISCARDS the
# test binary's stderr, so a startup crash surfaces only as "code: N, output:"
# with N the raw wait-status (6 == killed by SIGABRT). GitHub runners don't run
# ReportCrash, so no .ips is written; instead get the faulting stack live via
# lldb (Xcode is installed) and use DYLD_PRINT_INITIALIZERS to tell a load-time
# global-constructor crash from a MINIT crash. Capture rc explicitly — `if ! cmd`
# would zero $?.
set +e
"$CMD" "${build_args[@]}"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  if [ "$OS" = "macos" ] && [ -x buildroot/bin/php ]; then
    echo "======================================================================"
    echo "spc build failed (rc=$rc) — diagnosing macOS startup crash"
    echo "======================================================================"
    set +e
    echo "--- probe 1: plain run, stderr attached ---"
    ./buildroot/bin/php -n -r 'echo "hello\n";'
    echo ">>> exit: $?"
    echo "--- probe 2: dyld initializers (LAST line before it stops = culprit lib if the"
    echo "             crash is a load-time global constructor; if 'init-done' prints"
    echo "             then it dies later, in PHP MINIT) ---"
    DYLD_PRINT_INITIALIZERS=1 ./buildroot/bin/php -n -r 'echo "init-done\n";' 2>&1 | tail -60
    echo "--- probe 3: post-mortem backtrace via core dump (no debugger-attach perms"
    echo "             needed, which live lldb attach lacks on CI) ---"
    sudo sysctl -w kern.coredump=1 >/dev/null 2>&1
    # /cores is root:wheel 0755 by default; the kernel writes the core as the
    # crashing process's uid, so make it writable or the core is silently dropped.
    sudo mkdir -p /cores 2>/dev/null; sudo chmod 1777 /cores 2>/dev/null
    rm -f /cores/core.* 2>/dev/null
    ( ulimit -c unlimited; ./buildroot/bin/php -n -r 'echo "hi\n";' ) 2>&1
    core="$(ls -t /cores/core.* 2>/dev/null | head -1)"
    if [ -n "$core" ]; then
      echo "core: $core ($(du -h "$core" | cut -f1))"
      # --no-strip (set for this target above) keeps the symbol table in the binary,
      # so frames resolve to real function names without a separate dSYM. Keep the
      # command list minimal — lldb --batch aborts the whole session on the first
      # command error, so no best-effort commands that might fail here.
      xcrun lldb --batch -c "$core" buildroot/bin/php \
        -o 'thread backtrace all' -o 'quit' 2>&1 | tail -120
      # The backtrace shows zend_startup_module_ex(module=...) with debug info, so pull
      # that extension's name straight from the core. Separate session so a frame/expr
      # mismatch can't abort the backtrace above. frame #9 is zend_startup_module_ex in
      # the observed trace; print its `module->name`.
      echo "--- culprit module name (from core, frame 9 = zend_startup_module_ex) ---"
      xcrun lldb --batch -c "$core" buildroot/bin/php \
        -o 'frame select 9' -o 'expr -- module->name' -o 'quit' 2>&1 | tail -12
      sudo rm -f "$core"
    else
      echo "(no core written; falling back to live lldb after enabling dev mode +"
      echo " ad-hoc signing with get-task-allow so attach is permitted)"
      sudo /usr/sbin/DevToolsSecurity -enable >/dev/null 2>&1
      ent="$(mktemp -t gettaskallow).plist"
      cat > "$ent" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
      codesign -s - -f --entitlements "$ent" buildroot/bin/php >/dev/null 2>&1
      xcrun lldb --batch -o 'run' -o 'thread backtrace all' -o 'quit' \
        -- ./buildroot/bin/php -n -r 'echo "hi\n";' 2>&1 | tail -120
    fi
    echo "--- probe 4: name each extension as its MINIT starts; the LAST name printed"
    echo "             before the abort is the extension whose MINIT overflows. This is"
    echo "             symbol-resolution-proof (reads the arg), unlike the backtrace. ---"
    # zend_startup_module_ex(zend_module_entry *module) — arg0 in %rdi (SysV). In the
    # 7.4/8.x zend_module_entry the `const char *name` sits at offset 32 (size u16 @0,
    # zend_api u32 @4, zend_debug/zts u8 @8/9, pad, ini_entry* @16, deps* @24, name @32).
    # Break there, print the name, auto-continue; live debugging needs attach perms, so
    # enable developer mode and ad-hoc-sign a copy with get-task-allow first.
    sudo /usr/sbin/DevToolsSecurity -enable >/dev/null 2>&1
    ent="$(mktemp -t gettaskallow).plist"
    cat > "$ent" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
    cp buildroot/bin/php buildroot/bin/php.dbg
    codesign -s - -f --entitlements "$ent" buildroot/bin/php.dbg >/dev/null 2>&1
    xcrun lldb --batch \
      -o 'breakpoint set --name zend_startup_module_ex --skip-prologue false --auto-continue true' \
      -o 'breakpoint command add --one-liner "expr -- *(char **)($rdi + 32)" 1' \
      -o 'run' \
      -o 'thread backtrace' \
      -o 'quit' \
      -- ./buildroot/bin/php.dbg -n -r 'echo "hi\n";' 2>&1 | grep -vE '^ *0x|Valid values|or "' | tail -60
    rm -f buildroot/bin/php.dbg
    echo "--- file / otool / codesign ---"
    file buildroot/bin/php
    otool -L buildroot/bin/php 2>&1 | head -50
    codesign -dv buildroot/bin/php 2>&1 | head -20
    set -e
  fi
  exit "$rc"
fi

for b in buildroot/bin/php buildroot/bin/php-fpm; do
  [ -f "$b" ] || { echo "FATAL: expected artifact $b missing after build"; exit 1; }
done

# --- macOS ad-hoc signing (§4) — MANDATORY on Apple Silicon, BOTH binaries ----
if [ "$OS" = "macos" ]; then
  "$here/sign-macos.sh" buildroot/bin/php buildroot/bin/php-fpm
fi

echo "build-target: $MINOR/$OS complete -> $SPC_DIR/buildroot/bin/{php,php-fpm}"
