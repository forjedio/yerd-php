#!/usr/bin/env bash
# Resolve the latest upstream patch for each supported minor (§9).
# Emits JSON: {"8.2":"8.2.29","8.3":"8.3.28", ...} to stdout.
#
# Source of truth is php.net's release API:
#   https://www.php.net/releases/?json&version=<minor>
# which returns {"version":"8.4.12", ...} for the newest patch of that minor.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

out="{}"
for minor in $SUPPORTED_MINORS; do
  # --fail so a 404 (e.g. an EOL/unknown minor) aborts rather than silently
  # producing a bogus version; retry to ride out transient php.net hiccups.
  json="$(curl -fsSL --retry 5 --retry-all-errors "https://www.php.net/releases/?json&version=${minor}")"
  patch="$(jq -er '.version' <<<"$json")"
  # Sanity: the returned version must actually be within the requested minor.
  case "$patch" in
    "$minor".*) : ;;
    *) echo "FATAL: php.net returned '$patch' for minor '$minor'" >&2; exit 1 ;;
  esac
  out="$(jq --arg m "$minor" --arg p "$patch" '. + {($m): $p}' <<<"$out")"
done
echo "$out"
