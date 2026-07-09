#!/usr/bin/env bash
# Single source of truth for build configuration.
# Sourced by every script and exported into the CI environment.
#
# Authoritative brief: yerd-php-AGENTS.md. If this disagrees with it, the brief wins.

# --- Supported PHP minors (§2) -------------------------------------------------
# Every minor >= 8.2 that upstream still supports. 8.2 is yerd's floor.
# Add a minor when it GAs; drop it when it EOLs below the floor.
SUPPORTED_MINORS="8.2 8.3 8.4 8.5"

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
EXTENSIONS="apcu,bcmath,bz2,calendar,ctype,curl,dba,dom,event,exif,fileinfo,filter,ftp,gd,gmp,iconv,imagick,imap,intl,mbregex,mbstring,mysqli,mysqlnd,opcache,openssl,opentelemetry,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,protobuf,readline,redis,session,shmop,simplexml,soap,sockets,sodium,sqlite3,swoole,swoole-hook-mysql,sysvmsg,sysvsem,sysvshm,tokenizer,xml,xmlreader,xmlwriter,xsl,zip,zlib"

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
# Fallback only (brand-new minor with no published ext yet): ZEND_MODULE_API_NO
# that yerd-php-ext pins per minor. These are PHP's published ABI numbers; the
# authoritative source is yerd-php-ext's build config — verify there, don't trust
# these blindly. Format: "<minor>:<api_no>".
ZEND_API_NOS="8.2:20220829 8.3:20230831 8.4:20240924 8.5:20250925"

# --- Release model (§6) --------------------------------------------------------
RELEASE_TAG="php"                     # single rolling release; create once, never delete
MANIFEST_NAME="php.json"
MANIFEST_SIG_NAME="php.json.minisig"

# --- Targets (§1) --------------------------------------------------------------
# token | runner | spc wrapper. Runner labels copied from static-php-cli-hosted.
# Consumed by resolve-builds.php; kept here so the target list has one home.
# Format per line: "<os> <arch> <runner> <spc_wrapper>"
read -r -d '' TARGETS <<'EOF' || true
macos aarch64 macos-15 bin/spc
macos x86_64 macos-15-intel bin/spc
linux x86_64 ubuntu-latest bin/spc-gnu-docker
linux aarch64 ubuntu-24.04-arm bin/spc-gnu-docker
EOF

# Base download URL for the rolling release (used by the §5 real-ext gate).
release_base_url() { echo "https://github.com/${1:-$GITHUB_REPOSITORY}/releases/download/${RELEASE_TAG}"; }

# Canonical asset name (§1) — the ONE place the naming convention lives.
# usage: asset_name <php> <revision> <cli|fpm> <os> <arch>
asset_name() { echo "php-$1-$2-$3-$4-$5.tar.gz"; }
