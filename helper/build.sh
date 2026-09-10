#!/bin/sh
# Build yggstat into game/bin and smoke-test it with a single sample.
set -e
cd "$(dirname "$0")"
mkdir -p ../game/bin
swiftc -O -o ../game/bin/yggstat main.swift
line=$(../game/bin/yggstat --once)
echo "$line" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["cpu"]["cores"])==d["cpu"]["perf"]+d["cpu"]["eff"]; print("yggstat ok:", len(d["cpu"]["cores"]), "cores, total", d["cpu"]["total"], "rx_bps", d["net"]["rx_bps"])'
