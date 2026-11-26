#!/bin/bash
# Regenerates the README images in docs/images.
# Renders the app's panels with fixed sample values (--preview ... --demo), then composes them.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -x build/ChargeSurf.app/Contents/MacOS/ChargeSurf ] || ./build.sh
APP=build/ChargeSurf.app/Contents/MacOS/ChargeSurf
SHOTS=$(mktemp -d)
trap 'rm -rf "${SHOTS:?}"' EXIT
for theme in light dark; do
  flag=""; [ "$theme" = dark ] && flag=--dark
  for demo in sailing charging heat battery; do
    "$APP" --preview "$SHOTS/main-$demo-$theme.png" --page main --demo "$demo" $flag -AppleLanguages '(en)'
    "$APP" --preview "$SHOTS/menubar-$demo-$theme.png" --page menubar --demo "$demo" $flag -AppleLanguages '(en)'
  done
  "$APP" --preview "$SHOTS/settings-$theme.png" --page settings --demo sailing $flag -AppleLanguages '(en)'
  "$APP" --preview "$SHOTS/onboarding-$theme.png" --page onboarding --demo sailing $flag -AppleLanguages '(en)'
done
python3 docs/make_images.py "$SHOTS" docs/images
