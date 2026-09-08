#!/usr/bin/env bash
# ALL CHANNELS — pin OpenLDAP to the 2.6 series, applied to config/source.json in
# the cloned spc checkout BEFORE `spc download` reads it.
#
#   ldap -> 2.6.14
#     OpenLDAP 2.7.0 (published 2026-08-06) rewrote tlso_ctx_init() in
#     libraries/libldap/tls_o.c to load certs through OSSL_STORE, and the new
#     blocks declare variables immediately after a `case` label:
#       tls_o.c:547:7: error: a label can only be part of a statement and a
#                      declaration is not a statement
#           X509 *cert = OSSL_STORE_INFO_get0_CERT( info );
#       tls_o.c:548:7: error: expected expression before 'X509_STORE'
#     That is legal C23 but rejected by gcc's default -std=gnu17 in the gnu-docker
#     image, so `make` dies and spc reports "library ldap builder for Linux".
#     2.6.14 predates the OSSL_STORE rewrite entirely (no OSSL_STORE_INFO_get0_CERT
#     anywhere in its tls_o.c) and is the last 2.6.x release, i.e. exactly what the
#     unpinned selector resolved to while the build was green.
#
#     spc 2.8.5 sources ldap as a `filelist` off the OpenLDAP release directory
#     with a regex that matches ANY version, so it silently rolled onto 2.7.0 the
#     moment upstream published it — no SPC_REF bump, no commit here. Every Linux
#     leg has failed since (the first build to actually run after 2026-08-06).
#
#     ldap is not directly requested: it arrives as a lib-suggests of BOTH
#     postgresql (pdo_pgsql/pgsql) and krb5 (imap), and the build passes
#     --with-suggested-libs, so it cannot be dropped by trimming EXTENSIONS.
#
# Applied channel-wide: stable and legacy both build postgresql + krb5, and 2.6.14
# is fine for both. Drop this patch once spc pins ldap itself or OpenLDAP ships a
# 2.7.x that compiles under gnu17 — re-verify on every SPC_REF bump.
#
# The pin is idempotent (a second run sees the narrowed regex and no-ops) and
# FAILS if the field is missing or unexpectedly shaped — an spc change to how ldap
# is sourced must be caught, not silently skipped (§3 curl-patch discipline).
#
# usage: apply-ldap-pin-patch.sh <SPC_DIR>
set -euo pipefail

SPC_DIR="${1:?usage: apply-ldap-pin-patch.sh <SPC_DIR>}"
target="$SPC_DIR/config/source.json"
[ -f "$target" ] || { echo "FATAL: $target not found (spc layout changed? re-verify ldap pin for SPC_REF)"; exit 1; }

# Pin one JSON string field to $want, guarding on a glob that the current value
# must match (so an spc source-layout change is caught, not silently overwritten).
#   $1 jq path   $2 desired value   $3 sanity glob for the current value   $4 label
pin_field() {
  local path="$1" want="$2" glob="$3" label="$4" cur after tmp
  cur="$(jq -r "$path // empty" "$target")"
  [ -n "$cur" ] || { echo "FATAL: $path absent in $target ($label — spc no longer sources it this way? re-verify ldap pin)"; exit 1; }
  if [ "$cur" = "$want" ]; then
    echo "ldap pin: $label already pinned."
    return 0
  fi
  # shellcheck disable=SC2254  # $glob is an intentional case pattern
  case "$cur" in
    $glob) : ;;
    *) echo "FATAL: unexpected $path '$cur' in $target ($label — spc changed its selector? re-verify ldap pin for SPC_REF)"; exit 1 ;;
  esac
  tmp="$(mktemp)"
  jq --arg v "$want" "$path = \$v" "$target" > "$tmp"
  after="$(jq -r "$path // empty" "$tmp")"
  [ "$after" = "$want" ] || { rm -f "$tmp"; echo "FATAL: ldap pin failed to set $path (got '$after')"; exit 1; }
  mv "$tmp" "$target"
  echo "ldap pin: $label pinned ('$cur' -> '$want')."
}

# Narrow the filelist `regex` so only openldap-2.6.14.tgz matches. The OpenLDAP
# release directory keeps every past release, so 2.6.14 stays reachable — unlike
# the libxml2 ghtagtar pin, there is no pagination to widen.
pin_field '.ldap.regex' \
  '/href="(?<file>openldap-(?<version>2\.6\.14)\.tgz)"/' \
  '*openldap-*' \
  'ldap -> 2.6.14 (pre-OSSL_STORE tls_o.c, compiles under gnu17)'
