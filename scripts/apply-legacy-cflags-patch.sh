#!/usr/bin/env bash
# LEGACY CHANNEL ONLY — force a pre-C23 C standard for the php-src compile, and
# (macOS only) un-promote one clang default-error back to a warning.
#
# 1. -std=gnu17 (ALL targets)
#    7.4/8.0/8.1 bundle the old K&R-style libbcmath (ext/bcmath/libbcmath/src/*.c).
#    The newest Apple clang / gcc default to -std=gnu23, and C23 REMOVED K&R
#    function definitions from the language, so those sources fail to compile:
#      ext/bcmath/libbcmath/src/add.c:46:9: error: unknown type name 'n1'
#    Stable (8.3+/8.4) configure pins an older std itself, so it is unaffected —
#    this is why only the legacy minors break. We append `-std=gnu17` to spc's
#    php-src EXTRA_CFLAGS (clang/gcc honour the LAST -std), which is exactly how
#    spc's own xlswriter extension handles the same problem (see src/SPC/builder/
#    extension/xlswriter.php in the pinned ref).
#
# 2. -Wno-error=incompatible-function-pointer-types (macOS/clang ONLY)
#    libxml2 2.12 const-ified the structured-error callback: xmlStructuredErrorFunc
#    became `void (*)(void *, const xmlError *)`. 7.4/8.0's ext/libxml/libxml.c
#    still registers a handler taking a NON-const xmlErrorPtr, so the compile hits:
#      ext/libxml/libxml.c:1050: error: incompatible function pointer types passing
#        'void (void *, xmlErrorPtr)' to parameter of type 'xmlStructuredErrorFunc'
#        [-Wincompatible-function-pointer-types]
#    We can't dodge it via the version pin: the libxml patch already holds libxml2
#    at 2.13.9 (newest release still exporting ATTRIBUTE_UNUSED, which 2.14 removed
#    and 7.4/8.0 also need), and the const change landed back in 2.12 — so every
#    libxml2 new enough to keep ATTRIBUTE_UNUSED also has the const signature. The
#    mismatch is const-only (ABI-identical; PHP's handler just reads the struct), so
#    it is a benign warning. Linux gcc already treats it as one and builds fine;
#    Apple clang makes -Wincompatible-function-pointer-types an error BY DEFAULT, so
#    ONLY macOS breaks. `-Wno-error=...` reverts that default-error to a warning
#    (matching gcc) without silencing the signal. Linux never gets this flag: the
#    warning name is clang-specific and gcc doesn't need it. PHP fixed the handler
#    signature from 8.1 on, so 8.1/stable compile clean and the flag is a harmless
#    no-op there. Re-verify on every SPC_REF / libxml2-pin bump.
#
# Patches config/env.ini in the cloned spc checkout. Both appends are idempotent
# (the anchored match no longer holds once patched) and FAIL if they match nothing
# — an spc refactor of the env.ini flag lines must be caught, not silently skipped
# (§3 curl-patch discipline). Re-verify on every SPC_REF bump.
#
# usage: apply-legacy-cflags-patch.sh <SPC_DIR> [<os>]
#   <os> (macos|linux) gates the clang-only flag; defaults to no clang flag.
set -euo pipefail

SPC_DIR="${1:?usage: apply-legacy-cflags-patch.sh <SPC_DIR> [<os>]}"
OS="${2:-}"
target="$SPC_DIR/config/env.ini"
[ -f "$target" ] || { echo "FATAL: $target not found (spc layout changed? re-verify legacy cflags patch for SPC_REF)"; exit 1; }

# Every EXTRA_CFLAGS line spc defines (the macOS + Linux defaults). This is the
# denominator both appends verify against: after patching, EVERY such line must
# carry the flag. A mismatch means spc renamed/reshaped the var — fail loud.
lines="$(grep -cE '^SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS="' "$target" || true)"
[ "$lines" -ge 1 ] || { echo "FATAL: no SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS line in $target (spc env.ini layout changed? re-verify for SPC_REF)"; exit 1; }

# Count EXTRA_CFLAGS lines already carrying a flag (idempotency: present -> skip).
have() { grep -E '^SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS="' "$target" | grep -cF -- "$1" || true; }

# Append ' -std=gnu17' to every EXTRA_CFLAGS line ending in '${SPC_DEFAULT_C_FLAGS}"'.
# Detection is by substring (not end-anchored) so a trailing flag added later doesn't
# reopen the append; a second run finds the anchor gone and no-ops. (clang/gcc honour
# the LAST -std, so position among later flags is irrelevant.)
sed -i.bak -E 's/^(SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS="[^"]*\$\{SPC_DEFAULT_C_FLAGS\})"$/\1 -std=gnu17"/' "$target"
rm -f "$target.bak"
[ "$(have '-std=gnu17')" -eq "$lines" ] || { echo "FATAL: legacy cflags patch left $((lines - $(have '-std=gnu17')))/$lines EXTRA_CFLAGS line(s) without -std=gnu17 in $target (spc env.ini layout changed? re-verify for SPC_REF)"; exit 1; }
echo "legacy cflags patch applied (-std=gnu17 on $lines EXTRA_CFLAGS line(s))."

# macOS ONLY — append the clang default-error demotion to the same lines. Anchored on
# the '-std=gnu17"' suffix the step above guarantees; a second run finds that suffix
# already displaced by the flag and no-ops.
if [ "$OS" = "macos" ]; then
  cflag='-Wno-error=incompatible-function-pointer-types'
  sed -i.bak -E 's/^(SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS="[^"]*-std=gnu17)"$/\1 -Wno-error=incompatible-function-pointer-types"/' "$target"
  rm -f "$target.bak"
  [ "$(have "$cflag")" -eq "$lines" ] || { echo "FATAL: legacy cflags patch (clang flag) left $((lines - $(have "$cflag")))/$lines EXTRA_CFLAGS line(s) without $cflag in $target (spc env.ini layout changed? re-verify for SPC_REF)"; exit 1; }
  echo "legacy cflags patch applied ($cflag on $lines EXTRA_CFLAGS line(s), macOS)."
fi
