#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NIX="package.nix"
URL="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"

echo "Fetching DMG from $URL..."
TMP=$(mktemp /tmp/Codex.XXXXXX.dmg)
trap 'rm -f "$TMP"' EXIT

curl -fsSL -o "$TMP" "$URL"

# Compute sha256 in SRI format (sha256-<base64>)
HASH_HEX=$(sha256sum "$TMP" | awk '{print $1}')
HASH_B64=$(echo "$HASH_HEX" | xxd -r -p | base64 -w0)
NEW_HASH="sha256-${HASH_B64}"

echo "New hash: $NEW_HASH"

# Extract the current DMG hash (specifically the one after the Codex.dmg URL)
CURRENT_HASH=$(python3 -c "
import re, sys
content = open('$PACKAGE_NIX').read()
m = re.search(r'url = \"https://persistent\.oaistatic\.com/codex-app-prod/Codex\.dmg\";\s*\n\s*hash = \"([^\"]+)\"', content)
if m:
    print(m.group(1))
else:
    sys.exit(1)
")

echo "Current hash: $CURRENT_HASH"

if [ "$NEW_HASH" = "$CURRENT_HASH" ]; then
  echo "Hash unchanged, nothing to do."
  exit 0
fi

# Update only the DMG hash in package.nix
python3 -c "
import re
content = open('$PACKAGE_NIX').read()
content = re.sub(
    r'(url = \"https://persistent\.oaistatic\.com/codex-app-prod/Codex\.dmg\";\s*\n\s*hash = \")[^\"]+(\";)',
    r'\g<1>${NEW_HASH}\g<2>',
    content
)
open('$PACKAGE_NIX', 'w').write(content)
"

echo "Updated $PACKAGE_NIX with new hash."
