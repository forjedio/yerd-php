#!/usr/bin/env bash
# LEGACY CHANNEL ONLY — pin libxml2 to the 2.13 series for the php-src compile.
#
# libxml2 2.14.0 REMOVED the public `ATTRIBUTE_UNUSED` macro (it lived in
# include/libxml/xmlexports.h through 2.13.x). 7.4/8.0's ext/libxml/libxml.c
# still relies on libxml2 providing it:
#   ext/libxml/libxml.c:431: error: expected ')' before 'ATTRIBUTE_UNUSED'
#     ... php_libxml_output_buffer_create_filename(..., int compression ATTRIBUTE_UNUSED)
# PHP fixed this upstream from 8.1 onward (8.1.x got the backport), which is why
# stable (8.2+) AND legacy 8.1 build fine against the 2.14 that spc now resolves —
# only the EOL, never-patched 7.4/8.0 sources break. Pinning libxml2 back to the
# last 2.13 (2.13.9, which still exports ATTRIBUTE_UNUSED) restores the macro for
# the whole legacy channel; 8.0/8.1 compile against 2.13 identically, so the pin
# is applied channel-wide to keep ONE uniform legacy recipe (cf. the §-style
# legacy cflags patch). Stable is untouched and stays on the latest 2.14.
#
# Mechanism: spc resolves libxml2 as a `ghtagtar` source whose `match` regex
# selects the newest matching GNOME/libxml2 tag. Narrowing that regex from
# "v2\.\d+\.\d+$" (=> latest 2.14) to "v2\.13\.\d+$" (=> latest 2.13) pins it
# without touching anything else. Edits config/source.json in the cloned spc
# checkout, BEFORE `spc download` reads it.
#
# Idempotent (a second run sees the already-narrowed regex and no-ops) and FAILS
# if it matched nothing — an spc change to how libxml2 is sourced must be caught,
# not silently skipped (§3 curl-patch discipline). Re-verify on every SPC_REF bump.
#
# usage: apply-legacy-libxml-patch.sh <SPC_DIR>
set -euo pipefail

SPC_DIR="${1:?usage: apply-legacy-libxml-patch.sh <SPC_DIR>}"
target="$SPC_DIR/config/source.json"
[ -f "$target" ] || { echo "FATAL: $target not found (spc layout changed? re-verify legacy libxml patch for SPC_REF)"; exit 1; }

# The 2.13 series is the last to export ATTRIBUTE_UNUSED; 2.13.9 is its tip.
PIN_MATCH='v2\.13\.\d+$'

cur="$(jq -r '.libxml2.match // empty' "$target")"
[ -n "$cur" ] || { echo "FATAL: .libxml2.match absent in $target (spc no longer sources libxml2 as a matched tag? re-verify legacy libxml patch)"; exit 1; }

if [ "$cur" = "$PIN_MATCH" ]; then
  echo "legacy libxml patch already applied (libxml2.match already pinned to '$PIN_MATCH')."
  exit 0
fi

# Guard against a silent upstream change: we only know how to pin the broad
# "any 2.x tag" matcher we were written against. Anything else is unexpected.
case "$cur" in
  'v2\.'*) : ;;
  *) echo "FATAL: unexpected .libxml2.match '$cur' in $target (spc changed its libxml2 pinning? re-verify legacy libxml patch for SPC_REF)"; exit 1 ;;
esac

tmp="$(mktemp)"
jq --arg m "$PIN_MATCH" '.libxml2.match = $m' "$target" > "$tmp"
after="$(jq -r '.libxml2.match // empty' "$tmp")"
[ "$after" = "$PIN_MATCH" ] || { rm -f "$tmp"; echo "FATAL: legacy libxml patch failed to set libxml2.match (got '$after')"; exit 1; }
mv "$tmp" "$target"
echo "legacy libxml patch applied (libxml2.match '$cur' -> '$PIN_MATCH', pins libxml2 to 2.13.x)."
