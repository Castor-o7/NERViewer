#!/bin/sh
# Build the self-contained app with the yggstat helper beside it.
#   macOS: dist/NERViewer.app. Needs Godot 4.7.2 export templates (Editor >
#          Manage Export Templates) and the Xcode command line tools for
#          swiftc and codesign.
#   Linux: dist/linux/NERViewer.x86_64, its NERViewer.pck, and dist/linux/yggstat.
#          Needs the Godot 4.7.2 Linux export templates and python3.
set -e
cd "$(dirname "$0")/.."

case "$(uname)" in
  Darwin)
    GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
    command -v godot >/dev/null 2>&1 && GODOT=godot

    echo "-- helper"
    helper/build.sh

    echo "-- export"
    rm -rf dist/NERViewer.app
    mkdir -p dist
    "$GODOT" --path game --headless --export-release "macOS" ../dist/NERViewer.app

    echo "-- bundle helper"
    cp game/bin/yggstat dist/NERViewer.app/Contents/MacOS/yggstat
    # Adding a binary invalidates the ad-hoc signature; sign again.
    codesign --force --deep --sign - dist/NERViewer.app

    echo "-- done: dist/NERViewer.app"
    ;;
  Linux)
    GODOT=${GODOT:-godot}
    # The editor finds its templates here; say so plainly rather than let
    # the export die with a terse "template not found".
    TPL="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates"
    VER=$("$GODOT" --version | sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?)\.([a-z0-9]+)\..*/\1.\3/')
    if [ ! -f "$TPL/$VER/linux_release.x86_64" ]; then
      echo "no Linux export template at $TPL/$VER/linux_release.x86_64"
      echo "install the $VER templates (Godot: Editor > Manage Export Templates)"
      exit 1
    fi

    echo "-- helper"
    helper/build.sh

    echo "-- export"
    rm -rf dist/linux
    mkdir -p dist/linux
    # A failed export can still leave the bare template behind; drop it so
    # launch_agent.sh never installs a binary with no game in it.
    if ! "$GODOT" --path game --headless --export-release "Linux" ../dist/linux/NERViewer.x86_64 \
        || [ ! -x dist/linux/NERViewer.x86_64 ] || [ ! -f dist/linux/NERViewer.pck ]; then
      rm -f dist/linux/NERViewer.x86_64 dist/linux/NERViewer.pck
      echo "export failed: no dist/linux/NERViewer.x86_64"
      exit 1
    fi

    echo "-- helper beside the executable"
    # HelperStatSource looks beside the executable first.
    cp game/bin/yggstat dist/linux/yggstat
    chmod +x dist/linux/yggstat

    echo "-- done: dist/linux/NERViewer.x86_64"
    ;;
  *)
    echo "no build for $(uname)"; exit 1
    ;;
esac
