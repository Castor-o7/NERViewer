#!/bin/sh
# Build dist/NERViewer.app: a self-contained app with the yggstat helper
# inside it. Needs Godot 4.7.2 export templates (Editor > Manage Export
# Templates) and the Xcode command line tools for swiftc and codesign.
set -e
cd "$(dirname "$0")/.."
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

echo "-- Apple Silicon only"
# The official export templates are universal; dropping the Intel half
# halves the app. (An arm64 preset would need a custom template.)
EXE="dist/NERViewer.app/Contents/MacOS/NERViewer"
lipo "$EXE" -thin arm64 -output "$EXE.arm64" && mv "$EXE.arm64" "$EXE"
# Adding a binary invalidates the ad-hoc signature; sign again.
codesign --force --deep --sign - dist/NERViewer.app

echo "-- done: dist/NERViewer.app"
