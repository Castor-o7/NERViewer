#!/bin/sh
# Start NERViewer at login, or stop doing so.
#   tools/launch_agent.sh install
#   tools/launch_agent.sh remove
# macOS: a LaunchAgent running dist/NERViewer.app.
# Linux: a systemd user unit running dist/linux/NERViewer.x86_64, tied to
#        the graphical session so it starts with the desktop and stops with
#        it. The Yggdrasil System cockpit starts this unit when it wants
#        NERViewer and the unit exists.
# Run tools/build_app.sh first.
set -e
cd "$(dirname "$0")/.."
LABEL=edu.pdx.josh.nerviewer

case "$(uname)" in
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    APP="$(pwd)/dist/NERViewer.app/Contents/MacOS/NERViewer"

    case "$1" in
      install)
        [ -x "$APP" ] || { echo "build the app first: tools/build_app.sh"; exit 1; }
        mkdir -p "$HOME/Library/LaunchAgents"
        cat > "$PLIST" <<PLIST
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
PLIST
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
    ;;
  Linux)
    UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    UNIT="$UNIT_DIR/$LABEL.service"
    APP="$(pwd)/dist/linux/NERViewer.x86_64"

    case "$1" in
      install)
        [ -x "$APP" ] || { echo "build the app first: tools/build_app.sh"; exit 1; }
        mkdir -p "$UNIT_DIR"
        # No Restart=: like KeepAlive false on macOS, quitting it (Q) means
        # it stays quit. The display comes from the session environment
        # that Plasma imports into the systemd user manager.
        cat > "$UNIT" <<UNIT
[Unit]
Description=NERViewer system stats
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart="$APP"

[Install]
WantedBy=graphical-session.target
UNIT
        systemctl --user daemon-reload
        systemctl --user enable --now "$LABEL.service"
        echo "installed and started: NERViewer will start with the desktop ($UNIT)"
        ;;
      remove)
        systemctl --user disable --now "$LABEL.service" 2>/dev/null || true
        rm -f "$UNIT"
        systemctl --user daemon-reload
        echo "removed"
        ;;
      *)
        echo "usage: $0 install|remove"; exit 2
        ;;
    esac
    ;;
  *)
    echo "no login item for $(uname)"; exit 1
    ;;
esac
