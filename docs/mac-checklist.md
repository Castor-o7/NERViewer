# Mac checklist

The Yggdrasil Suite (this repo and its sibling, NERViewer) was ported to Linux and tuned there on the `linux-tuneup` branch. Everything that runs only on a Mac was written with care but has never been compiled or run: this box has no `swiftc`. Walk this list on the MacBook before merging to `main`. The same file lives in both repos.

Paths are relative to the Grimoire folder that holds both repos.

## Build

1. `cd NERViewer/helper && sh build.sh`. It compiles `main.swift` and prints `yggstat ok: N cores, N values, inner <E> eff ...`. A compile error here is the first thing to fix.
2. `cd YggdrasilSystem && tools/build_app.sh` from a clean clone. Two checks:
   - the export-templates precheck explains itself when the templates are missing;
   - `GODOT=/path/to/Godot tools/build_app.sh` uses that path even with a `godot` on `PATH`.

## The core glyph on Apple Silicon (must be unchanged)

3. `NERViewer/game/bin/yggstat --once`. The `cpu` object is `{"cores":[...],"total":..,"perf":P,"eff":E}`, with **no** `inner`, `inner_kind` or `threads` keys. To be sure, build the helper from `main` too and compare: only the numbers may differ.
4. `sysctl hw.optional.arm64 hw.physicalcpu hw.logicalcpu hw.perflevel0.logicalcpu hw.perflevel1.logicalcpu`. Note the output beside this list.
5. `NERViewer/tools/build_app.sh`, then open `dist/NERViewer.app`. The core ring, the `P n  E n` caption, the per-core readouts and the hairlines look exactly as before. Screenshot it next to a build from `main`.
6. The LOAD dots grid is unchanged: on Apple Silicon the thread count is the core count.

## Docking (known broken on the Mac)

7. Run NERViewer from a terminal with the cockpit up. Expect `ERROR ... not a child` and **no** `docked to`. This confirms the known gap: `OS.is_process_running` only sees child processes, so the sigil never docks on a Mac. The planned fix is a `/bin/ps -ww -p <pid> -o command=` check, cached per pid or run off the main thread (see the comment on `_pid_alive` in `NERViewer/game/scenes/main.gd`). Build and test it here.

## Readings

8. `sysctl kern.memorystatus_level` at rest and under load. Compare with 100·(1 − (free + inactive + purgeable)/total) to judge how close the Linux memory-pressure reading now rests to the Mac's.

## Intel Mac (only if one is at hand)

9. Build there. `yggstat --once` shows `"inner_kind":"smt"`, `perf` = `hw.physicalcpu`, `2 × perf` values and `inner = perf`. Pin one single-threaded load (`yes > /dev/null`) and check that the busy outer slice and the busy inner slice belong to the same core: `main.swift` assumes logical CPUs `2k` and `2k+1` are one core's two threads. The rings are captioned `T1` / `T2`, and the LOAD grid reads the thread count.

## Optional

10. In NERViewer's synthetic mode, press **A** to step through all eight architectures, or run `tools/shots.tscn`, which writes `arch_<name>.png` for each.

## Known Mac gaps, not yet fixed

- **Docking**, above.
- **Terminal profile:** it can stay on Yggdrasil when zen ends with Terminal closed. Turning zen on launches Terminal, and zen-off resets every tab and the startup setting.
- **Logout:** logging out, or `launch_agent.sh remove`, sends SIGTERM, so zen is never handed back.
- **Network counter:** it wraps to a huge number when an interface disappears (Swift).
- **Per-app CPU:** it double-counts child apps and dips when a child exits (Swift).
- **Dev-run NERViewer:** a NERViewer run from the editor isn't recognised by the cockpit (Swift).
- **Universal helpers:** the Swift helpers aren't universal binaries (needs `lipo`).
- **1x screens:** the thick-line (`lift`) mode and the inscription oversampling are untested on a non-Retina display.
- **Multi-monitor:** the frames and title-bar cover are untested with more than one screen.
