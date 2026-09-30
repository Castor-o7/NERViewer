#!/bin/sh
# Build yggstat into game/bin and smoke-test it with a single sample.
# macOS compiles the Swift helper; Linux installs the Python one (no
# extension, executable) so the game finds it at the same path.
set -e
cd "$(dirname "$0")"
mkdir -p ../game/bin
case "$(uname)" in
  Darwin)
    # Universal, with the app's own floors, so an Intel Mac or an older
    # macOS runs the helper too. Keep in step with export_presets.cfg.
    floor() {
      v=$(sed -n "s/^application\/min_macos_version_$1=\"\(.*\)\"/\1/p" ../game/export_presets.cfg | head -n 1)
      echo "${v:-$2}"
    }
    T=$(mktemp -d)
    trap 'rm -rf "$T"' EXIT
    for a in arm64 x86_64; do
      if [ "$a" = arm64 ]; then v=$(floor arm64 13.0); else v=$(floor x86_64 11.0); fi
      swiftc -O -target "$a-apple-macos$v" -o "$T/$a" main.swift \
        || { rm -f "$T/$a"; echo "yggstat: WARNING $a slice did not build" >&2; }
    done
    host=$(uname -m)
    if [ -f "$T/arm64" ] && [ -f "$T/x86_64" ]; then
      lipo -create -output ../game/bin/yggstat "$T/arm64" "$T/x86_64"
      lipo ../game/bin/yggstat -verify_arch arm64 x86_64
    elif [ -f "$T/$host" ]; then
      # One slice would not build (an SDK without it, say): the host's alone
      # beats nothing, but the app will not run the helper on the other.
      echo "yggstat: WARNING not universal; $host only" >&2
      cp "$T/$host" ../game/bin/yggstat
    else
      echo "yggstat: swiftc failed" >&2; exit 1
    fi
    ;;
  Linux)
    # The helper is a python3 script and the smoke test below needs it too.
    command -v python3 >/dev/null 2>&1 || { echo "yggstat: python3 not found; the Linux helper needs it" >&2; exit 1; }
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
