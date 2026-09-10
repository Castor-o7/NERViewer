#!/bin/sh
# Build dist/NERViewer.app: a self-contained app with the yggstat helper
# inside it. Needs Godot 4.3 export templates (Editor > Manage Export
# Templates) and the Xcode command line tools for swiftc and codesign.
set -e
cd "$(dirname "$0")/.."
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
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
