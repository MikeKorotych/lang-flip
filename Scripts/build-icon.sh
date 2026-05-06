#!/usr/bin/env bash
# Generate the macOS iconset and AppIcon.icns from a single 1024x1024 master
# PNG (Resources/lang-flip-logo.png by default). Re-run after changing the
# master to refresh the icon.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MASTER="${1:-$ROOT_DIR/Resources/lang-flip-logo.png}"
ICONSET="$ROOT_DIR/Resources/AppIcon.iconset"
ICNS="$ROOT_DIR/Resources/AppIcon.icns"

if [[ ! -f "$MASTER" ]]; then
  echo "Master PNG not found: $MASTER" >&2
  exit 1
fi

# Verify the master is at least 1024x1024 — Apple's largest required size.
DIMS=$(sips -g pixelWidth -g pixelHeight "$MASTER" | awk '/pixel(Width|Height)/ { print $2 }' | tr '\n' 'x' | sed 's/x$//')
if [[ "$DIMS" != "1024x1024" ]]; then
  echo "Master must be exactly 1024x1024 (got $DIMS): $MASTER" >&2
  exit 1
fi

echo "→ Generating iconset from $(basename "$MASTER")…"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# macOS-required sizes: 16, 32, 64, 128, 256, 512, 1024 with @2x retina pairs.
declare -a TARGETS=(
  "16    icon_16x16.png"
  "32    icon_16x16@2x.png"
  "32    icon_32x32.png"
  "64    icon_32x32@2x.png"
  "128   icon_128x128.png"
  "256   icon_128x128@2x.png"
  "256   icon_256x256.png"
  "512   icon_256x256@2x.png"
  "512   icon_512x512.png"
  "1024  icon_512x512@2x.png"
)

for entry in "${TARGETS[@]}"; do
  size=$(echo "$entry" | awk '{print $1}')
  name=$(echo "$entry" | awk '{print $2}')
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
done

echo "→ Compiling AppIcon.icns…"
iconutil --convert icns "$ICONSET" --output "$ICNS"

echo "✓ Wrote $ICONSET (10 PNGs) and $ICNS"
