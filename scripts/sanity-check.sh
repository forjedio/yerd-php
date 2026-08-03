#!/usr/bin/env bash
# §10.8 — post-publish sanity for THIS channel's manifests: the unix manifest
# (php.json / php-legacy.json) and the windows manifest (php-windows.json /
# php-windows-legacy.json — §W). For each, fetch it from the live release, verify
# its minisign signature with the embedded public key, and assert every
# referenced asset is downloadable and its sha256 matches. Read-only.
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

# Verify one manifest: signature + every referenced asset (HEAD + sha256). A
# manifest that isn't published (e.g. a windows manifest before the first windows
# build) is skipped, not an error.
verify_manifest() {
  local m="$1" n=0
  if ! curl -fsSL --retry 5 "$base/$m" -o "$tmp/$m" 2>/dev/null; then
    echo "  $m not published — skipping."
    return 0
  fi
  curl -fsSL --retry 5 "$base/$m.minisig" -o "$tmp/$m.minisig" \
    || { echo "FATAL: $m is published but its signature is missing"; exit 1; }
  echo "Verifying $m signature (prehashed)…"
  minisign -V -H -P "$MINISIGN_PUBLIC_KEY" -m "$tmp/$m" -x "$tmp/$m.minisig" \
    || { echo "FATAL: $m signature failed to verify"; exit 1; }
  echo "Checking every asset $m references (HEAD + sha256)…"
  # cli+fpm on unix entries, bundle on windows entries; skip absent kinds.
  while IFS=$'\t' read -r file sha; do
    [ -z "$file" ] && continue
    n=$((n + 1))
    # sha256 is authenticated by the manifest signature; verify bytes match it.
    got="$(curl -fsSL --retry 5 "$base/$file" | shasum -a 256 | awk '{print $1}')"
    [ "$got" = "$sha" ] || { echo "FATAL: sha mismatch for $file (got $got want $sha)"; exit 1; }
    echo "  ok: $file"
  done < <(jq -r '.builds[] | (.cli, .fpm, .bundle | select(. != null) | .file + "\t" + .sha256)' "$tmp/$m")
  echo "  $m: $n asset(s) verified against the signed manifest."
}

verify_manifest "$MANIFEST_NAME"
verify_manifest "$WINDOWS_MANIFEST_NAME"
echo "sanity-check: OK."
