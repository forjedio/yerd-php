#!/usr/bin/env bash
# spc v3 (stable channel) — every source-level patch we apply to the pinned
# static-php-cli v3 checkout, in one place. These are the v3 ports of the 2.x
# apply-*-patch.sh scripts (which remain in use for the legacy channel on 2.8.5).
#
# Same discipline as the 2.x scripts (§3): every patch FAILS THE BUILD if it
# matches nothing, so an spc refactor on an SPC_REF_V3 bump is caught here rather
# than silently shipping an unpatched binary. Must run on a freshly checked-out
# tree (build-target.sh does `checkout -f` first), BEFORE any bin/spc command.
#
#   1. curl c-ares OFF (§3, yerd#59)
#        src/Package/Target/curl.php: optionalPackage('libcares', '-DENABLE_ARES=ON')
#        -> OFF in both branches. libcares is always resolved (swoole needs it),
#        so the present-branch flag is the one that matters.
#   2. swoole --disable-swoole-stdext (yerd-php#4)
#        src/Package/Extension/swoole.php passes --enable-swoole-stdext for swoole
#        >= 6.1; stdext installs user opcode handlers that make OPcache turn the
#        JIT off. §5.7 of verify-artifact.sh asserts the JIT is really on.
#   3. OpenLDAP pinned to 2.6.14 (yerd#235 build break)
#        config/pkg/lib/ldap.yml sources ldap as an unpinned `filelist`; 2.7.0's
#        tls_o.c broke the gcc gnu17 Linux builds. Pinned to the release the
#        §5.6 LDAP repro was verified against.
#   4. swoole pinned to $SWOOLE_PIN
#        config/pkg/ext/ext-swoole.yml sources swoole as an unpinned `ghtar`
#        (prefer-stable); an unpinned roll (6.2.3) once broke every macOS leg.
#        `match` is tested against each release's tarball_url; per_page=100 keeps
#        the pinned tag reachable as newer releases land.
#   5. Linux only: -Wl,--exclude-libs,ALL on the php/php-fpm link (yerd#252)
#        Hides the static archive symbols from the dynamic symbol table so a
#        library dlopened via FFI (libvips) binds to its own system libpng/libxml2
#        rather than PHP's static copies. In v3 SPC_CMD_VAR_PHP_MAKE_EXTRA_LDFLAGS
#        feeds EXTRA_LDFLAGS_PROGRAM (SAPI executable links only — PHP's own
#        objects aren't archive members, so the PHP API stays exported). Replaces
#        the 2.x spc-patch-linux-exclude-libs.php --with-added-patch hook, which
#        v3 removed. §5.8 of verify-artifact.sh is the end-to-end proof.
#
# Not needed on v3 (handled upstream): the imap stray-tests-dir extract fix
# (PhpExtensionPackage checks for config.m4) and the 8.6 micro patch set.
#
# usage: apply-spc-v3-patches.sh <SPC_DIR> <os>
set -euo pipefail

SPC_DIR="${1:?usage: apply-spc-v3-patches.sh <SPC_DIR> <os>}"
OS="${2:?usage: apply-spc-v3-patches.sh <SPC_DIR> <os>}"
SWOOLE_PIN="v6.2.6"

sha1() { if command -v sha1sum >/dev/null; then sha1sum "$1" | awk '{print $1}'; else shasum -a1 "$1" | awk '{print $1}'; fi; }

# patch <label> <file> <perl-substitution> <grep -F proof-after>
# Applies a perl in-place substitution and fails loud unless the file changed AND
# the proof string is now present.
patch_file() {
  local label="$1" rel="$2" expr="$3" proof="$4" f before after
  f="$SPC_DIR/$rel"
  [ -f "$f" ] || { echo "FATAL: [$label] $rel not found (spc v3 layout changed? re-verify for SPC_REF_V3)"; exit 1; }
  before="$(sha1 "$f")"
  perl -0pi -e "$expr" "$f"
  after="$(sha1 "$f")"
  if [ "$before" != "$after" ] && grep -qF -- "$proof" "$f"; then
    echo "spc v3 patch: $label applied."
  else
    echo "FATAL: [$label] patch did not apply to $rel (upstream changed? re-verify for SPC_REF_V3)"
    exit 1
  fi
}

# 1. curl c-ares OFF
patch_file "curl c-ares OFF" src/Package/Target/curl.php \
  "s/->optionalPackage\('libcares', *'-DENABLE_ARES=ON'\)/->optionalPackage('libcares', '-DENABLE_ARES=OFF', '-DENABLE_ARES=OFF')/" \
  "'-DENABLE_ARES=OFF', '-DENABLE_ARES=OFF'"
if grep -qF -- "ENABLE_ARES=ON" "$SPC_DIR/src/Package/Target/curl.php"; then
  echo "FATAL: [curl c-ares OFF] ENABLE_ARES=ON still present in curl.php"; exit 1
fi

# 2. swoole stdext OFF
patch_file "swoole --disable-swoole-stdext" src/Package/Extension/swoole.php \
  "s/' --enable-swoole-stdext'/' --disable-swoole-stdext'/" \
  "' --disable-swoole-stdext'"
if grep -qF -- "--enable-swoole-stdext" "$SPC_DIR/src/Package/Extension/swoole.php"; then
  echo "FATAL: [swoole stdext] --enable-swoole-stdext still present in swoole.php"; exit 1
fi

# 3. OpenLDAP -> 2.6.14
patch_file "ldap -> 2.6.14" config/pkg/lib/ldap.yml \
  's/openldap-\(\?<version>\[\^"\]\+\)\\\.tgz/openldap-(?<version>2\\.6\\.14)\\.tgz/' \
  'openldap-(?<version>2\.6\.14)\.tgz'

# 4. swoole -> $SWOOLE_PIN. Insert match/query under the ghtar source's
# prefer-stable line (indentation copied from it).
swoole_re="${SWOOLE_PIN//./\\\\.}"
patch_file "swoole -> $SWOOLE_PIN" config/pkg/ext/ext-swoole.yml \
  "s/^( *)(repo: swoole\/swoole-src\n)\1prefer-stable: true\n/\$1\$2\$1prefer-stable: true\n\$1match: '\/${swoole_re}\\\$'\n\$1query: '?per_page=100'\n/m" \
  "match: '/${SWOOLE_PIN//./\\.}\$'"

# 5. Linux: --exclude-libs,ALL on the SAPI executable link. Only the [linux]
# section's line is touched (macOS ld64 has no --exclude-libs).
if [ "$OS" = "linux" ]; then
  patch_file "linux -Wl,--exclude-libs,ALL" config/env.ini \
    's/(\[linux\](?:(?!\n\[).)*?\nSPC_CMD_VAR_PHP_MAKE_EXTRA_LDFLAGS=)""/$1"-Wl,--exclude-libs,ALL"/s' \
    'SPC_CMD_VAR_PHP_MAKE_EXTRA_LDFLAGS="-Wl,--exclude-libs,ALL"'
fi
