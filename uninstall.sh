#!/bin/bash
# Removes ChargeSurf completely and releases the macOS charge limit.
# Usage: sudo ./uninstall.sh   (the log file is kept)
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "Run with sudo: sudo ./uninstall.sh"; exit 1; }
D="/Library/Application Support/ChargeSurf"
LABEL=io.github.mirakoz.chargesurf
launchctl bootout system/$LABEL 2>/dev/null
[ -x "$D/chargesurfd" ] && "$D/chargesurfd" reset
rm -f /Library/LaunchDaemons/$LABEL.plist
rm -rf "$D"
pkill -x ChargeSurf 2>/dev/null
rm -rf /Applications/ChargeSurf.app
if [ -n "${SUDO_USER:-}" ]; then
  U=$(id -u "$SUDO_USER")
  H=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')
  launchctl bootout "gui/$U/$LABEL.ui" 2>/dev/null
  rm -f "$H/Library/LaunchAgents/$LABEL.ui.plist"
  rm -rf "$H/Applications/ChargeSurf.app"
fi
echo "ChargeSurf removed (log kept at /Library/Logs/ChargeSurf.log)"
