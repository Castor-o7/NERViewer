#!/bin/sh
# Install NERViewer: copy dist/NERViewer.app into /Applications, where it
# no longer needs this repo around it, and if it starts at login, point
# the LaunchAgent at the installed copy.
#   tools/install.sh          copy (and re-point an existing agent)
#   tools/install.sh --login  copy and start at login
# Quit the app first; run tools/build_app.sh first.
set -e
cd "$(dirname "$0")/.."
SRC=dist/NERViewer.app
DST=/Applications/NERViewer.app
PLIST="$HOME/Library/LaunchAgents/edu.pdx.josh.nerviewer.plist"

[ -d "$SRC" ] || { echo "build the app first: tools/build_app.sh"; exit 1; }
if pgrep -f "$DST/Contents/MacOS/" >/dev/null 2>&1; then
  echo "quit the running NERViewer first"; exit 1
fi
rm -rf "$DST"
ditto "$SRC" "$DST"
echo "installed: $DST"
if [ "$1" = "--login" ] || [ -f "$PLIST" ]; then
  tools/launch_agent.sh install
fi
