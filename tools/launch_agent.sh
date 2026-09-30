#!/bin/sh
# Start NERViewer at login, or stop doing so. Re-running install after a
# rebuild restarts it on the new build.
#   tools/launch_agent.sh install
#   tools/launch_agent.sh remove
# macOS: a LaunchAgent running dist/NERViewer.app.
# Linux: an XDG autostart entry (every XDG desktop honours one) that runs
#        `tools/launch_agent.sh start`. With a systemd user manager that
#        can reach the display, that starts the user unit
#        edu.pdx.josh.nerviewer.service, which the Yggdrasil System cockpit
#        also starts when it wants NERViewer; without one there is no unit,
#        start runs dist/linux/NERViewer.<arch> itself and the cockpit
#        launches the export directly.
# Run tools/build_app.sh first.
set -e
# -P: the physical path, as /proc/<pid>/exe reads it, so app_pids still
# finds a running copy when the checkout is reached through a symlink.
cd -P "$(dirname "$0")/.."
LABEL=edu.pdx.josh.nerviewer

case "$(uname)" in
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    APP="$(pwd)/dist/NERViewer.app/Contents/MacOS/NERViewer"
    # A checkout under R&D/ would otherwise be malformed XML.
    XML_APP=$(printf '%s' "$APP" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

    case "$1" in
      install)
        # The bare template of a failed export has no pck.
        if [ ! -x "$APP" ] || ! ls "$(pwd)"/dist/NERViewer.app/Contents/Resources/*.pck >/dev/null 2>&1; then
          echo "build the app first: tools/build_app.sh"; exit 1
        fi
        mkdir -p "$HOME/Library/LaunchAgents"
        cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$XML_APP</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST
        plutil -lint "$PLIST" >/dev/null
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
    CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
    UNIT_DIR="$CONFIG/systemd/user"
    UNIT="$UNIT_DIR/$LABEL.service"
    DESKTOP="$CONFIG/autostart/$LABEL.desktop"
    # build_app.sh's naming; dist/linux holds only this machine's export.
    case "$(uname -m)" in
      x86_64|amd64) ARCH=x86_64 ;;
      aarch64|arm64) ARCH=arm64 ;;
      *) echo "no Linux export for $(uname -m)"; exit 1 ;;
    esac
    APP="$(pwd)/dist/linux/NERViewer.$ARCH"
    SELF="$(pwd)/tools/launch_agent.sh"

    # A user manager that can open the display. The game runs on X11
    # (XWayland under Wayland), so DISPLAY. Plasma and GNOME import it at
    # every login; XFCE, i3, bare sway and non-systemd distros may not, and
    # a unit there fails to start, which the cockpit would wait on forever.
    has_manager() {
      command -v systemctl >/dev/null 2>&1 \
        && systemctl --user show-environment 2>/dev/null | grep -q '^DISPLAY='
    }
    # This checkout's export running, however started; after a rebuild the
    # file under it is gone and readlink says so.
    app_pids() {
      for p in /proc/[0-9]*; do
        case "$(readlink "$p/exe" 2>/dev/null)" in
          "$APP"|"$APP (deleted)") echo "${p#/proc/}" ;;
        esac
      done
    }
    # One fresh copy, like macOS's unload + load: the unit's and any
    # started directly are stopped first, so a reinstall never leaves the
    # old build running beside the new.
    stop_app() {
      [ -f "$UNIT" ] && systemctl --user stop "$LABEL.service" 2>/dev/null || true
      pids=$(app_pids)
      # shellcheck disable=SC2086 # one word per pid
      [ -z "$pids" ] || kill $pids 2>/dev/null || true
      i=0
      while [ -n "$(app_pids)" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
    }

    case "$1" in
      install)
        if [ ! -x "$APP" ] || [ ! -f dist/linux/NERViewer.pck ]; then
          echo "build the app first: tools/build_app.sh"; exit 1
        fi
        stop_app
        # An older install enabled the unit into graphical-session.target;
        # login start is the autostart entry's now, so two would run.
        if command -v systemctl >/dev/null 2>&1; then
          systemctl --user disable "$LABEL.service" >/dev/null 2>&1 || true
        fi

        # Desktop Entry quoting: \ " ` $ escaped inside the quotes, then
        # every backslash doubled as a string value, and % is a field code.
        ESC_SELF=$(printf '%s' "$SELF" | sed -e 's/[\\"`$]/\\&/g' -e 's/\\/\\\\/g' -e 's/%/%%/g')
        mkdir -p "$(dirname "$DESKTOP")"
        cat > "$DESKTOP" <<DESKTOP
[Desktop Entry]
Type=Application
Name=NERViewer
Comment=System stats HUD
Exec="$ESC_SELF" start
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOP

        if has_manager; then
          # systemd ExecStart: % is a specifier, and \ and " are escaped
          # (systemd refuses a path holding them; start then fails over
          # below). $ is literal in the executable path.
          ESC_APP=$(printf '%s' "$APP" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g')
          mkdir -p "$UNIT_DIR"
          # No [Install]: nothing enables it; the autostart entry and the
          # cockpit start it. No Restart=: like KeepAlive false on macOS,
          # quitting it (Q) means it stays quit. PartOf stops it with a
          # Plasma or GNOME session.
          cat > "$UNIT" <<UNIT
[Unit]
Description=NERViewer system stats
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart="$ESC_APP"
UNIT
          if systemctl --user daemon-reload && systemctl --user start "$LABEL.service"; then
            echo "installed and started: $LABEL.service, at login through $DESKTOP"
            exit 0
          fi
          # A unit that cannot start would strand the cockpit, which starts
          # it and waits; without it the cockpit runs the export itself.
          rm -f "$UNIT"
          systemctl --user daemon-reload 2>/dev/null || true
          echo "systemctl could not start $LABEL.service; unit removed"
        elif [ -f "$UNIT" ]; then
          rm -f "$UNIT"
          systemctl --user daemon-reload 2>/dev/null || true
        fi
        nohup "$APP" >/dev/null 2>&1 &
        echo "installed and started: NERViewer, at login through $DESKTOP"
        echo "no systemd user unit (no user manager with a DISPLAY); the cockpit runs the export itself"
        echo "i3, sway and other bare window managers skip XDG autostart: add \`exec \"$SELF\" start\` to their config"
        ;;
      start)
        # The autostart entry, at login: through the unit when there is one
        # so the cockpit and a reinstall see the same copy, else directly.
        if [ -f "$UNIT" ] && has_manager && systemctl --user start "$LABEL.service"; then
          exit 0
        fi
        [ -x "$APP" ] || { echo "no $APP: tools/build_app.sh"; exit 1; }
        [ -z "$(app_pids)" ] || exit 0
        exec "$APP"
        ;;
      remove)
        rm -f "$DESKTOP"
        # Every copy, as install does: one the entry started directly
        # has no unit to stop it.
        stop_app
        if [ -f "$UNIT" ]; then
          systemctl --user disable "$LABEL.service" 2>/dev/null || true
          rm -f "$UNIT"
          systemctl --user daemon-reload 2>/dev/null || true
        fi
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
