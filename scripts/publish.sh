#!/usr/bin/env bash
# §6 / §10.4-10.7 — publish to the single rolling release, PRUNE LAST.
#
# A channel run publishes TWO manifests into the one rolling release: the unix
# manifest (php.json / php-legacy.json, cli+fpm) and the windows manifest
# (php-windows.json / php-windows-legacy.json, bundle — §W). They are separate so
# the daemon's cli/fpm parser never sees the bundle shape.
#
# Order is critical for consumer safety: at every instant each live
# (manifest, .minisig) pair must be internally consistent and every asset it
# references must exist. So:
#   1. upload/replace all new *.tar.gz assets
#   2. upload each regenerated manifest, then its detached .minisig
#   3. ONLY THEN delete superseded / out-of-range assets
#
# usage: publish.sh <dist-dir> <manifest> <sig> [<windows-manifest> <windows-sig>]
#   <dist-dir>  contains the freshly built *.tar.gz to upload
#   requires: gh authed; GITHUB_REPOSITORY set; RELEASE_TAG from config.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

DIST="${1:?usage: publish.sh <dist-dir> <manifest> <sig> [<win-manifest> <win-sig>]}"
MANIFEST="${2:?manifest}"
SIG="${3:?sig}"
WIN_MANIFEST="${4:-}"
WIN_SIG="${5:-}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

# Every tarball an entry can reference: cli/fpm on unix, bundle on windows.
manifest_files() { jq -r '.builds[]? | (.cli.file // empty), (.fpm.file // empty), (.bundle.file // empty)' "$1"; }

# 0. Ensure the rolling release exists (create once; never delete — §6).
if ! gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "Creating rolling release '$RELEASE_TAG' (first run)."
  gh release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
    --title "PHP binaries (rolling)" \
    --notes "PHP for yerd. Unix (macos/linux): static CLI+FPM, listed in ${MANIFEST_NAME}. Windows: repackaged windows.php.net bundle, listed SEPARATELY in ${WINDOWS_MANIFEST_NAME}. Do not delete this release/tag."
fi

# 1. Upload/replace all freshly-built tarballs.
shopt -s nullglob
tarballs=("$DIST"/*.tar.gz)
if [ ${#tarballs[@]} -gt 0 ]; then
  echo "Uploading ${#tarballs[@]} tarball(s)…"
  gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --clobber "${tarballs[@]}"
else
  echo "No new tarballs to upload (manifest-only refresh)."
fi

# 2 + 3. Upload each manifest, then its signature (sig must never predate manifest).
echo "Uploading ${MANIFEST_NAME} then ${MANIFEST_SIG_NAME}…"
gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --clobber "$MANIFEST"
gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --clobber "$SIG"
if [ -n "$WIN_MANIFEST" ]; then
  echo "Uploading ${WINDOWS_MANIFEST_NAME} then ${WINDOWS_MANIFEST_SIG_NAME}…"
  gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --clobber "$WIN_MANIFEST"
  gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --clobber "$WIN_SIG"
fi

# 4. PRUNE LAST — delete tarball assets referenced by NO manifest. All channels
# AND both os classes share this ONE release, so the keep-set is the UNION of
# every manifest's referenced assets (§6). We read the manifests we just built
# from disk (freshest), and fetch every OTHER manifest live from the release.
echo "Pruning superseded / out-of-range assets…"

# Snapshot the release's current assets ONCE, AFTER the uploads above (so the
# freshly-published manifests are visible to the sibling-presence check).
mapfile -t current_assets < <(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
  --json assets --jq '.assets[].name') \
  || { echo "FATAL: could not list release assets — refusing to prune blind."; exit 1; }
on_release() { printf '%s\n' "${current_assets[@]:-}" | grep -qxF "$1"; }

keep="$(mktemp)"; trap 'rm -f "$keep"' EXIT

# Files referenced by the manifest(s) we just built (local, fresh on disk).
manifest_files "$MANIFEST" >> "$keep"
published="$MANIFEST_NAME"
if [ -n "$WIN_MANIFEST" ]; then
  manifest_files "$WIN_MANIFEST" >> "$keep"
  published="$published $WINDOWS_MANIFEST_NAME"
fi

# Union in every OTHER manifest's referenced assets (other channels + the os
# class we did not publish this run). A manifest NOT on the release simply hasn't
# published yet (safe to skip). But if it IS on the release, its download MUST
# succeed — otherwise we'd prune its live, still-referenced tarballs and leave a
# signed-but-dangling manifest. So FAIL CLOSED on that case (the same
# anti-fail-open rule the resolve step applies).
for m in $(all_manifest_names); do
  case " $published " in *" $m "*) continue ;; esac
  if ! on_release "$m"; then
    echo "  sibling $m not yet published — nothing of its to keep."
    continue
  fi
  sib="$(mktemp)"
  gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
    --pattern "$m" --output "$sib" --clobber \
    || { rm -f "$sib"; echo "FATAL: sibling manifest $m is on the release but could not be downloaded — refusing to prune (would delete its still-referenced tarballs)."; exit 1; }
  manifest_files "$sib" >> "$keep" \
    || { rm -f "$sib"; echo "FATAL: sibling manifest $m is unparseable — refusing to prune."; exit 1; }
  rm -f "$sib"
  echo "  kept sibling $m's referenced assets."
done

# Every manifest + signature is always kept.
for m in $(all_manifest_names); do echo "$m"; echo "$m.minisig"; done >> "$keep"
sort -u -o "$keep" "$keep"

pruned=0
for a in "${current_assets[@]:-}"; do
  [ -z "$a" ] && continue
  case "$a" in *.tar.gz) ;; *) continue ;; esac   # only ever prune tarballs
  if ! grep -qxF "$a" "$keep"; then
    echo "  prune: $a"
    gh release delete-asset "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" "$a" --yes
    pruned=$((pruned + 1))
  fi
done
echo "publish: done (${pruned} asset(s) pruned)."
