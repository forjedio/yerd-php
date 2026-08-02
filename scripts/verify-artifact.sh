#!/usr/bin/env bash
# §5 — per-artifact verification gate. MUST pass before an artifact is published.
# Any failure fails the job: never publish an unverified, c-ares-enabled, or
# ABI-mismatched binary.
#
# usage: verify-artifact.sh <php-bin> <second-sapi-bin> <minor> <os> <arch>
#   second-sapi-bin is php-fpm on unix, php-cgi(.exe) on windows.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

PHP="${1:?php-bin}"; SECONDARY="${2-}"; MINOR="${3:?minor}"; OS="${4:?os}"; ARCH="${5:?arch}"

fail() { echo "VERIFY FAIL: $*" >&2; exit 1; }

# --- Windows bundle gate (repackage model) ------------------------------------
# The windows artifact is a DLL-based directory bundle (official NTS build), not
# an spc static binary, so it has its own self-contained gate and returns before
# the unix flow. arg2 is php-cgi.exe. Extensions load via the generated php.ini
# sitting next to php.exe, so every invocation passes `-c <bundle>/php.ini`.
if [ "$OS" = "windows" ]; then
  CGI="$SECONDARY"
  TREE="$(dirname "$PHP")"
  INI="$TREE/php.ini"
  CA="$TREE/cacert.pem"
  [ -f "$PHP" ] || fail "php.exe not found at '$PHP'"
  [ -f "$CGI" ] || fail "php-cgi.exe not found at '$CGI'"
  [ -f "$INI" ] || fail "generated php.ini not found at '$INI'"
  [ -f "$CA" ]  || fail "bundled cacert.pem not found at '$CA'"
  # Pass the CA bundle by absolute path — exactly what the daemon does at install
  # (curl.cainfo/openssl.cafile can't be relative). Proves the bundle+cert work.
  P=("$PHP" -c "$INI" -d "curl.cainfo=$CA" -d "openssl.cafile=$CA")
  C=("$CGI" -c "$INI" -d "curl.cainfo=$CA" -d "openssl.cafile=$CA")

  echo "== §5.1 no c-ares (windows curl) =="
  # Official windows curl has no c-ares, so CURLOPT_DNS_SERVERS must be rejected.
  dns="$("${P[@]}" -r 'var_export(curl_setopt(curl_init(), CURLOPT_DNS_SERVERS, "127.0.0.1"));' 2>/dev/null || true)"
  echo "  curl_setopt(CURLOPT_DNS_SERVERS) => $dns"
  [ "$dns" = "false" ] || fail "c-ares present in curl (got '$dns', want false)"
  ok="$("${P[@]}" -r '$ch=curl_init("https://www.php.net/");curl_setopt_array($ch,[CURLOPT_RETURNTRANSFER=>true,CURLOPT_NOBODY=>true,CURLOPT_TIMEOUT=>30]);curl_exec($ch);echo curl_errno($ch)===0?"ok":("err:".curl_error($ch));' 2>/dev/null || true)"
  echo "  curl_exec positive control => $ok"
  [ "$ok" = "ok" ] || fail "curl_exec positive control failed ($ok) — broken resolver"

  echo "== §5.2 php -v / php -m (bulk set + pgsql present) =="
  "${P[@]}" -v >/dev/null || fail "php -v did not run"
  mods="$("${P[@]}" -m)"
  for m in curl intl mbstring openssl sodium gd pdo_mysql pgsql pdo_pgsql pdo_sqlite sqlite3 zip soap; do
    grep -iqx "$m" <<<"$mods" || fail "module '$m' missing from php -m"
  done
  grep -iq "opcache" <<<"$mods" || fail "opcache missing from php -m"
  echo "  bulk-set + pgsql present."
  # PECL extensions are added best-effort; whichever DLLs landed in the bundle
  # MUST actually load (a present-but-unloadable DLL is a packaging bug).
  for pe in redis apcu igbinary msgpack imagick; do
    [ -f "$TREE/ext/php_${pe}.dll" ] || continue
    grep -iqx "$pe" <<<"$mods" || fail "PECL extension '$pe' is in the bundle but did not load"
  done
  echo "  bundled PECL extensions load."

  echo "== §5.3 php-cgi.exe (FastCGI serving SAPI) =="
  "${C[@]}" -v 2>&1 | grep -iq "cgi-fcgi" || fail "php-cgi -v did not report cgi-fcgi"
  cgimods="$("${C[@]}" -m 2>/dev/null || true)"
  for m in curl pgsql pdo_pgsql pdo_sqlite; do
    grep -iqx "$m" <<<"$cgimods" || fail "php-cgi -m missing '$m' (cgi diverged from cli?)"
  done
  echo "  php-cgi.exe runs (cgi-fcgi) and carries pgsql + the bulk modules."

  echo "== §5.4 real PDO (pgsql + sqlite drivers) =="
  pdo="$("${P[@]}" -r '
    $fail = [];
    foreach (["pgsql","pdo_pgsql","pdo_sqlite"] as $m) if (!extension_loaded($m)) $fail[] = "extension_loaded($m) !== true";
    $drivers = PDO::getAvailableDrivers();
    foreach (["mysql","pgsql","sqlite"] as $d) if (!in_array($d,$drivers,true)) $fail[] = "driver \"$d\" missing";
    try { $one = (new PDO("sqlite::memory:"))->query("SELECT 1")->fetchColumn(); if ((string)$one !== "1") $fail[]="SELECT 1 => ".var_export($one,true); }
    catch (\Throwable $e) { $fail[] = "new PDO(sqlite::memory:) threw: ".$e->getMessage(); }
    echo $fail ? ("FAIL: ".implode("; ",$fail)) : "ok";
  ' 2>/dev/null || true)"
  echo "  pdo module/driver agreement => $pdo"
  [ "$pdo" = "ok" ] || fail "windows PDO gate: $pdo"

  echo "== §5.5 ZEND_MODULE_API_NO (yerd-php-ext ABI) =="
  # This DLL build loads dynamic extensions (that is the whole point — yerd-dump.dll
  # can load), but yerd-php-ext does not yet publish windows .dll assets, so assert
  # the ABI number matches its pin. Backfill a real yerd-dump.dll load-check when
  # the ext ships windows artifacts.
  want=""
  for kv in $ZEND_API_NOS; do [ "${kv%%:*}" = "$MINOR" ] && want="${kv##*:}"; done
  [ -n "$want" ] || fail "no ZEND_MODULE_API_NO pinned for minor $MINOR"
  got="$("${P[@]}" -i | sed -n 's/^PHP API => \([0-9]\{8\}\).*/\1/p' | head -1)"
  echo "  ZEND_MODULE_API_NO got=$got want=$want"
  [ "$got" = "$want" ] || fail "ZEND_MODULE_API_NO mismatch (got '$got', want '$want')"

  echo "VERIFY OK (windows bundle): $MINOR $OS-$ARCH"
  exit 0
fi

# --- Unix gate (macos/linux, static-php-cli) ----------------------------------
FPM="${SECONDARY:?php-fpm-bin}"
[ -x "$PHP" ] || chmod +x "$PHP"
[ -x "$FPM" ] || chmod +x "$FPM"

# Narrow EXTENSIONS to what THIS minor was actually built with — must match
# build-target.sh, which builds against extensions_for_minor "$MINOR" (an EOL
# minor may drop a member the rest of the channel keeps, e.g. opcache on 7.4).
# Every has_ext gate below then reflects the real binary.
EXTENSIONS="$(extensions_for_minor "$MINOR")"

# True if $1 is a member of the effective (per-minor) comma-separated EXTENSIONS
# set. Assertions for optional extensions (e.g. swoole, which the legacy channel
# drops; opcache, which 7.4 drops) are gated on this so the gate matches what was
# actually built.
has_ext() { case ",$EXTENSIONS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

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
# Skip any that the active channel doesn't build (legacy drops swoole).
for m in curl swoole intl mbstring openssl sodium gd pdo_mysql pgsql redis zip; do
  has_ext "$m" || continue
  grep -iqx "$m" <<<"$mods" || fail "module '$m' missing from php -m"
done
# opcache is listed as "Zend OPcache", not "opcache". Gate on the effective set:
# 7.4 legitimately ships without it (spc can't build it as a static ext < 8.0).
if has_ext opcache; then
  grep -iq "opcache" <<<"$mods" || fail "opcache missing from php -m"
fi
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

echo "== §5.5 real PDO extensions (pdo_pgsql / pdo_sqlite, NOT swoole hooks) =="
# Regression gate for the swoole-hook-{pgsql,sqlite} -> real-ext cutover.
# Swoole's vendored forks register a 'pgsql'/'sqlite' PDO *driver* without ever
# registering the pdo_pgsql/pdo_sqlite *module*, so a broken build has
# getAvailableDrivers() listing the driver while extension_loaded() is false and
# php -m omits it — which the §5.2 grep would happily pass. Assert the module
# registry and the PDO driver hash AGREE, and that a real handle constructs.
# swoole is only asserted when the channel actually built it (legacy drops it).
req_mods="pdo_pgsql pdo_sqlite"
has_ext swoole && req_mods="$req_mods swoole"
pdo="$(REQ_MODS="$req_mods" "$PHP" -r '
  $fail = [];
  foreach (array_filter(explode(" ", getenv("REQ_MODS"))) as $m) {
    if (!extension_loaded($m)) $fail[] = "extension_loaded($m) !== true";
  }
  $drivers = PDO::getAvailableDrivers();
  foreach (["mysql", "pgsql", "sqlite"] as $d) {
    if (!in_array($d, $drivers, true)) $fail[] = "driver \"$d\" missing from getAvailableDrivers()";
  }
  try {
    $db  = new PDO("sqlite::memory:");
    $one = $db->query("SELECT 1")->fetchColumn();
    if ((string) $one !== "1") $fail[] = "SELECT 1 returned " . var_export($one, true);
  } catch (\Throwable $e) {
    $fail[] = "new PDO(sqlite::memory:) threw: " . $e->getMessage();
  }
  echo $fail ? ("FAIL: " . implode("; ", $fail)) : "ok";
' 2>/dev/null || true)"
echo "  pdo module/driver agreement => $pdo"
[ "$pdo" = "ok" ] || fail "real PDO ext gate: $pdo — swoole pgsql/sqlite hooks back in EXTENSIONS, or pdo_pgsql/pdo_sqlite dropped?"

# The real modules MUST appear in php -m (the swoole hooks never did). $mods is
# captured in §5.2.
for m in pdo_pgsql pdo_sqlite; do
  grep -iqx "$m" <<<"$mods" || fail "module '$m' missing from php -m (real ext not registered)"
done

# The FPM binary is built from the same EXTENSIONS set; assert it agrees so the
# CLI and FPM builds can't silently diverge. php-fpm -m lists compiled modules.
fpmmods="$("$FPM" -m 2>/dev/null || true)"
for m in pdo_pgsql pdo_sqlite; do
  grep -iqx "$m" <<<"$fpmmods" || fail "module '$m' missing from php-fpm -m"
done
has_ext swoole && { grep -iqx "swoole" <<<"$fpmmods" || fail "module 'swoole' missing from php-fpm -m"; }
echo "  pdo_pgsql / pdo_sqlite present in both php -m and php-fpm -m."

# Driver-specific PDO subclasses (Pdo\Pgsql, Pdo\Sqlite) landed in 8.4 via the
# "PDO driver specific subclasses" RFC. They do NOT exist on 8.2/8.3, so assert
# only for minors >= 8.4. `min(8.4, MINOR) == 8.4` <=> MINOR >= 8.4.
if [ "$(printf '8.4\n%s\n' "$MINOR" | sort -V | head -1)" = "8.4" ]; then
  sub="$("$PHP" -r '
    $fail = [];
    foreach (["Pdo\\Pgsql", "Pdo\\Sqlite"] as $c) {
      if (!class_exists($c)) $fail[] = "$c does not exist";
    }
    echo $fail ? ("FAIL: " . implode("; ", $fail)) : "ok";
  ' 2>/dev/null || true)"
  echo "  minor $MINOR >= 8.4, Pdo\\Pgsql / Pdo\\Sqlite subclasses => $sub"
  [ "$sub" = "ok" ] || fail "8.4+ PDO driver subclasses: $sub"
else
  echo "  minor $MINOR < 8.4 — skipping Pdo\\Pgsql / Pdo\\Sqlite subclass check (not present pre-8.4)."
fi

echo "VERIFY OK: $MINOR $OS-$ARCH"
