#!/usr/bin/env bash
# ALL CHANNELS — make spc's ext-imap "already bundled" skip require a real
# ext/imap/config.m4, and FAIL the build if the patch matched nothing.
#
#   PHP 8.4.27 / 8.5.12 (published 2026-10) ship a stray
#     php-src/ext/imap/tests/oom_imap_mime_header_decode.phpt
#   even though imap left core in 8.4 (it is PECL now, spc source `ext-imap`).
#   spc 2.8.5's SourceManager::initSource() special-cases ext-imap: if
#   php-src/ext/imap already exists it assumes the PHP < 8.4 bundled copy and
#   `continue`s without extracting the PECL tarball. The tests-only dir trips that
#   skip, so configure dies with:
#     File system error: Reading file /app/source/php-src/ext/imap/config.m4 failed
#   8.4.26 / 8.5.11 have no ext/imap at all, which is why they built.
#
#   Narrowing the skip to "config.m4 present" keeps the < 8.4 behaviour (the
#   bundled ext has config.m4) and sends the stray dir down spc's normal
#   hash-mismatch path: remove the dir, extract the PECL source into it.
#
# Not fixed upstream as of spc main (2026-10-21) — drop once an SPC_REF bump
# carries an equivalent check; re-verify on every bump.
#
# usage: apply-imap-extract-patch.sh <SPC_DIR>
set -euo pipefail

SPC_DIR="${1:?usage: apply-imap-extract-patch.sh <SPC_DIR>}"
target="$SPC_DIR/src/SPC/store/SourceManager.php"
[ -f "$target" ] || { echo "FATAL: $target not found (spc layout changed? re-verify imap extract patch for SPC_REF)"; exit 1; }

if grep -qF "\$source === 'ext-imap' && file_exists(\"{\$check}/config.m4\")" "$target"; then
  echo "SourceManager.php ext-imap patch already applied."
  exit 0
fi

# sha1 helper (sha1sum on Linux, shasum on macOS).
sha1() { if command -v sha1sum >/dev/null; then sha1sum "$1" | awk '{print $1}'; else shasum -a1 "$1" | awk '{print $1}'; fi; }

before="$(sha1 "$target")"
sed -i.bak -E "s/if \(\\\$source === 'ext-imap'\) \{/if (\$source === 'ext-imap' \&\& file_exists(\"{\$check}\/config.m4\")) {/" \
  "$target"
after="$(sha1 "$target")"

if [ "$before" != "$after" ] && grep -qF "\$source === 'ext-imap' && file_exists(\"{\$check}/config.m4\")" "$target"; then
  echo "SourceManager.php ext-imap patch applied."
  rm -f "$target.bak"
else
  echo "FATAL: SourceManager.php ext-imap patch did not apply (upstream refactor? re-verify imap extract patch for SPC_REF)"
  exit 1
fi
