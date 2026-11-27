#!/bin/bash
# Rebuilds resources/ChargeSurf.icns and docs/images/icon.png from generate-icon.swift.
# Needs only the Command Line Tools (swift, sips, iconutil).
set -euo pipefail
cd "$(dirname "$0")/../.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swift docs/icon/generate-icon.swift "$T" >/dev/null
SET="$T/ChargeSurf.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$T/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o resources/ChargeSurf.icns
sips -z 256 256 "$T/icon-1024.png" --out docs/images/icon.png >/dev/null
echo "wrote resources/ChargeSurf.icns docs/images/icon.png"
