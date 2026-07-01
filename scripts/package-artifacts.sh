#!/usr/bin/env bash
# §1 — package the two single-member tarballs with their exact contract names.
#
# Each archive must contain EXACTLY ONE regular file at the archive root:
#   *-cli-* -> a file named `php`
#   *-fpm-* -> a file named `php-fpm`
# No directory, extra members, or symlinks — yerd's extractor rejects anything else.
#
# usage: package-artifacts.sh <php> <revision> <os> <arch> <bindir> <outdir>
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

PHP="${1:?php}"; REV="${2:?revision}"; OS="${3:?os}"; ARCH="${4:?arch}"
BINDIR="${5:?bindir}"; OUTDIR="${6:?outdir}"
mkdir -p "$OUTDIR"

package_one() {
  local kind="$1" binname="$2"
  local src="$BINDIR/$binname"
  [ -f "$src" ] || { echo "FATAL: $src not found"; exit 1; }
  [ -L "$src" ] && { echo "FATAL: $src is a symlink"; exit 1; }

  local out; out="$OUTDIR/$(asset_name "$PHP" "$REV" "$kind" "$OS" "$ARCH")"
  # -C so the member is the bare filename (no leading path); single file only.
  tar -czf "$out" -C "$BINDIR" "$binname"

  # Assert the single-member / bare-name / regular-file shape before publishing.
  local members; members="$(tar -tzf "$out")"
  if [ "$members" != "$binname" ]; then
    echo "FATAL: $out is not a single '$binname' member. Contents:"; echo "$members"; exit 1
  fi
  echo "packaged: $out"
}

package_one cli php
package_one fpm php-fpm
