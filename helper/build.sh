#!/bin/sh
# Build yggstat into game/bin and smoke-test it with a single sample.
# macOS compiles the Swift helper; Linux installs the Python one (no
# extension, executable) so the game finds it at the same path.
set -e
cd "$(dirname "$0")"
mkdir -p ../game/bin
case "$(uname)" in
  Darwin)
    swiftc -O -o ../game/bin/yggstat main.swift
    ;;
  Linux)
    cp yggstat.py ../game/bin/yggstat
    chmod +x ../game/bin/yggstat
    ;;
  *)
    echo "yggstat: no helper for $(uname)"; exit 1
    ;;
esac
line=$(../game/bin/yggstat --once)
echo "$line" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["cpu"]["cores"])==d["cpu"]["perf"]+d["cpu"]["eff"]; print("yggstat ok:", len(d["cpu"]["cores"]), "cores, total", d["cpu"]["total"], "rx_bps", d["net"]["rx_bps"])'
