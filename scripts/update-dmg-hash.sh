#!/usr/bin/env bash
# update-dmg-hash.sh — Update DMG hash, native module versions, and tarball
# hashes in package.nix.  Designed to run in CI (ubuntu-latest + Nix).
#
# What it does:
#   1. Prefetch the latest Codex.dmg → new SRI hash.
#   2. Extract the DMG (7z) → extract app.asar (asar) → read bundled
#      better-sqlite3 and node-pty versions from their package.json files.
#   3. Compare everything to what's pinned in package.nix.
#   4. If anything changed, update package.nix with new hashes/versions.
#
# Requirements (provided via nix shell in CI):
#   nix, jq, 7z, node, asar
set -euo pipefail

###############################################################################
# Paths & constants
###############################################################################
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_NIX="$ROOT_DIR/package.nix"
DMG_URL="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
NPM_REGISTRY="https://registry.npmjs.org"

###############################################################################
# Prerequisite checks
###############################################################################
for cmd in nix jq 7z node asar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' is required but not found on PATH." >&2
    echo "Hint: nix shell nixpkgs#p7zip nixpkgs#nodejs_20 nixpkgs#nodePackages.asar" >&2
    exit 1
  fi
done

###############################################################################
# Temp directory with cleanup
###############################################################################
WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

###############################################################################
# Step 1 — Prefetch DMG and get new SRI hash
###############################################################################
echo "==> Prefetching DMG from $DMG_URL …"
prefetch_json="$(nix store prefetch-file --json "$DMG_URL")"
new_dmg_hash="$(echo "$prefetch_json" | jq -r '.hash')"
dmg_store_path="$(echo "$prefetch_json" | jq -r '.storePath')"

if [[ -z "$new_dmg_hash" || "$new_dmg_hash" == "null" ]]; then
  echo "ERROR: Failed to resolve SRI hash for DMG." >&2
  exit 1
fi
echo "    DMG hash: $new_dmg_hash"

###############################################################################
# Step 2 — Extract DMG → Codex.app → app.asar → read native module versions
###############################################################################
echo "==> Extracting DMG …"
DMG_EXTRACT="$WORK_DIR/dmg-extract"
mkdir -p "$DMG_EXTRACT"

rc=0
7z x -y "$dmg_store_path" -o"$DMG_EXTRACT" >/dev/null 2>&1 || rc=$?
if (( rc > 2 )); then
  echo "ERROR: 7z fatal error (exit code $rc)." >&2
  exit 1
fi
echo "    7z exited with rc=$rc (OK)"

APP_PATH="$(find "$DMG_EXTRACT" -name "Codex.app" -type d | head -1)"
if [[ -z "$APP_PATH" ]]; then
  echo "ERROR: Could not find Codex.app in extracted DMG." >&2
  find "$DMG_EXTRACT" -type d >&2
  exit 1
fi
echo "    Found app at: $APP_PATH"

ASAR_FILE="$APP_PATH/Contents/Resources/app.asar"
if [[ ! -f "$ASAR_FILE" ]]; then
  echo "ERROR: app.asar not found at $ASAR_FILE" >&2
  exit 1
fi

echo "==> Extracting app.asar …"
ASAR_EXTRACT="$WORK_DIR/app-extracted"
asar extract "$ASAR_FILE" "$ASAR_EXTRACT"

# Read bundled native module versions
app_better_sqlite3_ver="$(node -p "require('$ASAR_EXTRACT/node_modules/better-sqlite3/package.json').version")"
app_node_pty_ver="$(node -p "require('$ASAR_EXTRACT/node_modules/node-pty/package.json').version")"

echo "    Bundled better-sqlite3: $app_better_sqlite3_ver"
echo "    Bundled node-pty:       $app_node_pty_ver"

###############################################################################
# Step 3 — Read current values from package.nix
###############################################################################
echo "==> Reading current values from package.nix …"

current_dmg_hash="$(sed -n '/^[[:space:]]*src = fetchurl {/,/^[[:space:]]*};/{
  s/.*hash = "\(sha256-[^"]*\)".*/\1/p
}' "$PACKAGE_NIX" | head -1)"

current_better_sqlite3_ver="$(sed -n 's/^[[:space:]]*betterSqlite3Version = "\([^"]*\)".*/\1/p' "$PACKAGE_NIX")"
current_node_pty_ver="$(sed -n 's/^[[:space:]]*nodePtyVersion = "\([^"]*\)".*/\1/p' "$PACKAGE_NIX")"

echo "    Current DMG hash:            $current_dmg_hash"
echo "    Current betterSqlite3Version: $current_better_sqlite3_ver"
echo "    Current nodePtyVersion:       $current_node_pty_ver"

###############################################################################
# Step 4 — Determine what changed
###############################################################################
changes=0

if [[ "$current_dmg_hash" != "$new_dmg_hash" ]]; then
  echo "  ✱ DMG hash changed"
  (( ++changes ))
fi
if [[ "$current_better_sqlite3_ver" != "$app_better_sqlite3_ver" ]]; then
  echo "  ✱ better-sqlite3 version changed: $current_better_sqlite3_ver → $app_better_sqlite3_ver"
  (( ++changes ))
fi
if [[ "$current_node_pty_ver" != "$app_node_pty_ver" ]]; then
  echo "  ✱ node-pty version changed: $current_node_pty_ver → $app_node_pty_ver"
  (( ++changes ))
fi

if (( changes == 0 )); then
  echo "==> No changes detected. package.nix is up to date."
  exit 0
fi

###############################################################################
# Step 5 — Prefetch new native module tarballs (if version bumped)
###############################################################################
if [[ "$current_better_sqlite3_ver" != "$app_better_sqlite3_ver" ]]; then
  echo "==> Prefetching better-sqlite3 $app_better_sqlite3_ver tarball …"
  bs3_url="$NPM_REGISTRY/better-sqlite3/-/better-sqlite3-${app_better_sqlite3_ver}.tgz"
  new_bs3_hash="$(nix store prefetch-file --json "$bs3_url" | jq -r '.hash')"
  echo "    Hash: $new_bs3_hash"
else
  new_bs3_hash=""
fi

if [[ "$current_node_pty_ver" != "$app_node_pty_ver" ]]; then
  echo "==> Prefetching node-pty $app_node_pty_ver tarball …"
  npty_url="$NPM_REGISTRY/node-pty/-/node-pty-${app_node_pty_ver}.tgz"
  new_npty_hash="$(nix store prefetch-file --json "$npty_url" | jq -r '.hash')"
  echo "    Hash: $new_npty_hash"
else
  new_npty_hash=""
fi

###############################################################################
# Step 6 — Apply updates to package.nix using sed
###############################################################################
echo "==> Updating package.nix …"
new_version="0-unstable-$(date +%Y-%m-%d)"

# --- DMG hash ---
sed -i "s|hash = \"${current_dmg_hash}\"|hash = \"${new_dmg_hash}\"|" "$PACKAGE_NIX"
echo "    ✓ DMG hash → $new_dmg_hash"

# --- version string ---
# Match the version line in stdenv.mkDerivation (not the module version lets)
sed -i "s|version = \"[^\"]*\";|version = \"${new_version}\";|" "$PACKAGE_NIX"
echo "    ✓ version → $new_version"

# --- better-sqlite3 version + hash ---
if [[ -n "$new_bs3_hash" ]]; then
  sed -i "s|betterSqlite3Version = \"[^\"]*\"|betterSqlite3Version = \"${app_better_sqlite3_ver}\"|" "$PACKAGE_NIX"

  # Update the hash inside the betterSqlite3Src fetchurl block.
  # We match the unique URL pattern to anchor the replacement.
  sed -i "/better-sqlite3-\${betterSqlite3Version}/,/};/{
    s|hash = \"sha256-[^\"]*\"|hash = \"${new_bs3_hash}\"|
  }" "$PACKAGE_NIX"
  echo "    ✓ betterSqlite3Version → $app_better_sqlite3_ver"
  echo "    ✓ betterSqlite3Src hash → $new_bs3_hash"
fi

# --- node-pty version + hash ---
if [[ -n "$new_npty_hash" ]]; then
  sed -i "s|nodePtyVersion = \"[^\"]*\"|nodePtyVersion = \"${app_node_pty_ver}\"|" "$PACKAGE_NIX"

  # Update the hash inside the nodePtySrc fetchurl block.
  sed -i "/node-pty-\${nodePtyVersion}/,/};/{
    s|hash = \"sha256-[^\"]*\"|hash = \"${new_npty_hash}\"|
  }" "$PACKAGE_NIX"
  echo "    ✓ nodePtyVersion → $app_node_pty_ver"
  echo "    ✓ nodePtySrc hash → $new_npty_hash"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "=== Update complete ==="
echo "  version:              $new_version"
echo "  DMG hash:             $current_dmg_hash → $new_dmg_hash"
if [[ -n "$new_bs3_hash" ]]; then
  echo "  better-sqlite3:       $current_better_sqlite3_ver → $app_better_sqlite3_ver"
fi
if [[ -n "$new_npty_hash" ]]; then
  echo "  node-pty:             $current_node_pty_ver → $app_node_pty_ver"
fi
