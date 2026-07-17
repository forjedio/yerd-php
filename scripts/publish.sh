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

# 4. PRUNE LAST — delete tarball assets referenced by NO channel's manifest.
# Both channels (stable/legacy) share this ONE release, so the keep-set is the
# UNION of every channel's referenced assets — pruning must never delete a
# sibling channel's tarballs. We use the fresh manifest we just built for THIS
# channel, plus each other channel's manifest fetched live from the release.
echo "Pruning superseded / out-of-range assets…"

# Snapshot the release's current assets ONCE (reused for the sibling-presence
# check and the prune scan). Refuse to prune blind if this can't be read.
mapfile -t current_assets < <(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
  --json assets --jq '.assets[].name') \
  || { echo "FATAL: could not list release assets — refusing to prune blind."; exit 1; }
on_release() { printf '%s\n' "${current_assets[@]:-}" | grep -qxF "$1"; }

keep="$(mktemp)"; trap 'rm -f "$keep"' EXIT

# Files referenced by the manifest we just built (fresh, on disk).
jq -r '.builds[] | .cli.file, .fpm.file' "$MANIFEST" >> "$keep"

# Union in every OTHER channel's referenced assets. A sibling manifest that is
# NOT among the release's current assets simply hasn't published yet (safe to
# skip). But if it IS on the release, its download MUST succeed — otherwise we'd
# prune its live, still-referenced tarballs and leave a signed-but-dangling
# manifest. So FAIL CLOSED on that case (never default a fetch error to empty —
# the same anti-fail-open rule the resolve step applies).
for m in $(all_manifest_names); do
  [ "$m" = "$MANIFEST_NAME" ] && continue
  if ! on_release "$m"; then
    echo "  sibling $m not yet published — nothing of its to keep."
    continue
  fi
  sib="$(mktemp)"
  gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
    --pattern "$m" --output "$sib" --clobber \
    || { rm -f "$sib"; echo "FATAL: sibling manifest $m is on the release but could not be downloaded — refusing to prune (would delete its still-referenced tarballs)."; exit 1; }
  jq -r '.builds[]? | .cli.file, .fpm.file' "$sib" >> "$keep" \
    || { rm -f "$sib"; echo "FATAL: sibling manifest $m is unparseable — refusing to prune."; exit 1; }
  rm -f "$sib"
  echo "  kept sibling $m's referenced assets."
done

# Every channel's manifest + signature is always kept.
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
