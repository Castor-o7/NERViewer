#!/bin/sh
# Build yggstat into game/bin and smoke-test it with a single sample.
set -e
cd "$(dirname "$0")"
mkdir -p ../game/bin
# Without a target swiftc builds for this Mac's OS and newer only; the
# apps run on macOS 13 (the export preset's minimum), so the helpers must.
TARGET="-target arm64-apple-macos13.0"
swiftc -O $TARGET -o ../game/bin/yggstat main.swift
line=$(../game/bin/yggstat --once)
echo "$line" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["cpu"]["cores"])==d["cpu"]["perf"]+d["cpu"]["eff"]; print("yggstat ok:", len(d["cpu"]["cores"]), "cores, total", d["cpu"]["total"], "rx_bps", d["net"]["rx_bps"])'
