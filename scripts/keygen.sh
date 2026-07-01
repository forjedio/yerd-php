#!/usr/bin/env bash
# One-time setup (§6): generate this repo's DEDICATED minisign keypair.
#
# DO NOT reuse yerd's app-update key (UPDATE_PUBLIC_KEY). This repo gets its own.
#   - secret half  -> store as GitHub Actions secret  MINISIGN_SECRET_KEY
#                     (+ MINISIGN_PASSWORD if you set a password below)
#   - public half  -> store as Actions *variable* MINISIGN_PUBLIC_KEY (for CI
#                     self-verify/sanity) AND embed in yerdd as PHP_LISTING_PUBLIC_KEY
#
# The secret key is printed once. Never commit it. Rotating it later requires
# shipping a new yerd with the new PHP_LISTING_PUBLIC_KEY (§6 key rotation).
#
# usage: keygen.sh [output-dir]   (default: ./keys, git-ignored)
set -euo pipefail
OUT="${1:-keys}"
mkdir -p "$OUT"; chmod 700 "$OUT"
sec="$OUT/yerd-php-minisign.key"
pub="$OUT/yerd-php-minisign.pub"

[ -e "$sec" ] && { echo "refusing to overwrite existing $sec"; exit 1; }

echo "Generating dedicated minisign keypair (you'll be asked for a password)…"
echo "Tip: a password is recommended; set the same value as MINISIGN_PASSWORD secret."
minisign -G -p "$pub" -s "$sec"

echo
echo "== public key (base64 line — embed in yerdd as PHP_LISTING_PUBLIC_KEY) =="
tail -1 "$pub"
echo
echo "== next steps =="
cat <<EOF
  gh secret set MINISIGN_SECRET_KEY   < "$sec"
  gh secret set MINISIGN_PASSWORD                 # if you set one (else skip)
  gh variable set MINISIGN_PUBLIC_KEY --body "\$(tail -1 "$pub")"
Then embed the public key in yerdd as PHP_LISTING_PUBLIC_KEY and delete $sec locally.
EOF
