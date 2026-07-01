#!/usr/bin/env bash
# Emit the §1 target table (from config.sh) as a JSON array to stdout:
#   [{"os":"macos","arch":"aarch64","runner":"macos-15","spc":"bin/spc"}, ...]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

arr="[]"
while read -r os arch runner spc; do
  [ -z "${os:-}" ] && continue
  arr="$(jq \
    --arg os "$os" --arg arch "$arch" --arg runner "$runner" --arg spc "$spc" \
    '. + [{os:$os, arch:$arch, runner:$runner, spc:$spc}]' <<<"$arr")"
done <<<"$TARGETS"
echo "$arr"
