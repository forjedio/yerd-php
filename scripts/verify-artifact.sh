#!/usr/bin/env bash
# §5 — per-artifact verification gate. MUST pass before an artifact is published.
# Any failure fails the job: never publish an unverified, c-ares-enabled, or
# ABI-mismatched binary.
#
# usage: verify-artifact.sh <php-bin> <php-fpm-bin> <minor> <os> <arch>
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

PHP="${1:?php-bin}"; FPM="${2:?php-fpm-bin}"; MINOR="${3:?minor}"; OS="${4:?os}"; ARCH="${5:?arch}"
[ -x "$PHP" ] || chmod +x "$PHP"
[ -x "$FPM" ] || chmod +x "$FPM"

fail() { echo "VERIFY FAIL: $*" >&2; exit 1; }

echo "== §5.1 #59 regression gate (no c-ares) =="
# CURLOPT_DNS_SERVERS is a c-ares-only option: curl_setopt returns false
# (CURLE_NOT_BUILT_IN) iff libcurl lacks c-ares. true => c-ares present => FAIL.
dns="$("$PHP" -r 'var_export(curl_setopt(curl_init(), CURLOPT_DNS_SERVERS, "127.0.0.1"));' 2>/dev/null || true)"
echo "  curl_setopt(CURLOPT_DNS_SERVERS) => $dns"
[ "$dns" = "false" ] || fail "c-ares present in curl (got '$dns', want false) — §3 patch reverted?"

# Positive control: a real https fetch must resolve & connect (guards against a
# build with no working resolver at all).
ok="$("$PHP" -r '
  $ch = curl_init("https://www.php.net/");
  curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER=>true, CURLOPT_NOBODY=>true, CURLOPT_TIMEOUT=>30]);
  curl_exec($ch);
  echo curl_errno($ch) === 0 ? "ok" : ("err:".curl_error($ch));
' 2>/dev/null || true)"
echo "  curl_exec positive control => $ok"
[ "$ok" = "ok" ] || fail "curl_exec positive control failed ($ok) — broken resolver"

echo "== §5.2 php -v / php -m (bulk set present) =="
"$PHP" -v >/dev/null || fail "php -v did not run"
mods="$("$PHP" -m)"
# Name mapping is not 1:1 with ext tokens, so we assert a critical, cleanly-named
# subset — including the four the brief calls out explicitly (swoole,intl,opcache,curl).
for m in curl swoole intl mbstring openssl sodium gd pdo_mysql pgsql redis zip; do
  grep -iqx "$m" <<<"$mods" || fail "module '$m' missing from php -m"
done
# opcache is listed as "Zend OPcache", not "opcache".
grep -iq "opcache" <<<"$mods" || fail "opcache missing from php -m"
echo "  bulk-set critical modules present."

echo "== §5.3 php-fpm -t (valid config) =="
# A freshly-built static php-fpm has no default config file, so a bare `-t`
# fails with "failed to open configuration file" even on a perfectly good
# binary. Point it at a minimal valid config so `-t` actually exercises the
# binary rather than the (absent) default path.
fpmconf="$(mktemp)"; fpmlog="$(mktemp)"
cat > "$fpmconf" <<'CONF'
[global]
error_log = /dev/stderr
[www]
listen = 127.0.0.1:9000
pm = static
pm.max_children = 1
CONF
"$FPM" -t -y "$fpmconf" >"$fpmlog" 2>&1 || true
cat "$fpmlog"
grep -qi "successful" "$fpmlog" || fail "php-fpm -t did not report a valid configuration"
rm -f "$fpmconf" "$fpmlog"

echo "== §5.4 real extension load (cross-repo ABI gate) =="
# Preferred, authoritative gate: download the matching yerd-php-ext .so for this
# (minor, os, arch) and really load it. Only for a brand-new minor with no
# published ext do we fall back to asserting ZEND_MODULE_API_NO.
so=""; tmp=""
if [ -n "${EXT_SO:-}" ] && [ -f "${EXT_SO}" ]; then
  so="$EXT_SO"
elif command -v gh >/dev/null 2>&1; then
  # yerd-php-ext publishes per (minor, os, arch); try to fetch yerd-dump.so.
  # NOTE: yerd-php-ext currently ships NO macos-x86_64 asset, so the Intel-mac
  # leg always takes the ZEND_MODULE_API_NO fallback below (by design, until the
  # ext adds Intel or yerd drops that target — §1 contingency).
  tmp="$(mktemp -d)"
  pat="yerd-dump-${MINOR}-${OS}-${ARCH}.so"
  if gh release download --repo "$EXT_REPO" --pattern "$pat" --dir "$tmp" 2>/dev/null; then
    so="$(find "$tmp" -name '*.so' | head -1)"
  fi
fi

if [ -n "$so" ]; then
  echo "  loading real ext: $so"
  loaded="$("$PHP" -d "extension=$so" -m 2>/dev/null | grep -i "yerd\|pcov" || true)"
  [ -n "$loaded" ] || fail "yerd-php-ext .so did not load (ABI mismatch) — $so"
  echo "  real-ext load OK: $loaded"
else
  # Fallback: assert the built PHP's ZEND_MODULE_API_NO matches what yerd-php-ext
  # pins for this minor. This number is authoritative in yerd-php-ext's build
  # config — the value here is only a backstop; backfill the real-load check as
  # soon as the ext ships for this minor.
  echo "  WARN: no yerd-php-ext .so for $MINOR-$OS-$ARCH; falling back to ZEND_MODULE_API_NO assertion." >&2
  want=""
  for kv in $ZEND_API_NOS; do [ "${kv%%:*}" = "$MINOR" ] && want="${kv##*:}"; done
  [ -n "$want" ] || fail "no ZEND_MODULE_API_NO pinned for minor $MINOR (add to config.sh / verify in $EXT_REPO)"
  # ZEND_MODULE_API_NO is the "PHP API => NNNNNNNN" line (what a .so checks on
  # load), NOT "Zend Extension Build => API4..." (that's ZEND_EXTENSION_API_NO).
  got="$("$PHP" -i | sed -n 's/^PHP API => \([0-9]\{8\}\).*/\1/p' | head -1)"
  echo "  ZEND_MODULE_API_NO got=$got want=$want"
  [ "$got" = "$want" ] || fail "ZEND_MODULE_API_NO mismatch (got '$got', want '$want')"
fi
[ -n "$tmp" ] && rm -rf "$tmp"

echo "VERIFY OK: $MINOR $OS-$ARCH"
