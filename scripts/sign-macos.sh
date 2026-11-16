#!/usr/bin/env bash
# §4 — macOS ad-hoc signing. MANDATORY on Apple Silicon: the kernel SIGKILLs any
# native binary lacking at least an ad-hoc signature (independent of Gatekeeper/
# quarantine). yerd spawns php-fpm as a subprocess, so BOTH binaries must be signed.
#
# Full Developer ID notarization is NOT required: yerd downloads via its own HTTP
# client, which sets no com.apple.quarantine xattr, so Gatekeeper never fires.
#
# Ad-hoc signing without `--options runtime` leaves library validation OFF, which
# is what lets FFI dlopen Homebrew's libvips (yerd#252) and php load yerd-dump/pcov.
# A move to Developer ID + hardened runtime / notarization would need the
# com.apple.security.cs.disable-library-validation entitlement for both to work.
#
# usage: sign-macos.sh <binary> [<binary> ...]
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: sign-macos.sh <binary> [<binary> ...]"; exit 1; }

for b in "$@"; do
  [ -f "$b" ] || { echo "FATAL: $b not found"; exit 1; }
  codesign --remove-signature "$b" 2>/dev/null || true
  codesign -s - -f "$b"
  codesign --verify --strict "$b"
  # mode bits are not covered by the signature, so chmod after signing is fine.
  chmod +x "$b"
  echo "signed (ad-hoc): $b"
done
