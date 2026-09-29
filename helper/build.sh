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
# The core contract (yggstat.py header): perf + eff physical cores, one
# value each, plus one more per core on the inner ring when it shows SMT
# threads. macOS on Apple Silicon sends no inner_kind: one value per core.
echo "$line" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = d["cpu"]
kind = c.get("inner_kind", "eff" if c["eff"] > 0 else "none")
inner = c.get("inner", c["eff"])
assert kind in ("eff", "cluster", "smt", "none"), kind
assert len(c["cores"]) == c["perf"] + c["eff"] + (inner if kind == "smt" else 0), c
assert 0 <= inner <= len(c["cores"]), c
assert (inner == c["eff"]) if kind == "eff" else (c["eff"] == 0), c
assert (inner == 0) == (kind == "none"), c
assert c.get("threads", len(c["cores"])) >= c["perf"] + c["eff"], c
print("yggstat ok:", c["perf"] + c["eff"], "cores,", len(c["cores"]), "values, inner", inner, kind, "total", c["total"], "rx_bps", d["net"]["rx_bps"])'
