#!/usr/bin/env bash
# §3 — force curl's c-ares backend OFF in the static-php-cli source, and FAIL the
# build if the patch matched nothing (an upstream curl.php refactor could silently
# turn the sed into a no-op; §5 is the second line of defence at runtime).
#
# usage: apply-curl-patch.sh <SPC_DIR>
set -euo pipefail

SPC_DIR="${1:?usage: apply-curl-patch.sh <SPC_DIR>}"
target="$SPC_DIR/src/Package/Target/curl.php"
[ -f "$target" ] || { echo "FATAL: $target not found (spc layout changed?)"; exit 1; }

# sha1 helper (sha1sum on Linux, shasum on macOS).
sha1() { if command -v sha1sum >/dev/null; then sha1sum "$1" | awk '{print $1}'; else shasum -a1 "$1" | awk '{print $1}'; fi; }

before="$(sha1 "$target")"
sed -i.bak -E "s/->optionalPackage\('libcares', *'-DENABLE_ARES=ON'\)/->optionalPackage('libcares', '-DENABLE_ARES=OFF', '-DENABLE_ARES=OFF')/" \
  "$target"
after="$(sha1 "$target")"

if [ "$before" != "$after" ] && grep -q "ENABLE_ARES=OFF" "$target"; then
  echo "curl.php c-ares patch applied."
  rm -f "$target.bak"
else
  echo "FATAL: curl.php c-ares patch did not apply (upstream refactor? re-verify §3 for SPC_REF)"
  exit 1
fi
