#!/bin/sh
# Start NERViewer at login, or stop doing so.
#   tools/launch_agent.sh install
#   tools/launch_agent.sh remove
# Uses /Applications/NERViewer.app if tools/install.sh put it there, else
# dist/NERViewer.app; run tools/build_app.sh first.
set -e
cd "$(dirname "$0")/.."
LABEL=edu.pdx.josh.nerviewer
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BUNDLE="/Applications/NERViewer.app"
[ -d "$BUNDLE" ] || BUNDLE="$(pwd)/dist/NERViewer.app"
APP="$BUNDLE/Contents/MacOS/NERViewer"

case "$1" in
  install)
    [ -x "$APP" ] || { echo "build the app first: tools/build_app.sh"; exit 1; }
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "installed: NERViewer will start at login ($PLIST)"
    ;;
  remove)
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed"
    ;;
  *)
    echo "usage: $0 install|remove"; exit 2
    ;;
esac
