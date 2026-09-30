# Mac checklist

The Yggdrasil Suite (this repo and its sibling, NERViewer) was ported to Linux and tuned there on the `linux-tuneup` branch. Everything that runs only on a Mac was written with care but has never been compiled or run: this box has no `swiftc`. Walk this list on the MacBook before merging to `main`. The same file lives in both repos.

Paths are relative to the Grimoire folder that holds both repos.

## Build

1. `cd NERViewer/helper && sh build.sh`. It compiles `main.swift` twice, for arm64 and x86_64 at the export presets' minimum macOS versions, joins them with `lipo`, and prints `yggstat ok: N cores, N values, inner <E> eff ...`. A compile error here is the first thing to fix: `main.swift` gained per-interface network rates and a monotonic clock (2026-09-29) that have never been compiled. Then `lipo -info ../game/bin/yggstat` names both architectures; a `WARNING ... slice did not build` line means only the host's was made.
2. `cd YggdrasilSystem && tools/build_app.sh` from a clean clone. Two checks:
   - the export-templates precheck explains itself when the templates are missing;
   - `GODOT=/path/to/Godot tools/build_app.sh` uses that path even with a `godot` on `PATH`.
   - `NERViewer/tools/build_app.sh` with no `godot` on `PATH` but a `godot4`, or only `/Applications/Godot.app`, still finds it.
   - `NERViewer/tools/launch_agent.sh install` from a checkout whose path holds a `&` (or a space) writes a plist that `plutil -lint` accepts.

## The core glyph on Apple Silicon (must be unchanged)

3. `NERViewer/game/bin/yggstat --once`. The `cpu` object is `{"cores":[...],"total":..,"perf":P,"eff":E}`, with **no** `inner`, `inner_kind` or `threads` keys. To be sure, build the helper from `main` too and compare: only the numbers may differ.
4. `sysctl hw.optional.arm64 hw.physicalcpu hw.logicalcpu hw.perflevel0.logicalcpu hw.perflevel1.logicalcpu`. Note the output beside this list.
5. `NERViewer/tools/build_app.sh`, then open `dist/NERViewer.app`. The core ring, the `P n  E n` caption, the per-core readouts and the hairlines look exactly as before. Screenshot it next to a build from `main`.
6. The LOAD dots grid is unchanged: on Apple Silicon the thread count is the core count.

## Docking (fixed, never run on a Mac)

7. `_pid_alive` in `NERViewer/game/scenes/main.gd` now asks `/bin/ps -ww -p <pid> -o command=` on macOS, cached for 2 s. Run NERViewer from a terminal with the cockpit up:
   - it prints `docked to` and the sigil sits in the cockpit; no `not a child` error;
   - `kill -9` the cockpit: NERViewer undocks within about 2 s;
   - watch for a hitch twice a second while docked. If `ps` shows up as a stutter, the comment there says how to move it off the main thread.

## Readings

- **No signal:** with NERViewer up, `pkill -STOP yggstat`. Within about 3 s the core ring says NO SIGNAL (docked too) and the panels dim; the helper is replaced and the readings come back on their own. `pkill yggstat` does the same through the exit path. Nothing should ever show made-up numbers: synthetic data is only `-- --synthetic` or `-- --arch=`.
- **Network:** start a download, then connect and disconnect a VPN, and unplug or switch off an adapter. The rate never jumps to an absurd figure, and a download through the VPN reads once, not twice. Wi-Fi must still count (it should report as Ethernet, `IFT_ETHER`).

8. `sysctl kern.memorystatus_level` at rest and under load. Compare with 100·(1 − (free + inactive + purgeable)/total) to judge how close the Linux memory-pressure reading now rests to the Mac's.

## Intel Mac (only if one is at hand)

9. Build there. `yggstat --once` shows `"inner_kind":"smt"`, `perf` = `hw.physicalcpu`, `2 × perf` values and `inner = perf`. Pin one single-threaded load (`yes > /dev/null`) and check that the busy outer slice and the busy inner slice belong to the same core: `main.swift` assumes logical CPUs `2k` and `2k+1` are one core's two threads. The rings are captioned `T1` / `T2`, and the LOAD grid reads the thread count.

## Optional

10. In NERViewer's synthetic mode, press **A** to step through all eight architectures, or run `tools/shots.tscn`, which writes `arch_<name>.png` for each.

## Known Mac gaps, not yet fixed

- **Docking**, above.
- **Terminal profile:** it can stay on Yggdrasil when zen ends with Terminal closed. Turning zen on launches Terminal, and zen-off resets every tab and the startup setting.
- **Logout:** logging out, or `launch_agent.sh remove`, sends SIGTERM, so zen is never handed back.
- **Per-app CPU:** it double-counts child apps and dips when a child exits (Swift).
- **Dev-run NERViewer:** a NERViewer run from the editor isn't recognised by the cockpit (Swift).
- **Universal helpers:** NERViewer's helper is universal now (item 1); the cockpit's own Swift helper is not.
- **macOS 11:** without `hw.perflevel*` the helper puts every core on the outer ring (`inner_kind` `none`). Untested; only matters on Big Sur.
- **1x screens:** the thick-line (`lift`) mode and the inscription oversampling are untested on a non-Retina display.
- **Multi-monitor:** the frames and title-bar cover are untested with more than one screen.
