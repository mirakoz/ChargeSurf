#!/bin/bash
# Builds the daemon, the SMC probe tool and the menu bar app into ./build
# Requires Xcode Command Line Tools (clang, swiftc). Apple Silicon only.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

echo "== chargesurfd"
clang -O2 -Wall -Wextra -fno-objc-arc -framework Foundation -framework IOKit \
  src/smc.c src/chargesurfd.m -o build/chargesurfd

echo "== smc-probe"
clang -O2 -Wall -framework IOKit src/smc.c tools/smc-probe.c -o build/smc-probe

echo "== ChargeSurf.app"
APP=build/ChargeSurf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macos15 src/ChargeSurfApp.swift -o "$APP/Contents/MacOS/ChargeSurf"
cp -R resources/*.lproj "$APP/Contents/Resources/"
cp resources/ChargeSurf.icns "$APP/Contents/Resources/"   # rebuilt by docs/icon/make-icon.sh
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.mirakoz.ChargeSurf</string>
  <key>CFBundleName</key><string>ChargeSurf</string>
  <key>CFBundleDisplayName</key><string>ChargeSurf</string>
  <key>CFBundleExecutable</key><string>ChargeSurf</string>
  <key>CFBundleIconFile</key><string>ChargeSurf</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Ad-hoc sign. Folders synced by iCloud (e.g. ~/Documents) keep re-adding extended
# attributes that codesign rejects; install-app.sh signs again after copying out of them.
xattr -cr "$APP"
codesign --force -s - "$APP" 2>/dev/null || echo "note: could not sign in this folder (iCloud?); install-app.sh will sign the installed copy"
echo "built: build/chargesurfd build/smc-probe $APP"
