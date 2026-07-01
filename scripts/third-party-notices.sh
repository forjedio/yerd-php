#!/usr/bin/env bash
# §8 — assemble a THIRD-PARTY-NOTICES bundle for PHP + every bundled library.
# Run against a completed spc build (which records per-lib license metadata).
# Ship the result alongside the release and reference it from yerd's docs.
#
# Copyleft to eyeball across the set: ICU, GD, ImageMagick, swoole, openssl,
# imap/krb5. Also confirm readline links libedit (BSD), NOT GNU readline.
#
# usage: third-party-notices.sh <SPC_DIR> <out-file>
set -euo pipefail
SPC_DIR="${1:?usage: third-party-notices.sh <SPC_DIR> <out-file>}"
OUT="${2:?usage: third-party-notices.sh <SPC_DIR> <out-file>}"

{
  echo "THIRD-PARTY NOTICES — yerd-php static PHP distribution"
  echo "Generated from static-php-cli build metadata."
  echo

  # spc exposes per-library license info via `dump-license`; fall back to
  # scraping the recorded source license files if the subcommand is absent.
  if "$SPC_DIR/bin/spc" dump-license --help >/dev/null 2>&1; then
    "$SPC_DIR/bin/spc" dump-license
  else
    echo "(spc dump-license unavailable — collecting LICENSE files from sources)"
    echo
    find "$SPC_DIR/source" -maxdepth 2 -iregex '.*/\(LICENSE\|COPYING\).*' 2>/dev/null | while read -r f; do
      echo "===== $f ====="; cat "$f"; echo
    done
  fi
} > "$OUT"

# §8 assertion: readline must link libedit (BSD), not GPL GNU readline.
if grep -Rqi "with-readline" "$SPC_DIR/config" 2>/dev/null; then
  echo "WARN: build appears to use GNU readline — §8 requires libedit. Investigate." >&2
fi

echo "third-party-notices: wrote $OUT"
