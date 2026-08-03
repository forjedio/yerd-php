#!/usr/bin/env bash
# Manifest-only refresh (§W) — regenerate + re-sign + re-publish THIS channel's
# unix and windows manifests from the CURRENTLY published manifests, with NO
# rebuild. Every entry's file/sha256/size is carried over from the existing
# manifests (generate-manifest reads them from --old-manifest and never touches a
# tarball), so this is fast and needs no build.
#
# Primary use: split the windows `bundle` entries OUT of php.json into the
# separate php-windows.json (§W) when the binaries are already on the release —
# which both un-breaks the daemon's php.json parser AND stands up the windows
# manifest, without a rebuild.
#
# usage: CHANNEL=stable|legacy bash scripts/refresh-manifests.sh
#   requires: gh authed; GITHUB_REPOSITORY; php; jq; minisign;
#             MINISIGN_SECRET_KEY (+ MINISIGN_PASSWORD if set); MINISIGN_PUBLIC_KEY.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

base="$(release_base_url "$GITHUB_REPOSITORY")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# 1. Fetch the current unix + windows manifests (either may be absent -> {}). The
#    unix manifest may currently ALSO hold windows bundle entries (the pre-split
#    state); merging both and re-splitting routes every entry to the right file.
fetch() { curl -fsSL --retry 5 "$base/$1" -o "$2" 2>/dev/null || printf '{}' > "$2"; }
fetch "$MANIFEST_NAME"         "$work/cur-unix.json"
fetch "$WINDOWS_MANIFEST_NAME" "$work/cur-win.json"
jq -s '{schema:1, builds: ((.[0].builds // []) + (.[1].builds // []))}' \
  "$work/cur-unix.json" "$work/cur-win.json" > "$work/cur-all.json"
echo "refresh: $(jq '.builds | length' "$work/cur-all.json") existing build(s) to re-split for channel '$CHANNEL'."

# 2. Regenerate both manifests from the merged source, with NO built entries
#    (pure carry-over — asset_obj is never called, so no tarballs are needed).
printf '{"include":[]}' > "$work/built.json"; mkdir -p "$work/empty"
php "$here/generate-manifest.php" --built="$work/built.json" --assets-dir="$work/empty" \
    --minors="$SUPPORTED_MINORS" --old-manifest="$work/cur-all.json" > "$MANIFEST_NAME"
php "$here/generate-manifest.php" --built="$work/built.json" --assets-dir="$work/empty" \
    --minors="$SUPPORTED_MINORS" --old-manifest="$work/cur-all.json" --windows > "$WINDOWS_MANIFEST_NAME"
echo "  $MANIFEST_NAME: $(jq '.builds | length' "$MANIFEST_NAME") unix build(s)."
echo "  $WINDOWS_MANIFEST_NAME: $(jq '.builds | length' "$WINDOWS_MANIFEST_NAME") windows build(s)."

# 3. Sign both.
bash "$here/sign-manifest.sh" "$MANIFEST_NAME"         "$MANIFEST_SIG_NAME"
bash "$here/sign-manifest.sh" "$WINDOWS_MANIFEST_NAME" "$WINDOWS_MANIFEST_SIG_NAME"

# 4. Publish (manifest-only: no new tarballs). publish.sh's prune keeps every
#    asset the two fresh manifests reference — including the already-published
#    windows bundles now listed in the windows manifest — and drops true orphans.
mkdir -p "$work/dist"
bash "$here/publish.sh" "$work/dist" \
  "$MANIFEST_NAME" "$MANIFEST_SIG_NAME" \
  "$WINDOWS_MANIFEST_NAME" "$WINDOWS_MANIFEST_SIG_NAME"

echo "refresh-manifests: done for channel '$CHANNEL'."
