#!/usr/bin/env bash
# §6 — sign php.json with this repo's DEDICATED minisign key, PREHASHED (-H).
#
# Two non-negotiables for yerd's verify_minisign(bytes, sig, allow_legacy=false):
#   1. Prehashed signing is MANDATORY (minisign -H) — a legacy ed25519 sig is
#      rejected at runtime.
#   2. Use this repo's OWN key, never yerd's app-update key. The secret half lives
#      ONLY in this repo's Actions secrets; its public half is embedded in yerdd
#      as PHP_LISTING_PUBLIC_KEY.
#
# The secret key is provided via env MINISIGN_SECRET_KEY (raw file contents) and,
# if the key is password-protected, MINISIGN_PASSWORD. We write the key to a
# private temp file, sign, and shred it.
#
# usage: sign-manifest.sh <manifest-path> <out-sig-path>
set -euo pipefail

MANIFEST="${1:?usage: sign-manifest.sh <manifest> <out-sig>}"
SIG="${2:?usage: sign-manifest.sh <manifest> <out-sig>}"
[ -f "$MANIFEST" ] || { echo "FATAL: manifest $MANIFEST not found"; exit 1; }
[ -n "${MINISIGN_SECRET_KEY:-}" ] || { echo "FATAL: MINISIGN_SECRET_KEY not set"; exit 1; }

keydir="$(mktemp -d)"
key="$keydir/minisign.key"
umask 077
printf '%s' "$MINISIGN_SECRET_KEY" > "$key"
cleanup() { rm -rf "$keydir"; }
trap cleanup EXIT

# -H prehashed (mandatory). Feed the password on stdin (empty line if unset).
printf '%s\n' "${MINISIGN_PASSWORD:-}" | minisign -S -H -s "$key" -m "$MANIFEST" -x "$SIG"

echo "signed (prehashed): $SIG"

# Self-check if the public key is available (belt & braces before publish).
if [ -n "${MINISIGN_PUBLIC_KEY:-}" ]; then
  minisign -V -H -P "$MINISIGN_PUBLIC_KEY" -m "$MANIFEST" -x "$SIG" \
    || { echo "FATAL: signature self-verify failed"; exit 1; }
  echo "signature self-verify OK"
fi
