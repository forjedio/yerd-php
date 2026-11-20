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
#      + both OSes: keep the PHP API EXPORTED from php/php-fpm. v3 (unlike 2.x)
#        links with -Wl,-dead_strip (macOS) / --gc-sections (Linux); without
#        -export_dynamic, ld64 strips every exported PHP API function the binary
#        doesn't call itself (e.g. zend_register_ini_entries), so dynamic exts —
#        yerd-dump.so, pcov.so — fail with "symbol not found in flat namespace".
#        Linux gets --export-dynamic explicitly for the same reason (gc roots).
#        §5.4 of verify-artifact.sh really loads yerd-dump.so.
#   6. --with-suggests resolves suggested LIBRARIES only, as v2's
#        --with-suggested-libs did; v3 would otherwise add suggested extensions
#        (swoole-hook-pgsql etc.) and change the shipped extension set.
#   7. ngtcp2 gets OpenSSL as -l flags, not absolute .a paths, so newer Apple
#        ar doesn't write an empty libngtcp2_crypto_ossl.a (breaks curl HTTP/3).
#   8. PHP 8.6: restore the removed aliases + apcu php_verror fix for the static
#        PECL exts (spc-v3-php86-compat.php, hooked into php's buildconf stage).
#   9. PHP 8.6 only: phpredis from a pinned develop commit. 8.6 changed the session
#        save-handler API (PS_OPEN_ARGS save_path is now zend_string *); phpredis
#        develop handles it, the 6.3.0 release does not. Drop on the next release.
#
# Not needed on v3 (handled upstream): the imap stray-tests-dir extract fix
# (PhpExtensionPackage checks for config.m4) and the 8.6 micro patch set.
#
# usage: apply-spc-v3-patches.sh <SPC_DIR> <os> <minor>
set -euo pipefail

SPC_DIR="${1:?usage: apply-spc-v3-patches.sh <SPC_DIR> <os> <minor>}"
OS="${2:?usage: apply-spc-v3-patches.sh <SPC_DIR> <os> <minor>}"
MINOR="${3:?usage: apply-spc-v3-patches.sh <SPC_DIR> <os> <minor>}"
SWOOLE_PIN="v6.2.6"
# phpredis develop @ 2026-11-19 — first commit with PHP 8.6 in CI (#3013/#3014);
# no 8.6-capable release yet. 8.6 ONLY; earlier minors keep the released PIE source.
REDIS_PHP86_SHA="a6ce1e60b3e81ce3b25174aa5aaefd5590dc64fd"

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

# patch_literal <label> <file> <old> <new>
# Exact-string replacement (no regex escaping), exactly one occurrence required.
patch_literal() {
  local label="$1" rel="$2" f="$SPC_DIR/$2" n
  [ -f "$f" ] || { echo "FATAL: [$label] $rel not found (spc v3 layout changed? re-verify for SPC_REF_V3)"; exit 1; }
  n="$(OLD="$3" perl -0ne 'print scalar(() = /\Q$ENV{OLD}\E/g)' "$f")"
  [ "$n" = "1" ] || { echo "FATAL: [$label] expected 1 match in $rel, found $n (upstream changed? re-verify for SPC_REF_V3)"; exit 1; }
  OLD="$3" NEW="$4" perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$f"
  grep -qF -- "$4" "$f" || { echo "FATAL: [$label] replacement not present in $rel after patch"; exit 1; }
  echo "spc v3 patch: $label applied."
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

# 6. --with-suggests follows LIBRARY suggests only (v2 --with-suggested-libs).
# v3 merged v2's --with-suggested-libs/-exts into one flag that also turns
# suggested EXTENSIONS into hard deps — e.g. swoole's suggested swoole-hook-pgsql,
# which we deliberately exclude (see STABLE_EXTENSIONS) and which spc then rejects
# as conflicting with pdo_pgsql. Filter ext-* out of the suggests merge so the
# extension set is exactly what we request, while suggested libs still enable
# optional features (e.g. curl's brotli/nghttp2).
patch_file "suggests: libs only" src/StaticPHP/Util/DependencyResolver.php \
  "s/array_merge\(\\\$pkg_item\['depends'\], \\\$pkg_item\['suggests'\]\)/array_merge(\\\$pkg_item['depends'], array_values(array_filter(\\\$pkg_item['suggests'], static fn (string \\\$s): bool => !str_starts_with(\\\$s, 'ext-'))))/" \
  "static fn (string \$s): bool => !str_starts_with(\$s, 'ext-')"

# 7. ngtcp2: give configure OpenSSL as -L/-l flags, not absolute .a paths.
# libtool copies absolute .a inputs INTO libngtcp2_crypto_ossl.a as members (v3
# then `ar d`s them on macOS). Newer Apple ar (macOS 27 / current Xcode) instead
# writes an EMPTY archive when any input is itself an archive, so curl's HTTP/3
# link fails with undefined _ngtcp2_crypto_* symbols. -l flags are never archived,
# so this works with both old and new ar; extra flags (-lresolv, -ldl) are kept.
patch_literal "ngtcp2 OPENSSL_LIBS as -l flags" src/Package/Library/ngtcp2.php \
  '"OPENSSL_LIBS=\"{$openssl->getStaticLibFiles()}\"",' \
  '"OPENSSL_LIBS=\"-L{$openssl->getLibDir()} " . preg_replace('"'"'#\S*/lib([^/\s]+)\.a(?=\s|$)#'"'"', '"'"'-l$1'"'"', $openssl->getStaticLibFiles()) . "\"",'

# 8. PHP 8.6 source compat for statically built PECL exts (removed macros,
# php_hash_bin2hex, apcu php_verror). The logic lives in spc-v3-php86-compat.php;
# here it is copied into the spc tree and hooked into php's buildconf stage, which
# runs after php-src and every ext source are extracted. No-op below 8.6.
here_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$SPC_DIR/config/yerd"
cp "$here_dir/spc-v3-php86-compat.php" "$SPC_DIR/config/yerd/php86-compat.php"
patch_literal "php 8.6 PECL compat hook" src/Package/Target/php/unix.php \
  '        SourcePatcher::patchPhpSrc();
' \
  '        SourcePatcher::patchPhpSrc();

        // yerd-php: PHP 8.6 compat for static PECL exts (apply-spc-v3-patches.sh #8)
        require_once dirname(__DIR__, 4) . '"'"'/config/yerd/php86-compat.php'"'"';
        yerd_php86_compat(SOURCE_PATH . '"'"'/php-src'"'"', php::getPHPVersionID());
'

# 9. PHP 8.6 only: phpredis from the pinned develop tarball (see REDIS_PHP86_SHA).
if [ "$MINOR" = "8.6" ]; then
  patch_literal "redis (8.6) -> phpredis@${REDIS_PHP86_SHA:0:8}" config/pkg/ext/ext-redis.yml \
    '      type: pie
      repo: phpredis/phpredis
' \
    "      type: url
      url: 'https://github.com/phpredis/phpredis/archive/${REDIS_PHP86_SHA}.tar.gz'
"
fi

# 5. SAPI executable link flags, per OS section of env.ini (only that section's
# SPC_CMD_VAR_PHP_MAKE_EXTRA_LDFLAGS line is touched):
#   linux: --exclude-libs,ALL (yerd#252) + --export-dynamic (PHP API for .so exts)
#   macos: -export_dynamic (PHP API for .so exts; ld64 has no --exclude-libs)
if [ "$OS" = "linux" ]; then
  patch_file "linux -Wl,--exclude-libs,ALL -Wl,--export-dynamic" config/env.ini \
    's/(\[linux\](?:(?!\n\[).)*?\nSPC_CMD_VAR_PHP_MAKE_EXTRA_LDFLAGS=)""/$1"-Wl,--exclude-libs,ALL -Wl,--export-dynamic"/s' \
    'SPC_CMD_VAR_PHP_MAKE_EXTRA_LDFLAGS="-Wl,--exclude-libs,ALL -Wl,--export-dynamic"'
else
  patch_file "macos -Wl,-export_dynamic" config/env.ini \
    's/(\[macos\](?:(?!\n\[).)*?\nSPC_CMD_VAR_PHP_MAKE_EXTRA_LDFLAGS=)""/$1"-Wl,-export_dynamic"/s' \
    'SPC_CMD_VAR_PHP_MAKE_EXTRA_LDFLAGS="-Wl,-export_dynamic"'
fi
