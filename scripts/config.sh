#!/usr/bin/env bash
# Single source of truth for build configuration.
# Sourced by every script and exported into the CI environment.
#
# Authoritative brief: yerd-php-AGENTS.md. If this disagrees with it, the brief wins.

# --- Channel: stable vs legacy ------------------------------------------------
# yerd-php publishes TWO channels into the SAME rolling release (§6):
#   stable  — supported minors (>= 8.2), full extension set        -> php.json
#   legacy  — EOL minors (7.4/8.0/8.1) offered as an opt-in, hideable UI tier,
#             with a trimmed extension set and NO yerd-php-ext (pcov / yerd-dump
#             aren't built for EOL PHP)                             -> php-legacy.json
# CHANNEL selects which one this invocation operates on. Every channel-varying
# knob (minors, extension set, manifest name) is swapped in the case block near
# the bottom of this file, so all the downstream scripts stay channel-agnostic —
# they just read SUPPORTED_MINORS / EXTENSIONS / MANIFEST_NAME.
CHANNEL="${CHANNEL:-stable}"

# --- Supported PHP minors, per channel (§2) -----------------------------------
# stable: every minor >= 8.2 that upstream still supports. 8.2 is yerd's floor.
#   Add a minor when it GAs; drop it when it EOLs below the floor.
STABLE_MINORS="8.2 8.3 8.4 8.5"
# legacy: EOL minors we still offer as a hideable tier. spc 2.8.5 can still build
# these; drop one when spc drops support for it.
LEGACY_MINORS="7.4 8.0 8.1"

# --- Extension set — the "bulk" set (§1) --------------------------------------
# Keep in sync with what yerd expects. Passed to spc as a single comma string.
# NOTE: keep `swoole` (we still drop c-ares from *curl* via the §3 patch).
#
# pdo_pgsql / pdo_sqlite are the REAL upstream PDO extensions — deliberately NOT
# swoole-hook-pgsql / swoole-hook-sqlite. Swoole's vendored forks register a
# `pgsql`/`sqlite` PDO *driver* WITHOUT ever registering the pdo_pgsql/pdo_sqlite
# *module*, so extension_loaded('pdo_pgsql') stays false and `php -m` omits it
# even though PDO::getAvailableDrivers() lists the driver — which silently breaks
# `composer install` platform checks for ext-pdo_pgsql / ext-pdo_sqlite. spc
# treats the hook and the real ext as MUTUALLY EXCLUSIVE and hard-fails the build
# if both are present (swoole_hook_pgsql.php / swoole_hook_sqlite.php throw
# WrongUsageException; see docs/en/guide/extension-notes.md in the pinned ref).
# Do NOT re-add the pgsql/sqlite hooks — §5.5 of verify-artifact.sh asserts the
# real modules load and will fail the build if they come back.
# swoole-hook-mysql is different: it hooks mysqlnd + pdo_mysql and COEXISTS with
# them (spc lists pdo_mysql as one of its ext-depends; no conflict), so it stays.
STABLE_EXTENSIONS="apcu,bcmath,bz2,calendar,ctype,curl,dba,dom,event,exif,fileinfo,filter,ftp,gd,gmp,iconv,imagick,imap,intl,mbregex,mbstring,mysqli,mysqlnd,opcache,openssl,opentelemetry,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,protobuf,readline,redis,session,shmop,simplexml,soap,sockets,sodium,sqlite3,swoole,swoole-hook-mysql,sysvmsg,sysvsem,sysvshm,tokenizer,xml,xmlreader,xmlwriter,xsl,zip,zlib"

# --- Extension set — legacy (EOL minors) --------------------------------------
# STABLE_EXTENSIONS minus the extensions that don't build uniformly across
# 7.4/8.0/8.1 with the pinned spc:
#   - opentelemetry     : the ext requires PHP 8.0+ (hard-fails on 7.4).
#   - swoole            : spc's pinned swoole needs a newer PHP than 7.4 and
#                         fragments across the legacy minors; dropped so the
#                         legacy set is ONE uniform list (§ verify gate skips the
#                         swoole assertions automatically when it's absent).
#   - swoole-hook-mysql : depends on swoole.
# Everything else (incl. the real pdo_pgsql / pdo_sqlite modules the §5.5 gate
# asserts) is kept. PROVISIONAL: the exact set can only be confirmed by the first
# CI build — if spc rejects another ext on an EOL minor, trim it here.
#
# opcache and protobuf are SPECIAL cases and stay in this list: spc hard-fails
# BOTH on 7.4 because each needs PHP >= 8.0 ("Statically compiled PHP with Zend
# Opcache only available for PHP >= 8.0"; "The latest protobuf extension requires
# PHP 8.0 or later"), but 8.0/8.1 build them fine. Dropping them channel-wide
# would needlessly regress 8.0/8.1, so instead they are stripped PER MINOR for 7.4
# only — see extensions_for_minor() below, which every build/verify step MUST go
# through rather than reading $EXTENSIONS directly.
LEGACY_EXTENSIONS="apcu,bcmath,bz2,calendar,ctype,curl,dba,dom,event,exif,fileinfo,filter,ftp,gd,gmp,iconv,imagick,imap,intl,mbregex,mbstring,mysqli,mysqlnd,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,protobuf,readline,redis,session,shmop,simplexml,soap,sockets,sodium,sqlite3,sysvmsg,sysvsem,sysvshm,tokenizer,xml,xmlreader,xmlwriter,xsl,zip,zlib"

# --- Windows extension set (repackage model, NOT spc) -------------------------
# The Windows leg does NOT use static-php-cli (see the TARGETS note + §W below):
# it repackages the official windows.php.net NTS build, whose extensions ship as
# DLLs. scripts/repackage-windows.sh enables every STABLE_EXTENSIONS member that
# is present as a bundled `ext/php_<name>.dll` in that build (built-ins need no
# line); the intersection is computed at build time, so there is no separate
# Windows list to drift. PECL-only members not in the official bundle are added
# from WINDOWS_PECL below.

# PECL extensions to add to the Windows bundle: prebuilt NTS x64 DLLs pulled from
# windows.php.net/downloads/pecl and dropped into the bundle's ext/. PINNED by
# version for reproducibility (re-verify availability on a bump). Availability is
# per (ext, version, minor, vs-tag): a pin with no matching Windows DLL for a
# given minor is a LOUD WARN (the core bundle still ships), not a hard failure.
# Serializers (igbinary, msgpack) are listed FIRST so they load before redis/apcu,
# which use them. Format: "<ext>:<version>".
WINDOWS_PECL="igbinary:3.2.16 msgpack:3.0.1 redis:6.3.0 apcu:5.1.28"

# imagick is handled separately from WINDOWS_PECL because it is not a single DLL.
# Its PECL zip ships php_imagick.dll AND ImageMagick's own runtime (~160 CORE_RL_*,
# IM_MOD_RL_*, FILTER_* DLLs) which must live next to php.exe, not in ext/ (the
# Windows loader searches the exe dir for a loaded DLL's dependencies). That adds
# ~60 MB to the bundle. Pin the version (re-verify on bump); blank to skip. Still
# not covered (harder or absent Windows builds): imap, event, opentelemetry,
# protobuf — addable on demand via the standard PECL-DLL-in-ext/ mechanism.
WINDOWS_IMAGICK="3.8.1"

# --- static-php-cli pinning (§3, §9) ------------------------------------------
# PIN the ref and re-verify the curl.php c-ares patch on every bump
# (curl.php is under upstream refactor — RFC #959/#963). The §3 patch step
# fails the build if the patch matches nothing, and §5 is the runtime backstop.
SPC_REPO="https://github.com/crazywhalecc/static-php-cli.git"
# 2.8.5 is the first ref that supports PHP 8.5 (2.7.x tops out at 8.4). The §3
# patch (apply-curl-patch.sh) is verified against this ref's curl.php layout;
# re-verify on every bump — the c-ares option location is under upstream churn.
SPC_REF="2.8.5"

# --- Cross-repo ABI partner (§5.4) --------------------------------------------
# forjedio/yerd-php-ext publishes yerd-dump.so / pcov.so that get dlopen'ed into
# these binaries. The §5 gate downloads the matching .so and really loads it.
EXT_REPO="forjedio/yerd-php-ext"
# Fallback ZEND_MODULE_API_NO per minor — used when no real yerd-php-ext .so
# exists to load (a brand-new stable minor, OR every legacy minor, which ships no
# ext at all). These are PHP's published ABI numbers ("PHP API => NNNNNNNN"); for
# stable minors the authoritative source is yerd-php-ext's build config — verify
# there, don't trust these blindly. The legacy (7.4/8.0/8.1) numbers are PHP's own
# published values (no ext partner to reconcile with). Format: "<minor>:<api_no>".
ZEND_API_NOS="7.4:20190902 8.0:20200930 8.1:20210902 8.2:20220829 8.3:20230831 8.4:20240924 8.5:20250925"

# --- Release model (§6) --------------------------------------------------------
RELEASE_TAG="php"                     # single rolling release; create once, never delete

# Both channels live in the ONE rolling release above. This registry maps each
# channel -> its manifest filename. publish.sh unions every channel's referenced
# assets so publishing one channel never prunes another's tarballs (§6). Keep in
# sync with the per-channel case block below. Format: "<channel>:<manifest>".
CHANNELS="stable:php.json legacy:php-legacy.json"
# Windows entries live in a SEPARATE per-channel manifest (§W) so the daemon's
# cli/fpm php.json parser never sees the bundle shape.
WINDOWS_CHANNELS="stable:php-windows.json legacy:php-windows-legacy.json"
# All manifest basenames across channels (unix + windows). Sig = "<name>.minisig".
# publish.sh unions the assets referenced by ALL of these so one channel/manifest
# never prunes another's tarballs.
all_manifest_names() { for c in $CHANNELS $WINDOWS_CHANNELS; do echo "${c#*:}"; done; }

# --- Per-channel knobs (swapped by $CHANNEL) ----------------------------------
# Downstream scripts read SUPPORTED_MINORS / EXTENSIONS / MANIFEST_NAME only, so
# this single switch is the whole of the channel abstraction.
case "$CHANNEL" in
  stable)
    SUPPORTED_MINORS="$STABLE_MINORS"
    EXTENSIONS="$STABLE_EXTENSIONS"
    MANIFEST_NAME="php.json"
    WINDOWS_MANIFEST_NAME="php-windows.json"
    ;;
  legacy)
    SUPPORTED_MINORS="$LEGACY_MINORS"
    EXTENSIONS="$LEGACY_EXTENSIONS"
    MANIFEST_NAME="php-legacy.json"
    WINDOWS_MANIFEST_NAME="php-windows-legacy.json"
    ;;
  *) echo "FATAL: unknown CHANNEL '$CHANNEL' (want: stable|legacy)" >&2; exit 1 ;;
esac
MANIFEST_SIG_NAME="$MANIFEST_NAME.minisig"                 # unix manifest (macos/linux, cli+fpm)
WINDOWS_MANIFEST_SIG_NAME="$WINDOWS_MANIFEST_NAME.minisig" # windows manifest (bundle) — §W

# --- Per-minor extension tweaks (EOL-minor quirks) ----------------------------
# EXTENSIONS is one uniform set per channel, but a few EOL minors reject a member
# the rest of the channel keeps. Deriving the effective set here — instead of
# dropping the member channel-wide — avoids regressing the minors that DO support
# it. Downstream (build-target.sh, verify-artifact.sh) MUST build/verify against
# extensions_for_minor "$MINOR", never $EXTENSIONS directly.
#   - opcache on 7.4:  spc hard-fails "Statically compiled PHP with Zend Opcache
#                      only available for PHP >= 8.0" (validate() throws).
#   - protobuf on 7.4: spc's validate() hard-fails "The latest protobuf extension
#                      requires PHP 8.0 or later".
#   - protobuf on 8.0: passes validate() but the pinned protobuf 5.34.1 C source
#                      does NOT compile on 8.0 (ext/protobuf/array.c: undeclared
#                      arginfo_offsetGet / parse errors — its generated arginfo
#                      needs 8.1+). PECL declares min-php 8.2; only 8.1 (the newest
#                      legacy minor, already published) actually builds it.
# So: 7.4 drops opcache+protobuf; 8.0 drops protobuf; 8.1 keeps everything. (opcache
# and protobuf are the only LEGACY_EXTENSIONS with a throwing spc *validate()* gate
# — verified by sweeping src/SPC/builder/extension/*.php; the 8.0 protobuf drop is
# a *compile* incompatibility found in CI, not a validate() gate.)
# Prints the comma-separated effective set for the given minor to stdout.
# (Unix/spc only — the Windows leg repackages a prebuilt PHP and derives its own
# enable-list in repackage-windows.sh, so it never calls this.)
extensions_for_minor() {
  local minor="${1:?usage: extensions_for_minor <minor>}" exts=",$EXTENSIONS,"
  case "$minor" in
    7.4)                                  # opcache + protobuf need PHP >= 8.0
      exts="${exts//,opcache,/,}"
      exts="${exts//,protobuf,/,}"
      ;;
    8.0)                                  # protobuf 5.34.1 won't compile on 8.0
      exts="${exts//,protobuf,/,}"
      ;;
  esac
  exts="${exts#,}"; exts="${exts%,}"      # trim the sentinel commas
  echo "$exts"
}

# --- Targets (§1) --------------------------------------------------------------
# token | runner | spc wrapper. Runner labels copied from static-php-cli-hosted.
# Consumed by resolve-builds.php; kept here so the target list has one home.
# Format per line: "<os> <arch> <runner> <spc_wrapper>"
read -r -d '' TARGETS <<'EOF' || true
macos aarch64 macos-15 bin/spc
macos x86_64 macos-15-intel bin/spc
linux x86_64 ubuntu-latest bin/spc-gnu-docker
linux aarch64 ubuntu-24.04-arm bin/spc-gnu-docker
windows x86_64 windows-latest repackage
EOF
# §W — Windows differs on BOTH axes:
#   BUILD:    it is not a static-php-cli build. repackage-windows.sh repackages the
#             official windows.php.net NTS build into a directory BUNDLE (php.exe +
#             php-cgi.exe + php8.dll + ext/*.dll + libpq/openssl DLLs + cacert.pem).
#   MANIFEST: its `bundle` entry shape is INCOMPATIBLE with the daemon's cli/fpm
#             php.json parser (crates/yerd-php/src/release.rs). A windows entry in
#             php.json fails the strict deserialize and empties the WHOLE version
#             list, macOS included. So windows entries go in a SEPARATE per-channel
#             manifest (php-windows.json / php-windows-legacy.json), NEVER merged
#             into php.json/php-legacy.json — the same isolation pcov uses. The
#             existing daemon keeps reading unix-only php.json and cannot break; a
#             daemon update reads php-windows.json when running on windows.
# generate-manifest.php emits the two shapes into the two files (`--windows` flag).
# §W — Windows is a DIFFERENT build model. spc builds a STATIC php on Windows,
# which can neither load dynamic extensions (yerd-php-ext's yerd-dump.dll) nor
# link libpq (pgsql). So — like Laravel Herd — the windows leg REPACKAGES the
# official windows.php.net NTS build (php.exe + php-cgi.exe + php8.dll + ext/*.dll
# + libpq/openssl DLLs) into a directory bundle, via scripts/repackage-windows.sh
# (the "repackage" wrapper token above marks it). Consequences vs the unix legs:
#   - the artifact is a directory bundle, not a single-member tarball (§1 relaxed
#     for windows only); the manifest carries a `bundle` asset, not cli/fpm.
#   - php-cgi.exe is the FastCGI serving binary (windows has no fpm SAPI).
#   - extensions load dynamically, so yerd-dump.dll works and pgsql is available.
#   - the c-ares (#59) problem is absent — official windows curl has no c-ares.
# windows builds in BOTH channels: legacy is just another download (7.4=vc15,
# 8.0/8.1=vs16), with none of the Unix legacy patching, so there is nothing to
# gate. All legacy minors get the full extension set (pgsql + PECL included);
# 7.4's only quirk is that gd ships as php_gd2.dll, which repackage-windows.sh
# handles. Each windows minor's enable-list is derived from the official build's
# own ext/ DLLs, so the channel EXTENSIONS split does not apply.

# Base download URL for the rolling release (used by the §5 real-ext gate).
release_base_url() { echo "https://github.com/${1:-$GITHUB_REPOSITORY}/releases/download/${RELEASE_TAG}"; }

# Canonical asset name (§1) — the ONE place the naming convention lives.
# usage: asset_name <php> <revision> <cli|fpm> <os> <arch>
asset_name() { echo "php-$1-$2-$3-$4-$5.tar.gz"; }
