#!/usr/bin/env bash
# =============================================================================
#  INTERNET MACHINE ONLY. Resolves/refreshes the commit pins in custom_nodes.txt
# =============================================================================
#  Usage:
#    ./scripts/pin_custom_nodes.sh            # fill in only the MISSING pins
#    ./scripts/pin_custom_nodes.sh --update   # re-pin EVERY node to current HEAD
#
#  --update is an explicit, deliberate act: it changes what goes into the image,
#  so it must be followed by a rebuild and a fresh ./scripts/verify_offline.sh.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
LIST=custom_nodes.txt
UPDATE_ALL=0
[ "${1:-}" = "--update" ] && UPDATE_ALL=1

[ -f "$LIST" ] || { echo "FATAL: $LIST not found" >&2; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

changed=0
while IFS= read -r line || [ -n "$line" ]; do
  # Pass comments and blank lines through untouched.
  # NOTE: printf '%s' on an EMPTY line emits nothing at all, so grep would get
  # zero lines and the `$` alternation could never match -- every blank line was
  # then parsed as a node entry with an empty URL. The trailing \n is load-bearing.
  if printf '%s\n' "$line" | grep -qE '^[[:space:]]*(#|$)'; then
    printf '%s\n' "$line" >> "$TMP"; continue
  fi

  url="$(printf '%s' "$line" | awk '{print $1}')"
  ref="$(printf '%s' "$line" | awk '{print $2}')"

  if [ -n "$ref" ] && [ "$UPDATE_ALL" -eq 0 ]; then
    printf '%s\n' "$line" >> "$TMP"; continue
  fi

  if [ -z "$url" ]; then
    echo "FATAL: malformed line in $LIST: [$line]" >&2; exit 1
  fi

  echo "resolving $(basename "$url" .git) ..." >&2
  # `|| true` is required: under `set -e`/`pipefail` a failed ls-remote would
  # abort the script here, silently, before the helpful message below can print.
  sha="$(git ls-remote "$url" HEAD 2>/dev/null | awk '{print $1}' || true)"
  if [ -z "$sha" ]; then
    echo "FATAL: cannot reach $url — are you on the internet-connected machine?" >&2
    exit 1
  fi

  [ "$sha" != "$ref" ] && changed=$((changed + 1))
  printf '%-62s %s\n' "$url" "$sha" >> "$TMP"
done < "$LIST"

mv "$TMP" "$LIST"
trap - EXIT

echo
echo "custom_nodes.txt updated — ${changed} pin(s) changed."
if [ "$changed" -gt 0 ]; then
  echo "Next: rebuild, then re-run ./scripts/verify_offline.sh before exporting."
fi
