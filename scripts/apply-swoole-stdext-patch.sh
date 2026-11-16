#!/usr/bin/env bash
# ALL CHANNELS — build swoole with --disable-swoole-stdext so OPcache JIT works
# (yerd-php#4), and FAIL the build if the patch matched nothing.
#
#   spc 2.8.5's src/SPC/builder/extension/swoole.php appends
#     ' --enable-swoole-stdext'
#   for swoole >= 6.1.0 (we pin 6.2.2). stdext's MINIT (php_swoole_stdext_minit)
#   installs user opcode handlers (INIT_METHOD_CALL, ASSIGN_DIM, ...), so
#   OPcache's zend_jit_check_support() refuses to start the JIT:
#     Warning: JIT is incompatible with third party extensions that setup user
#     opcode handlers. JIT disabled.
#   Swoole labels stdext "[Experimental] only used for swoole-cli" and nothing we
#   ship depends on it. Swoole's remaining handlers (BEGIN/END_SILENCE, EXIT
#   pre-8.4) are exempt from the JIT check. §5.7 of verify-artifact.sh asserts
#   the JIT actually comes up on every swoole build.
#
#   The flag is rewritten to --disable- (not deleted) so spc.shell.log records
#   the choice and we don't depend on swoole's default staying "no".
#
# Applied channel-wide for symmetry with the ldap/swoole pins; legacy doesn't
# build swoole, so there it edits an unused file. Idempotent; fails loud if it
# no-ops (§3 curl-patch discipline). Re-verify on every SPC_REF bump.
#
# usage: apply-swoole-stdext-patch.sh <SPC_DIR>
set -euo pipefail

SPC_DIR="${1:?usage: apply-swoole-stdext-patch.sh <SPC_DIR>}"
target="$SPC_DIR/src/SPC/builder/extension/swoole.php"
[ -f "$target" ] || { echo "FATAL: $target not found (spc layout changed? re-verify swoole stdext patch for SPC_REF)"; exit 1; }

if grep -qF -- "' --disable-swoole-stdext'" "$target" && ! grep -qF -- '--enable-swoole-stdext' "$target"; then
  echo "swoole.php stdext patch already applied."
  exit 0
fi

# sha1 helper (sha1sum on Linux, shasum on macOS).
sha1() { if command -v sha1sum >/dev/null; then sha1sum "$1" | awk '{print $1}'; else shasum -a1 "$1" | awk '{print $1}'; fi; }

before="$(sha1 "$target")"
sed -i.bak -E "s/' --enable-swoole-stdext'/' --disable-swoole-stdext'/" "$target"
after="$(sha1 "$target")"

if [ "$before" != "$after" ] && grep -qF -- "' --disable-swoole-stdext'" "$target" && ! grep -qF -- '--enable-swoole-stdext' "$target"; then
  echo "swoole.php stdext patch applied (--disable-swoole-stdext)."
  rm -f "$target.bak"
else
  echo "FATAL: swoole.php stdext patch did not apply (spc no longer passes --enable-swoole-stdext? re-verify swoole stdext patch for SPC_REF)"
  exit 1
fi
