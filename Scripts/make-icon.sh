#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from Resources/AppIcon.svg.
#
# Run this after editing the SVG and commit both files. The build itself only
# copies the committed .icns, so building the app needs no extra tools.
#
# Needs: uv (renders the SVG with resvg in a throwaway environment) and
# iconutil (ships with macOS).

set -euo pipefail
cd "$(dirname "$0")/.."

SVG="Resources/AppIcon.svg"
ICNS="Resources/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# Every size macOS asks for in an .icns: base name and pixel width.
uv run --quiet --no-project --with resvg-py==0.5.0 python - "$SVG" "$ICONSET" <<'PY'
import sys
import resvg_py

svg_path, iconset = sys.argv[1], sys.argv[2]
sizes = {
    "icon_16x16": 16, "icon_16x16@2x": 32,
    "icon_32x32": 32, "icon_32x32@2x": 64,
    "icon_128x128": 128, "icon_128x128@2x": 256,
    "icon_256x256": 256, "icon_256x256@2x": 512,
    "icon_512x512": 512, "icon_512x512@2x": 1024,
}
for name, px in sizes.items():
    png = resvg_py.svg_to_bytes(svg_path=svg_path, width=px, height=px)
    with open(f"{iconset}/{name}.png", "wb") as f:
        f.write(bytes(png))
PY

iconutil --convert icns --output "$ICNS" "$ICONSET"
echo "==> wrote $ICNS"
