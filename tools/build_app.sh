#!/bin/sh
# Build the self-contained app with the yggstat helper beside it.
#   macOS: dist/NERViewer.app. Needs Godot 4.7.2 export templates (Editor >
#          Manage Export Templates) and the Xcode command line tools for
#          swiftc and codesign.
#   Linux: dist/linux/NERViewer.<arch> (x86_64 or arm64, from uname -m),
#          its NERViewer.pck, and dist/linux/yggstat. NERVIEWER_ARCH=<other>
#          cross-exports to dist/linux-<other> and leaves dist/linux alone.
#          Needs the Godot 4.7.2 Linux export templates and python3.
# Godot is GODOT=..., else godot or godot4 on PATH, else Godot.app on
# macOS or the Flathub org.godotengine.Godot on Linux.
set -e
cd "$(dirname "$0")/.."

FLATPAK=
if [ -n "$GODOT" ]; then
  command -v "$GODOT" >/dev/null 2>&1 || { echo "GODOT=$GODOT is not runnable"; exit 1; }
elif command -v godot >/dev/null 2>&1; then
  GODOT=godot
elif command -v godot4 >/dev/null 2>&1; then
  GODOT=godot4
elif [ "$(uname)" = Darwin ]; then
  GODOT=/Applications/Godot.app/Contents/MacOS/Godot
elif command -v flatpak >/dev/null 2>&1 && flatpak info org.godotengine.Godot >/dev/null 2>&1; then
  FLATPAK=1
else
  echo "no Godot found: set GODOT=/path/to/godot (e.g. Godot_v4.7.2-stable_linux.x86_64)"
  exit 1
fi

gd() {
  if [ -n "$FLATPAK" ]; then
    # The sandbox may not see the checkout otherwise.
    flatpak run --filesystem="$PWD" org.godotengine.Godot "$@"
  else
    "$GODOT" "$@"
  fi
}

# Templates live under the full version: 4.7.2.stable.arch_linux.x reads
# 4.7.2.stable, and the .NET editor's 4.7.2.stable.mono.official.x reads
# 4.7.2.stable.mono. A pipeline hides a missing godot from set -e, hence
# the separate steps.
RAW=$(gd --version) || { echo "${GODOT:-flatpak Godot} --version failed"; exit 1; }
VER=$(printf '%s\n' "$RAW" | sed -nE 's/^([0-9]+\.[0-9]+(\.[0-9]+)?\.[a-z]+[0-9]*)\..*/\1/p' | tail -n 1)
[ -n "$VER" ] || { echo "could not read the Godot version from: $RAW"; exit 1; }
case "$RAW" in *.mono.*) VER="$VER.mono" ;; esac

# The one dir this Godot reads templates from: editor_data/ beside a
# self-contained (_sc_) editor, found through symlinks as Godot finds
# itself; on macOS beside the .app. Otherwise the platform's data dir,
# which for the Flatpak is its own. Say so plainly rather than let the
# export die with a terse "template not found".
template() {
  if [ -n "$FLATPAK" ]; then
    d="$HOME/.var/app/org.godotengine.Godot/data/godot/export_templates"
  else
    bin=$(command -v "$GODOT")
    bin=$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")
    dir=$(dirname "$bin")
    case "$dir" in */Contents/MacOS) dir=$(dirname "$(dirname "$(dirname "$dir")")") ;; esac
    if [ -f "$dir/_sc_" ] || [ -f "$dir/._sc_" ]; then
      d="$dir/editor_data/export_templates"
    else
      case "$(basename "$bin")" in
        org.godotengine.Godot) d="$HOME/.var/app/org.godotengine.Godot/data/godot/export_templates" ;;
        *) d=$1 ;;
      esac
    fi
  fi
  [ ! -f "$d/$VER/$TEMPLATE" ] || return 0
  echo "no export template $d/$VER/$TEMPLATE"
  echo "install the $VER templates (Godot: Editor > Manage Export Templates)"
  exit 1
}

case "$(uname)" in
  Darwin)
    TEMPLATE=macos.zip
    template "$HOME/Library/Application Support/Godot/export_templates"

    echo "-- helper"
    helper/build.sh

    echo "-- export"
    rm -rf dist/NERViewer.app
    mkdir -p dist
    # As on Linux: a failed export can leave the bare template .app, which
    # launch_agent.sh would install as a game with no data.
    if ! gd --path game --headless --export-release "macOS" ../dist/NERViewer.app \
        || [ ! -x dist/NERViewer.app/Contents/MacOS/NERViewer ] \
        || ! ls dist/NERViewer.app/Contents/Resources/*.pck >/dev/null 2>&1; then
      rm -rf dist/NERViewer.app
      echo "export failed: no dist/NERViewer.app"
      exit 1
    fi

    echo "-- bundle helper"
    cp game/bin/yggstat dist/NERViewer.app/Contents/MacOS/yggstat
    # Adding a binary invalidates the ad-hoc signature; sign again.
    codesign --force --deep --sign - dist/NERViewer.app

    echo "-- done: dist/NERViewer.app"
    ;;
  Linux)
    # The preset fixes the architecture (the command line cannot), so one
    # preset per arch. Not plain ARCH: kernel cross-build shells export it.
    arch_of() {
      case "$1" in
        x86_64|amd64) echo x86_64 ;;
        aarch64|arm64) echo arm64 ;;
      esac
    }
    HOST=$(arch_of "$(uname -m)")
    ARCH=$(arch_of "${NERVIEWER_ARCH:-$(uname -m)}")
    case "$ARCH" in
      x86_64) PRESET="Linux" ;;
      arm64) PRESET="Linux arm64" ;;
      *) echo "no Linux export for ${NERVIEWER_ARCH:-$(uname -m)}"; exit 1 ;;
    esac
    # dist/linux is this machine's: the unit, the autostart entry and the
    # cockpit run it. A cross-export goes beside it, pck and all (the
    # presets pack different texture formats).
    OUT=dist/linux
    [ "$ARCH" = "$HOST" ] || OUT=dist/linux-$ARCH
    TEMPLATE=linux_release.$ARCH
    template "${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates"
    EXE=$OUT/NERViewer.$ARCH

    echo "-- helper"
    helper/build.sh

    echo "-- export ($PRESET)"
    rm -rf "$OUT"
    mkdir -p "$OUT"
    # A failed export can still leave the bare template behind; drop it so
    # launch_agent.sh never installs a binary with no game in it.
    if ! gd --path game --headless --export-release "$PRESET" "../$EXE" \
        || [ ! -x "$EXE" ] || [ ! -f "$OUT/NERViewer.pck" ]; then
      rm -f "$EXE" "$OUT/NERViewer.pck"
      echo "export failed: no $EXE"
      exit 1
    fi

    echo "-- helper beside the executable"
    # HelperStatSource looks beside the executable first.
    cp game/bin/yggstat "$OUT/yggstat"
    chmod +x "$OUT/yggstat"

    echo "-- done: $EXE"
    ;;
  *)
    echo "no build for $(uname)"; exit 1
    ;;
esac
