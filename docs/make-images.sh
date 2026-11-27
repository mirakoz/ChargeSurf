#!/bin/bash
# Regenerates the README images in docs/images.
# Renders the app's panels with fixed sample values (--preview ... --demo), then composes them.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -x build/ChargeSurf.app/Contents/MacOS/ChargeSurf ] || ./build.sh
APP=build/ChargeSurf.app/Contents/MacOS/ChargeSurf
SHOTS=$(mktemp -d)
trap 'rm -rf "${SHOTS:?}"' EXIT
LOC="-AppleLanguages (en) -AppleLocale en_US"   # English text, decimal points
for theme in light dark; do
  flag=""; [ "$theme" = dark ] && flag=--dark
  for demo in sailing charging heat battery; do
    "$APP" --preview "$SHOTS/main-$demo-$theme.png" --page main --demo "$demo" $flag $LOC
    "$APP" --preview "$SHOTS/menubar-$demo-$theme.png" --page menubar --demo "$demo" $flag $LOC
  done
  "$APP" --preview "$SHOTS/power-$theme.png" --page power --demo sailing $flag $LOC
  "$APP" --preview "$SHOTS/devices-$theme.png" --page devices --demo sailing $flag $LOC
  "$APP" --preview "$SHOTS/settings-$theme.png" --page settings --demo sailing $flag $LOC
  "$APP" --preview "$SHOTS/onboarding-$theme.png" --page onboarding --demo sailing $flag $LOC
done
python3 docs/make_images.py "$SHOTS" docs/images
