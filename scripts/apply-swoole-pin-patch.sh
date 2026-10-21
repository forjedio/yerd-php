#!/usr/bin/env bash
# ALL CHANNELS — pin swoole to v6.2.2, applied to config/source.json in the cloned
# spc checkout BEFORE `spc download` reads it.
#
#   swoole -> v6.2.2
#     swoole v6.2.3 (published 2026-09-22) added a non-Linux fallback for
#     sw_atomic_futex_wait() in src/core/misc.cc that polls with sw_usleep(), but
#     the release never declares sw_usleep anywhere, so clang on macOS stops with:
#       misc.cc:175:9: error: use of undeclared identifier 'sw_usleep'
#     Linux takes the real futex path and never compiles that branch, which is why
#     only the macOS legs broke. Every macOS build has failed since 2026-09-25.
#     v6.1.10 carries the same fallback, so 6.2.2 is the pin, i.e. exactly what
#     the unpinned selector resolved to while the build was green. Fixed upstream
#     in master (swoole/swoole-src#6243, adds include/swoole_posix.h) but not yet
#     in a stable release.
#
#     spc 2.8.5 sources swoole as a `ghtar` off the GitHub releases API with a
#     `match` of "v6\.+" and prefer-stable, so it rolled onto 6.2.3 the moment
#     upstream published it — no SPC_REF bump, no commit here.
#
# Applied channel-wide for symmetry with the ldap pin; legacy doesn't build swoole,
# so it is a no-op there. Drop this patch once swoole ships a stable release with
# the #6243 fix — re-verify on every SPC_REF bump.
#
# The pin is idempotent (a second run sees the narrowed match and no-ops) and
# FAILS if the field is missing or unexpectedly shaped — an spc change to how
# swoole is sourced must be caught, not silently skipped (§3 curl-patch discipline).
#
# usage: apply-swoole-pin-patch.sh <SPC_DIR>
set -euo pipefail

SPC_DIR="${1:?usage: apply-swoole-pin-patch.sh <SPC_DIR>}"
target="$SPC_DIR/config/source.json"
[ -f "$target" ] || { echo "FATAL: $target not found (spc layout changed? re-verify swoole pin for SPC_REF)"; exit 1; }

# Pin one JSON string field to $want, guarding on a glob that the current value
# must match (so an spc source-layout change is caught, not silently overwritten).
#   $1 jq path   $2 desired value   $3 sanity glob for the current value   $4 label
pin_field() {
  local path="$1" want="$2" glob="$3" label="$4" cur after tmp
  cur="$(jq -r "$path // empty" "$target")"
  [ -n "$cur" ] || { echo "FATAL: $path absent in $target ($label — spc no longer sources it this way? re-verify swoole pin)"; exit 1; }
  if [ "$cur" = "$want" ]; then
    echo "swoole pin: $label already pinned."
    return 0
  fi
  # shellcheck disable=SC2254  # $glob is an intentional case pattern
  case "$cur" in
    $glob) : ;;
    *) echo "FATAL: unexpected $path '$cur' in $target ($label — spc changed its selector? re-verify swoole pin for SPC_REF)"; exit 1 ;;
  esac
  tmp="$(mktemp)"
  jq --arg v "$want" "$path = \$v" "$target" > "$tmp"
  after="$(jq -r "$path // empty" "$tmp")"
  [ "$after" = "$want" ] || { rm -f "$tmp"; echo "FATAL: swoole pin failed to set $path (got '$after')"; exit 1; }
  mv "$tmp" "$target"
  echo "swoole pin: $label pinned ('$cur' -> '$want')."
}

# Set an OPTIONAL field to $want, adding it if absent (no pre-existence guard).
#   $1 jq path   $2 desired value   $3 human label
set_field() {
  local path="$1" want="$2" label="$3" cur after tmp
  cur="$(jq -r "$path // empty" "$target")"
  if [ "$cur" = "$want" ]; then
    echo "swoole pin: $label already set."
    return 0
  fi
  tmp="$(mktemp)"
  jq --arg v "$want" "$path = \$v" "$target" > "$tmp"
  after="$(jq -r "$path // empty" "$tmp")"
  [ "$after" = "$want" ] || { rm -f "$tmp"; echo "FATAL: swoole pin failed to set $path (got '$after')"; exit 1; }
  mv "$tmp" "$target"
  echo "swoole pin: $label set ('${cur:-<unset>}' -> '$want')."
}

# Narrow the ghtar `match` so only the v6.2.2 release matches. spc tests it against
# each release's tarball_url (".../tarball/v6.2.2"), hence the anchored tail.
pin_field '.swoole.match' '/v6\.2\.2$' 'v6*' 'swoole -> v6.2.2 (pre-sw_usleep futex fallback)'
# Ask GitHub for 100 releases/page. spc's ghtar reads only ONE page of the releases
# API (default 30, no pagination); v6.2.2 is ~#4 today but drifts down as swoole
# publishes 6.1.x/6.2.x/6.3.x releases. getLatestGithubTarball appends `query`
# verbatim to the releases URL.
set_field '.swoole.query' '?per_page=100' 'swoole releases per_page=100 (keep v6.2.2 reachable)'
