#!/bin/bash
# Installs the menu bar app to /Applications and starts it at login. No sudo needed
# on an admin account. macOS shows the app's icon on notifications only for apps in
# /Applications, so ~/Applications is used only when /Applications is not writable.
set -euo pipefail
cd "$(dirname "$0")"
[ -d build/ChargeSurf.app ] || ./build.sh
if [ -w /Applications ]; then DEST=/Applications; else DEST="$HOME/Applications"; fi
APP="$DEST/ChargeSurf.app"
mkdir -p "$DEST" ~/Library/LaunchAgents
pkill -x ChargeSurf 2>/dev/null || true
# 0.1.0 and early 0.2.0 builds installed to ~/Applications: remove that copy.
[ "$DEST" = /Applications ] && rm -rf "$HOME/Applications/ChargeSurf.app"
rm -rf "$APP"
cp -R build/ChargeSurf.app "$DEST/"
xattr -cr "$APP"
codesign --force -s - "$APP"
LABEL=io.github.mirakoz.chargesurf.ui
PL=~/Library/LaunchAgents/$LABEL.plist
cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ChargeSurf</string></array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for i in $(seq 1 20); do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 0.3; done
launchctl bootstrap "gui/$(id -u)" "$PL"
echo "ChargeSurf is in your menu bar (installed to $DEST)."
[ "$DEST" = /Applications ] || echo "note: /Applications is not writable, so notifications will show a blank icon."
