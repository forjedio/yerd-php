#!/usr/bin/env bash
# LEGACY CHANNEL ONLY — force a pre-C23 C standard for the php-src compile.
#
# 7.4/8.0/8.1 bundle the old K&R-style libbcmath (ext/bcmath/libbcmath/src/*.c).
# The newest Apple clang / gcc default to -std=gnu23, and C23 REMOVED K&R
# function definitions from the language, so those sources fail to compile:
#   ext/bcmath/libbcmath/src/add.c:46:9: error: unknown type name 'n1'
# Stable (8.3+/8.4) configure pins an older std itself, so it is unaffected — this
# is why only the legacy minors break. We append `-std=gnu17` to spc's php-src
# EXTRA_CFLAGS (clang/gcc honour the LAST -std), which is exactly how spc's own
# xlswriter extension handles the same problem (see src/SPC/builder/extension/
# xlswriter.php in the pinned ref).
#
# Patches config/env.ini in the cloned spc checkout. Idempotent (the anchored
# match no longer holds once patched) and FAILS if it matched nothing — an spc
# refactor of the env.ini flag lines must be caught, not silently skipped (§3
# curl-patch discipline). Re-verify on every SPC_REF bump.
#
# usage: apply-legacy-cflags-patch.sh <SPC_DIR>
set -euo pipefail

SPC_DIR="${1:?usage: apply-legacy-cflags-patch.sh <SPC_DIR>}"
target="$SPC_DIR/config/env.ini"
[ -f "$target" ] || { echo "FATAL: $target not found (spc layout changed? re-verify legacy cflags patch for SPC_REF)"; exit 1; }

# Append ' -std=gnu17' to every SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS line that ends
# in '${SPC_DEFAULT_C_FLAGS}"' (the macOS + Linux defaults). Anchored on that
# suffix so a second run is a no-op (portable across BSD + GNU sed).
before="$(grep -cE 'SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS=.*-std=gnu17"$' "$target" || true)"
sed -i.bak -E 's/^(SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS="[^"]*\$\{SPC_DEFAULT_C_FLAGS\})"$/\1 -std=gnu17"/' "$target"
after="$(grep -cE 'SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS=.*-std=gnu17"$' "$target" || true)"
rm -f "$target.bak"

if [ "$after" -gt "$before" ] || [ "$after" -ge 2 ]; then
  echo "legacy cflags patch applied (-std=gnu17 on $after EXTRA_CFLAGS line(s))."
else
  echo "FATAL: legacy cflags patch matched nothing in $target (spc env.ini layout changed? re-verify for SPC_REF)"
  exit 1
fi
