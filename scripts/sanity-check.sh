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

# Whether an asset is on the release — via the API (authoritative + consistent),
# NOT the download CDN (which lags after a --clobber upload).
on_release() {
  gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' 2>/dev/null \
    | grep -qxF "$1"
}

# Verify one manifest: signature + every referenced asset (download + sha256). A
# manifest that isn't published (e.g. a windows manifest before the first windows
# build) is skipped, not an error.
verify_manifest() {
  local m="$1" n=0 i
  if ! on_release "$m"; then
    echo "  $m not published — skipping."
    return 0
  fi
  # Fetch manifest + signature and verify, WITH RETRIES. A just-clobbered asset
  # can serve a stale blob from the release CDN for a few seconds, so a fresh
  # .minisig may not match the fetched manifest on the first try. Genuine
  # corruption still fails every attempt.
  echo "Verifying $m signature (prehashed)…"
  for i in 1 2 3 4 5 6; do
    if curl -fsSL --retry 3 "$base/$m"         -o "$tmp/$m"         2>/dev/null \
    && curl -fsSL --retry 3 "$base/$m.minisig" -o "$tmp/$m.minisig" 2>/dev/null \
    && minisign -V -H -P "$MINISIGN_PUBLIC_KEY" -m "$tmp/$m" -x "$tmp/$m.minisig" >/dev/null 2>&1; then
      echo "  $m signature verified (attempt $i)."
      break
    fi
    [ "$i" = 6 ] && { echo "FATAL: $m failed to fetch/verify after retries (CDN lag or bad signature)"; exit 1; }
    echo "  $m not yet consistent on the CDN (attempt $i) — retrying…"; sleep 6
  done
  echo "Checking every asset $m references (download + sha256)…"
  # cli+fpm on unix entries, bundle on windows entries; skip absent kinds.
  while IFS=$'\t' read -r file sha; do
    [ -z "$file" ] && continue
    n=$((n + 1))
    # sha256 is authenticated by the manifest signature; verify bytes match it.
    # Retry through the same clobber/CDN lag as the signature above.
    for i in 1 2 3 4 5; do
      got="$(curl -fsSL --retry 3 "$base/$file" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
      [ "$got" = "$sha" ] && break
      [ "$i" = 5 ] && { echo "FATAL: sha mismatch for $file (got $got want $sha)"; exit 1; }
      sleep 6
    done
    echo "  ok: $file"
  done < <(jq -r '.builds[] | (.cli, .fpm, .bundle | select(. != null) | .file + "\t" + .sha256)' "$tmp/$m")
  echo "  $m: $n asset(s) verified against the signed manifest."
}

verify_manifest "$MANIFEST_NAME"
verify_manifest "$WINDOWS_MANIFEST_NAME"
echo "sanity-check: OK."
