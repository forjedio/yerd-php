#!/usr/bin/env bash
# §10.8 — post-publish sanity: fetch php.json from the live release, verify its
# signature with the embedded public key, and assert every referenced asset is
# downloadable and its sha256 matches. Read-only; safe to run any time.
#
# usage: sanity-check.sh
#   requires: MINISIGN_PUBLIC_KEY (the PHP_LISTING_PUBLIC_KEY yerdd embeds),
#             GITHUB_REPOSITORY, curl, jq, minisign.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
: "${MINISIGN_PUBLIC_KEY:?MINISIGN_PUBLIC_KEY must be set}"
base="$(release_base_url "$GITHUB_REPOSITORY")"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 5 "$base/$MANIFEST_NAME"     -o "$tmp/$MANIFEST_NAME"
curl -fsSL --retry 5 "$base/$MANIFEST_SIG_NAME" -o "$tmp/$MANIFEST_SIG_NAME"

echo "Verifying manifest signature (prehashed)…"
minisign -V -H -P "$MINISIGN_PUBLIC_KEY" -m "$tmp/$MANIFEST_NAME" -x "$tmp/$MANIFEST_SIG_NAME" \
  || { echo "FATAL: manifest signature failed to verify"; exit 1; }

echo "Checking every referenced asset (HEAD + sha256)…"
n=0
while IFS=$'\t' read -r file sha; do
  n=$((n + 1))
  # sha256 is authenticated by the manifest signature; verify bytes match it.
  got="$(curl -fsSL --retry 5 "$base/$file" | shasum -a 256 | awk '{print $1}')"
  [ "$got" = "$sha" ] || { echo "FATAL: sha mismatch for $file (got $got want $sha)"; exit 1; }
  echo "  ok: $file"
done < <(jq -r '.builds[] | (.cli.file+"\t"+.cli.sha256), (.fpm.file+"\t"+.fpm.sha256)' "$tmp/$MANIFEST_NAME")

echo "sanity-check: OK ($n assets verified against signed manifest)."
