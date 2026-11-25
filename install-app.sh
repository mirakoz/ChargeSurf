#!/bin/bash
# Installs the menu bar app to ~/Applications and starts it at login. No sudo needed.
set -euo pipefail
cd "$(dirname "$0")"
[ -d build/ChargeSurf.app ] || ./build.sh
mkdir -p ~/Applications ~/Library/LaunchAgents
pkill -x ChargeSurf 2>/dev/null || true
rm -rf ~/Applications/ChargeSurf.app
cp -R build/ChargeSurf.app ~/Applications/
xattr -cr ~/Applications/ChargeSurf.app
codesign --force -s - ~/Applications/ChargeSurf.app
LABEL=io.github.mirakoz.chargesurf.ui
PL=~/Library/LaunchAgents/$LABEL.plist
cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/ChargeSurf.app/Contents/MacOS/ChargeSurf</string></array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for i in $(seq 1 20); do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 0.3; done
launchctl bootstrap "gui/$(id -u)" "$PL"
echo "ChargeSurf is in your menu bar."
