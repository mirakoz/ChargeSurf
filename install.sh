#!/bin/bash
# Installs or updates the ChargeSurf daemon (root LaunchDaemon).
# Usage: ./build.sh && sudo ./install.sh
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "Run with sudo: sudo ./install.sh"; exit 1; }
[ -x build/chargesurfd ] || { echo "Build first: ./build.sh"; exit 1; }

for app in AlDente batt; do
  if pgrep -xq "$app"; then
    echo "$app is running. Two charge tools fight over the same limit; quit it first."
    exit 1
  fi
done

echo "== checking macOS charge-limit support"
if ! out=$(build/chargesurfd status); then
  echo "$out"
  echo "This Mac/macOS is not supported (macOS 27+ with the PowerUI charge limit is required). Nothing was changed."
  exit 2
fi
echo "$out"

D="/Library/Application Support/ChargeSurf"
mkdir -p "$D"
install -m 755 -o root -g wheel build/chargesurfd "$D/chargesurfd"
[ -f "$D/config" ] || cp config.default "$D/config"
# Let the menu bar app (run by an admin user) change settings without a password prompt.
chown root:admin "$D/config" && chmod 664 "$D/config"
touch /Library/Logs/ChargeSurf.log && chmod 644 /Library/Logs/ChargeSurf.log

LABEL=io.github.mirakoz.chargesurf
install -m 644 -o root -g wheel launchd/$LABEL.plist /Library/LaunchDaemons/$LABEL.plist
launchctl bootout system/$LABEL 2>/dev/null || true
# bootout is asynchronous: wait for the old instance to go away, then load (with retries).
for i in $(seq 1 20); do launchctl print system/$LABEL >/dev/null 2>&1 || break; sleep 0.5; done
for i in 1 2 3 4 5; do
  launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist 2>/dev/null && break
  [ "$i" = 5 ] && { echo "ERROR: could not load the daemon"; exit 3; }
  sleep 1
done
sleep 3
echo "== installed"
"$D/chargesurfd" status
echo "Log: /Library/Logs/ChargeSurf.log   Menu bar app: ./install-app.sh (no sudo)"
