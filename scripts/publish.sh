#!/usr/bin/env bash
# §6 / §10.4-10.7 — publish to the single rolling release, PRUNE LAST.
#
# Order is critical for consumer safety: at every instant the live
# (php.json, .minisig) pair must be internally consistent and every asset it
# references must exist. So:
#   1. upload/replace all new *.tar.gz assets
#   2. upload the regenerated php.json
#   3. upload its detached php.json.minisig
#   4. ONLY THEN delete superseded / out-of-range assets
#
# usage: publish.sh <dist-dir> <manifest> <sig>
#   <dist-dir>  contains the freshly built *.tar.gz to upload
#   requires: gh authed; GITHUB_REPOSITORY set; RELEASE_TAG from config.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

DIST="${1:?usage: publish.sh <dist-dir> <manifest> <sig>}"
MANIFEST="${2:?manifest}"
SIG="${3:?sig}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

# 0. Ensure the rolling release exists (create once; never delete — §6).
if ! gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "Creating rolling release '$RELEASE_TAG' (first run)."
  gh release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
    --title "PHP binaries (rolling)" \
    --notes "c-ares-free static PHP (CLI+FPM) for yerd. Machine-readable listing: ${MANIFEST_NAME} (+ ${MANIFEST_SIG_NAME}). Do not delete this release/tag."
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

# 2 + 3. Upload manifest, then its signature (sig must never predate manifest).
echo "Uploading ${MANIFEST_NAME} then ${MANIFEST_SIG_NAME}…"
gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --clobber "$MANIFEST"
gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --clobber "$SIG"

# 4. PRUNE LAST — delete tarball assets not referenced by the NEW manifest.
echo "Pruning superseded / out-of-range assets…"
keep="$(mktemp)"
{
  jq -r '.builds[] | .cli.file, .fpm.file' "$MANIFEST"
  echo "$MANIFEST_NAME"
  echo "$MANIFEST_SIG_NAME"
} | sort -u > "$keep"

# Current tarball assets on the release.
mapfile -t current < <(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
  --json assets --jq '.assets[].name' | grep -E '\.tar\.gz$' || true)

pruned=0
for a in "${current[@]:-}"; do
  [ -z "$a" ] && continue
  if ! grep -qxF "$a" "$keep"; then
    echo "  prune: $a"
    gh release delete-asset "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" "$a" --yes
    pruned=$((pruned + 1))
  fi
done
rm -f "$keep"
echo "publish: done (${pruned} asset(s) pruned)."
