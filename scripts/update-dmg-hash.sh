#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_NIX="$ROOT_DIR/package.nix"
URL="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"

if ! command -v nix >/dev/null 2>&1; then
  echo "nix is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

new_hash="$(nix store prefetch-file --json "$URL" | jq -r '.hash')"

if [[ -z "$new_hash" || "$new_hash" == "null" ]]; then
  echo "Failed to resolve new hash from $URL" >&2
  exit 1
fi

current_hash="$(awk '
  /src = fetchurl \{/ { in_src=1 }
  in_src && /hash = "sha256-/ {
    match($0, /sha256-[^"]+/)
    if (RSTART > 0) {
      print substr($0, RSTART, RLENGTH)
      exit
    }
  }
  in_src && /^[[:space:]]*};$/ { in_src=0 }
' "$PACKAGE_NIX")"

if [[ -z "$current_hash" ]]; then
  echo "Could not locate current DMG hash in $PACKAGE_NIX" >&2
  exit 1
fi

if [[ "$current_hash" == "$new_hash" ]]; then
  echo "No change: $current_hash"
  exit 0
fi

awk -v new_hash="$new_hash" '
  /src = fetchurl \{/ { in_src=1 }
  in_src && /hash = "sha256-/ && !updated {
    sub(/sha256-[^"]+/, new_hash)
    updated=1
  }
  in_src && /^[[:space:]]*};$/ { in_src=0 }
  { print }
  END {
    if (!updated) {
      print "Failed to update src hash" > "/dev/stderr"
      exit 1
    }
  }
' "$PACKAGE_NIX" > "$PACKAGE_NIX.tmp"

mv "$PACKAGE_NIX.tmp" "$PACKAGE_NIX"

echo "Updated DMG hash: $current_hash -> $new_hash"
