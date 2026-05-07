#!/usr/bin/env bash
# Wrapper around Sparkle's sign_update tool. Given a release DMG, prints the
# `sparkle:edSignature="…"` and `length="…"` attributes to paste into
# docs/appcast.xml's <enclosure>.
#
# Usage: ./Scripts/sign-update.sh build/LangFlip-X.Y.Z.dmg

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path-to-dmg>" >&2
  exit 2
fi

DMG="$1"
if [[ ! -f "$DMG" ]]; then
  echo "✗ File not found: $DMG" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIGN_UPDATE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"

if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "✗ sign_update not found at $SIGN_UPDATE" >&2
  echo "  Run \`swift build\` first to download the Sparkle binary artifact." >&2
  exit 1
fi

echo "→ Signing $DMG with the EdDSA private key from your login.keychain…"
echo
"$SIGN_UPDATE" "$DMG"
echo
echo "Append the printed sparkle:edSignature and length to a new <item>"
echo "block in docs/appcast.xml (newest entries first)."
