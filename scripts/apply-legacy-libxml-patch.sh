#!/usr/bin/env bash
# LEGACY CHANNEL ONLY — pin the libxml2 + libxslt pair to the 2.13-era generation.
#
# Two coupled version pins (plus a tags-pagination tweak that keeps the libxml2
# pin reachable), applied to config/source.json in the cloned spc checkout BEFORE
# `spc download` reads it:
#
#   libxml2 -> 2.13.x (2.13.9)
#     2.14.0 REMOVED the public `ATTRIBUTE_UNUSED` macro (it lived in
#     include/libxml/xmlexports.h through 2.13.x). 7.4/8.0's ext/libxml/libxml.c
#     still relies on libxml2 providing it:
#       ext/libxml/libxml.c:431: error: expected ')' before 'ATTRIBUTE_UNUSED'
#     PHP fixed this from 8.1 on, so stable (8.2+) and legacy 8.1 build fine
#     against the 2.14/2.15 spc now resolves — only EOL 7.4/8.0 break. 2.13.9 is
#     the last release that still exports the macro.
#
#   libxslt -> 1.1.43
#     spc's pinned libxslt (1.1.45) hard-requires libxml2 >= 2.15.1 in its
#     configure (LIBXML_REQUIRED_VERSION), so the libxml2 downgrade above makes it
#     fail to configure:
#       error: Version 2.13.9 found. You need at least libxml2 2.15.1 ...
#     1.1.44 made that jump; 1.1.43 is the last libxslt needing only >= 2.6.27, so
#     it pairs cleanly with libxml2 2.13.x. libxml2 + libxslt are the ONLY two
#     sources in the set with a libxml2-version gate (imagemagick/libavif/gettext/
#     nghttp2 just link it, no minimum), so no further pin cascades from here.
#
# 8.0/8.1 build identically against this older pair, so it is applied channel-wide
# to keep ONE uniform legacy recipe (cf. the legacy cflags patch). Stable is
# untouched and stays on the latest libxml2/libxslt.
#
# Both pins are idempotent (a second run sees the narrowed selector and no-ops)
# and FAIL if the field is missing or unexpectedly shaped — an spc change to how
# either library is sourced must be caught, not silently skipped (§3 curl-patch
# discipline). Re-verify on every SPC_REF bump.
#
# usage: apply-legacy-libxml-patch.sh <SPC_DIR>
set -euo pipefail

SPC_DIR="${1:?usage: apply-legacy-libxml-patch.sh <SPC_DIR>}"
target="$SPC_DIR/config/source.json"
[ -f "$target" ] || { echo "FATAL: $target not found (spc layout changed? re-verify legacy libxml patch for SPC_REF)"; exit 1; }

# Pin one JSON string field to $want, guarding on a glob that the current value
# must match (so an spc source-layout change is caught, not silently overwritten).
#   $1 jq path (e.g. .libxml2.match)   $2 desired value
#   $3 sanity glob for the current value   $4 human label
pin_field() {
  local path="$1" want="$2" glob="$3" label="$4" cur after tmp
  cur="$(jq -r "$path // empty" "$target")"
  [ -n "$cur" ] || { echo "FATAL: $path absent in $target ($label — spc no longer sources it this way? re-verify legacy libxml patch)"; exit 1; }
  if [ "$cur" = "$want" ]; then
    echo "legacy libxml patch: $label already pinned."
    return 0
  fi
  # shellcheck disable=SC2254  # $glob is an intentional case pattern
  case "$cur" in
    $glob) : ;;
    *) echo "FATAL: unexpected $path '$cur' in $target ($label — spc changed its selector? re-verify legacy libxml patch for SPC_REF)"; exit 1 ;;
  esac
  tmp="$(mktemp)"
  jq --arg v "$want" "$path = \$v" "$target" > "$tmp"
  after="$(jq -r "$path // empty" "$tmp")"
  [ "$after" = "$want" ] || { rm -f "$tmp"; echo "FATAL: legacy libxml patch failed to set $path (got '$after')"; exit 1; }
  mv "$tmp" "$target"
  echo "legacy libxml patch: $label pinned ('$cur' -> '$want')."
}

# Set an OPTIONAL field to $want, adding it if absent (no pre-existence guard).
#   $1 jq path   $2 desired value   $3 human label
set_field() {
  local path="$1" want="$2" label="$3" cur after tmp
  cur="$(jq -r "$path // empty" "$target")"
  if [ "$cur" = "$want" ]; then
    echo "legacy libxml patch: $label already set."
    return 0
  fi
  tmp="$(mktemp)"
  jq --arg v "$want" "$path = \$v" "$target" > "$tmp"
  after="$(jq -r "$path // empty" "$tmp")"
  [ "$after" = "$want" ] || { rm -f "$tmp"; echo "FATAL: legacy libxml patch failed to set $path (got '$after')"; exit 1; }
  mv "$tmp" "$target"
  echo "legacy libxml patch: $label set ('${cur:-<unset>}' -> '$want')."
}

# libxml2: narrow the ghtagtar `match` from "any v2.x tag" to the 2.13 series.
pin_field '.libxml2.match' 'v2\.13\.\d+$' 'v2*' 'libxml2 -> 2.13.x (keeps ATTRIBUTE_UNUSED)'

# libxml2: ask GitHub for 100 tags/page. spc's ghtagtar reads only ONE page of the
# tags API (default 30, no pagination) and takes the first `match` hit. v2.13.9 is
# ~#12 today but drifts down as GNOME publishes newer 2.14/2.15/2.16 tags; without
# this, once >30 newer tags exist the 2.13 series falls off page 1 and the download
# hard-fails ("failed to find libxml2 source"). getLatestGithubTarball appends this
# `query` verbatim to the tags URL. 100/page keeps 2.13.x reachable far past the
# next SPC_REF bump. (Re-verify on bump regardless — the patch header says so.)
set_field '.libxml2.query' '?per_page=100' 'libxml2 tags per_page=100 (keep 2.13.x reachable)'

# libxslt: narrow the filelist `regex` so only libxslt-1.1.43.tar.xz matches.
pin_field '.libxslt.regex' '/href="(?<file>libxslt-(?<version>1\.1\.43)\.tar\.xz)"/' '*libxslt-*' 'libxslt -> 1.1.43 (libxml2 2.13-compatible)'
