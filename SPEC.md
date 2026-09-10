# NERViewer — Spec

A system activity monitor built as a living art piece. The reference set in
`references/` is Evangelion: seven Rebuild-era NERV screens and one
original-series MAGI display. Those screens are the visual spine — hairline
frames on near-black, concentric rings, vertical racks, curves with dot
markers, thin uppercase annotation, a great deal of empty space, and light
that reads as emitted rather than painted. That is already minimalist and
ethereal; the earlier claim that Eva is not minimalist was true of the 1995
series and wrong about Rebuild.

Yggdrasil (Ah! My Goddess) survives as a palette, not a structure: the
same geometry rendered pale blue and gold reads as sacred technology,
rendered red and amber it reads as NERV. Both palettes live in `palette.gd`
and swap with one constant. Josh chose Yggdrasil on 2026-09-09 after living
with both; it is the default. NERV stays available on the P key, and more
design exploration is planned once the functionality is complete.

Godot 4.3 (Forward+), GDScript for the piece, a ~250-line Swift helper for
the numbers. macOS only, Apple Silicon first. Everything in the stats layer
was probed on this machine (M2, 8 cores, macOS 15.7, Godot 4.3.stable,
`/usr/bin/swiftc` with no Xcode) on 2026-09-09; the validated probe sources
are in `helper/probes/`.
## Principles

1. **Beautiful at idle.** The system sits at 4% CPU most of the day. If the
   idle frame is not something you would hang on a wall, nothing else
   matters. Phase 0 exits on that test and nothing else.
2. **Accurate geometry, ethereal rendering.** Data maps to length, radius,
   angle, density — things the eye can compare. Glow, drift, and breath are
   the rendering of that geometry, never a substitute for it.
3. **Six metrics, refused growth.** CPU (per core), load, memory, network,
   thermal state, uptime. Disk, battery, and top processes are optional
   fields for later, not the plan.
4. **The data layer is boring and testable.** The art layer never touches a
   pipe, a thread, or a sysctl. It reads `Stats.smooth` and `Stats.history`.

## Repository layout

```
NERViewer/
  SPEC.md                    this document
  CLAUDE.md, README.md       same conventions as Garden of Mahna: README is
                             the milestone log, newest at top
  helper/
    main.swift               yggstat: the stat daemon (one file, no deps)
    build.sh                 swiftc -O -o ../game/bin/yggstat main.swift
    probes/                  the validated API probes this spec came from
  game/
    project.godot
    bin/yggstat              built helper (gitignored; build.sh makes it)
    autoload/
      stats.gd               "Stats": owns a source, smooths, keeps history
      palette.gd             "Palette": every color, tempo, and glow level
    stats/
      stat_sample.gd         StatSample — the schema, one tick of everything
      stat_source.gd         StatSource — abstract: start/stop, `sample` signal
      stat_source_helper.gd  HelperStatSource — spawns yggstat, reads the pipe
      stat_source_synthetic.gd  SyntheticStatSource — scripted scenarios
      history.gd             History — ring buffer with min/max/mean
    scenes/
      main.tscn              WorldEnvironment (glow) + Composition
      composition/
        yggdrasil.tscn       the central form; places and scales the glyphs
      glyphs/                one scene per metric (see Visual mapping)
        core_ring.tscn
        breath.tscn
        threads.tscn
        orbits.tscn
        veil.tscn
    shaders/
      glow_line.gdshader
      effulgence.gdshader
    fonts/
    tools/
      stats_probe.tscn/.gd   headless: helper + synthetic, schema asserts
      shots.tscn/.gd         screenshots of scripted states for review
      alpha_probe.tscn/.gd   windowed: does the glow carry alpha in desktop mode
    export_presets.cfg       macOS preset for tools/build_app.sh
  tools/
    build_app.sh             helper + export + bundle + re-sign -> dist/NERViewer.app
    launch_agent.sh          install|remove a LaunchAgent that starts the app at login
  dist/                      built app (gitignored)
```

Autoload names are PascalCase, files snake_case, matching your other
projects. `godot` is not on PATH here; use
`/Applications/Godot.app/Contents/MacOS/Godot --path game`.

## The stats layer

### Sample schema

One JSON object per line from the helper. Every field is always present so
the Godot side never branches on presence. Sizes in bytes, rates in bytes
per second, fractions in 0..1.

```json
{"t":1757444000.512,
 "cpu":{"cores":[0.12,0.08,0.05,0.03,0.31,0.02,0.01,0.00],"total":0.08,"perf":4,"eff":4},
 "load":[1.29,1.41,1.53],
 "mem":{"total":17179869184,"used":9120000000,"wired":2227000000,
        "compressed":469000000,"free":1300000000,"pressure":0.17},
 "net":{"rx_bps":3120.0,"tx_bps":1024.0},
 "thermal":0,
 "uptime":812345.0}
```

```gdscript
class_name StatSample
extends RefCounted
## One tick of everything the piece knows about the machine.

var t: float                       ## unix seconds, the helper's clock
var cpu_cores: PackedFloat32Array  ## 0..1 per logical core, helper order
var cpu_total: float
var cpu_perf_cores: int            ## hw.perflevel0.logicalcpu
var cpu_eff_cores: int             ## hw.perflevel1.logicalcpu
var load: Vector3                  ## 1, 5, 15 minute averages
var mem_total: int
var mem_used: int                  ## wired + active + compressed
var mem_wired: int
var mem_compressed: int
var mem_free: int
var mem_pressure: float            ## 1 - kern.memorystatus_level / 100
var net_rx_bps: float
var net_tx_bps: float
var thermal: int                   ## 0 nominal, 1 fair, 2 serious, 3 critical
var uptime: float

static func from_json(d: Dictionary) -> StatSample: ...
```

Core order: on Apple Silicon `host_processor_info` lists efficiency cores
first. Confirmed by the probe on 2026-09-09: the first four cores carry the
light load.

### yggstat — the Swift helper

One `main.swift`, compiled with `swiftc -O` (4.5 s here, no Xcode needed).
Foundation and Darwin only. Runs a loop: sample, diff against the previous
sample, print one JSON line, sleep. Exits when its stdout pipe closes
(SIGPIPE on the next write) or when `getppid() == 1` (orphaned).

```
yggstat [--interval 500] [--once]
```

`--once` prints a single sample and exits — the build script's smoke test.
Set `setvbuf(stdout, nil, _IOLBF, 0)` so every line flushes.

Sources, all validated in `helper/probes/probe.swift` and `ifmib.swift`:

| field | API | notes |
|---|---|---|
| cpu.cores | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | per-core user/system/idle/nice ticks; util = 1 - Δidle/Δtotal. `vm_deallocate` the buffer each call. |
| cpu.perf/eff | `sysctlbyname("hw.perflevel0.logicalcpu")`, `perflevel1` | 4 and 4 on M2. Read once. |
| load | `getloadavg` | |
| mem.* | `host_statistics64(HOST_VM_INFO64)` × `vm_kernel_page_size` (16384 here) | used = wire + active + compressor_page_count. total from `hw.memsize`. |
| mem.pressure | `sysctlbyname("kern.memorystatus_level")` | 100 = no pressure; store `1 - level/100`. |
| net | `sysctl [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, ifindex, IFDATA_GENERAL]` → `ifmibdata.ifmd_data.ifi_ibytes/obytes` | The only source with true 64-bit counters; matches `netstat -ib` exactly. `NET_RT_IFLIST2` and `getifaddrs` both truncate to 32 bits on this OS — do not use them. Enumerate with `if_nameindex()`, skip `lo0`, sum the rest. |
| thermal | `ProcessInfo.processInfo.thermalState.rawValue` | Public API. Real temperatures need private SMC calls; do not chase them. `powermetrics` needs sudo; do not use it. |
| uptime | `ProcessInfo.processInfo.systemUptime` | |

The validated network read, verbatim:

```swift
let idx = Int32(if_nametoindex(name))
var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, idx, IFDATA_GENERAL]
var len = 0
sysctl(&mib, 6, nil, &len, nil, 0)
var buf = [UInt8](repeating: 0, count: len)
sysctl(&mib, 6, &buf, &len, nil, 0)
let d = buf.withUnsafeBytes { $0.load(as: ifmibdata.self) }
// d.ifmd_data.ifi_ibytes, d.ifmd_data.ifi_obytes — UInt64
```

Optional fields for Phase 2, each behind its own flag so a failure cannot
take the helper down:

- `disk` read/write bps: IOKit, `IOBlockStorageDriver` → `Statistics`
  dictionary, keys `Bytes (Read)` / `Bytes (Write)`.
- `battery`: `IOPSCopyPowerSourcesInfo`. Percent, charging, present.
- `top`: `proc_listallpids` + `proc_pid_rusage` deltas + `proc_name`,
  top five by CPU. The names of things living in the tree.

### Godot side

**StatSource** is the abstract contract. Everything above the autoload
sees only this.

```gdscript
class_name StatSource
extends Node
signal sample(s: StatSample)
signal failed(reason: String)
func start() -> void: pass
func stop() -> void: pass
func source_name() -> String: return "none"
```

**HelperStatSource** spawns yggstat with `OS.execute_with_pipe` (new in
4.3, present in this binary) and reads it on a Thread. The read loop copes
with either blocking or non-blocking pipe semantics, because the 4.3 docs
are not explicit and the probe will settle it.

```gdscript
class_name HelperStatSource
extends StatSource

const HELPER := "res://bin/yggstat"
var _proc: Dictionary
var _thread: Thread
var _running := false

func start() -> void:
	var path := ProjectSettings.globalize_path(HELPER)
	if not FileAccess.file_exists(path):
		failed.emit("helper missing at %s; run helper/build.sh" % path)
		return
	_proc = OS.execute_with_pipe(path, ["--interval", "500"])
	if _proc.is_empty():
		failed.emit("could not spawn helper")
		return
	_running = true
	_thread = Thread.new()
	_thread.start(_read_loop)

func _read_loop() -> void:
	var pipe: FileAccess = _proc["stdio"]
	while _running and pipe.is_open():
		var line := pipe.get_line()
		if line.is_empty():
			if pipe.eof_reached():
				break
			OS.delay_msec(10)
			continue
		_on_line.call_deferred(line)
	_on_closed.call_deferred()

func _on_line(line: String) -> void:
	var d = JSON.parse_string(line)
	if d is Dictionary:
		sample.emit(StatSample.from_json(d))

func _on_closed() -> void:
	if _running:
		failed.emit("helper exited")

func stop() -> void:
	_running = false
	if _proc.has("pid"):
		OS.kill(_proc["pid"])        # first: unblocks a blocking get_line
	if _proc.has("stdio"):
		_proc["stdio"].close()
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
```

Order in `stop()` matters: kill, then close, then join. Call it from
`_exit_tree` and from `NOTIFICATION_WM_CLOSE_REQUEST`.

**SyntheticStatSource** emits at the same 500 ms cadence from scripted
scenarios, with `FastNoiseLite` layered on so nothing is sterile. This is
the art-direction tool; the piece is designed against it before real data
ever arrives.

| scenario | what it plays |
|---|---|
| `idle` | 2-6% CPU, gentle noise, memory steady, a trickle of network |
| `drift` | idle with one core wandering to 40% and back over a minute |
| `ramp` | all cores rising to 90% over 20 s, holding, thermal 0→1→2 |
| `spike` | one-second saturation on four cores, then recovery |
| `download` | rx climbing three orders of magnitude, CPU quiet |
| `pressure` | memory used climbing to 95%, compressed growing, pressure 0.7 |

Exposes `scenario: String`, `seek(t: float)`, and `speed`. A debug key
cycles scenarios in the running piece.

**Stats** (autoload) owns whichever source is active, eases toward each
sample every frame, and keeps history. Visuals read `Stats.smooth` and
`Stats.history`, never a source.

```gdscript
extends Node
## "Stats" autoload. Owns the source, smooths, keeps history.

signal sampled(s: StatSample)
signal source_changed(name: String)

const HISTORY_LEN := 360   # 3 minutes at 500 ms

var raw: StatSample
var smooth: StatSample     # eased toward raw each frame; what glyphs draw
var history := {}          # "cpu_total", "net_rx_bps", ... -> History

## Per-field easing rate. Higher follows faster. The breath is the tween.
const RATE := {
	"cpu_cores": 4.0, "cpu_total": 4.0,
	"mem_used": 1.0, "mem_pressure": 1.0,
	"net_rx_bps": 6.0, "net_tx_bps": 6.0,
	"load": 0.5,
}

func use(source: StatSource) -> void: ...

func _process(dt: float) -> void:
	# frame-rate independent approach; k from RATE
	# v = lerp(v, target, 1.0 - exp(-k * dt))
	...

## Bytes span six orders of magnitude; linear scales are useless.
static func log_norm(bps: float, ceiling_bps: float) -> float:
	return clampf(log(1.0 + bps) / log(1.0 + ceiling_bps), 0.0, 1.0)
```

Startup: try `HelperStatSource`; on `failed`, fall back to
`SyntheticStatSource("idle")` and say so quietly in the corner in phosphor
text. The piece must never show a blank frame.

## Project settings

```
[application]
config/features=PackedStringArray("4.3", "Forward Plus")
run/main_scene="res://scenes/main.tscn"

[autoload]
Palette="*res://autoload/palette.gd"
Stats="*res://autoload/stats.gd"

[display]
window/size/viewport_width=900
window/size/viewport_height=900
window/size/transparent=true
window/size/borderless=true
window/per_pixel_transparency/allowed=true

[rendering]
viewport/hdr_2d=true                 ; colors above 1.0 exist, so glow has something to bloom
viewport/transparent_background=true
```

`main.tscn` holds a `WorldEnvironment` with glow enabled, additive or
screen blend, threshold near 1.0, intensity starting around 0.6. Glow in
2D requires `hdr_2d`. Anything meant to shine is drawn with a color whose
channels exceed 1.0; everything else stays below and does not bloom. That
single rule is what keeps it effulgent instead of blurry.

`Engine.max_fps = 30` in a window, 15 over the desktop or docked in the
cockpit (30 again while being dragged), 3 minimized; this thing runs all
day. Measured 2026-09-09 while docked at 30 fps: 40% of an M2 core, about
half of it GDScript drawing the twelve-layer halo arcs (`draw_arc` builds
an antialiased polyline on the CPU every call) and the rest submitting
frames. Halving the rate halves both. If the docked cost still matters,
the next lever is drawing halos as a ring shader on one quad instead of
twelve polylines, not fewer layers.

## The references, read as a vocabulary

Each screenshot contributes one device. Names here are the glyph scene
names in `scenes/glyphs/`.

| reference | device | what it becomes |
|---|---|---|
| Concentric red rings, radial spokes, yellow triangular core (12.21.49) | `core_ring` | The centerpiece. One ring per core group, arc length = utilization, the core glows with total load. |
| Ring gauge with a yellow sweep and tick marks (12.20.49) | `gauge` | Memory. Sweep = used/total, inner tick ring = wired, a dimmer band = compressed. |
| Vertical rack of repeated bar glyphs in three labelled rows (12.21.29) | `rack` | Per-core history. Each column is one sample, each row one core group; blue at rest, white under load. |
| Sine curves in red, blue, yellow with dot markers (12.21.19) | `curves` | Network. rx and tx as two curves over the last three minutes, log-scaled, dots at each sample. |
| Sparse dot grid with panel dividers (12.21.03) | `dots` | Load average. Three sparse traces, 1/5/15 min, at three time scales. |
| Fan of lines converging to a point, then routed out (12.22.01) | `threads` | Optional, Phase 2: top processes fanning out from the core. |
| Dense text columns, wide red bar (12.20.33) | `ledger` | The alarm state only. Thermal ≥ 2 brings the dense mode in from the edges. |
| Original MAGI: numbered concentric rings, orange type (12.20.22) | `counters` | Uptime and the numerals. Ring-text is the one place the 1995 series lives. |

Common to every screen and therefore rules, not choices:

- **Hairlines.** Frames and rings are one pixel wide at 2x, with corner
  brackets, not boxes. Thickness carries no data; only luminance does.
- **Emptiness.** Most of every panel is black. A glyph that fills its
  frame is wrong.
- **Emitted light.** Everything drawn is a color above 1.0 in HDR; the
  glow does the rest. Nothing is filled except the core triangle.
- **Annotation.** Small uppercase labels with numeric readouts beside each
  glyph, dimmer than the glyph. They are texture as much as information.
- **Tempo.** Rebuild screens are nearly still. Motion is data arriving,
  plus one slow breath. Nothing decorative moves.

## Visual mapping — first hypotheses

To be art-directed against the synthetic scenarios, not decided here.

| metric | glyph | geometry (the accurate part) | rendering (the ethereal part) |
|---|---|---|---|
| CPU per core | `core_ring` | Two concentric rings, P-cores outer, E-cores inner, arcs by utilization. Spokes at core boundaries. | Arcs are hairlines at idle and brighten with load; the central triangle's glow = total. |
| CPU history | `rack` | 120 columns × 2 rows, one column per 500 ms sample, bar height = core-group mean. | Blue-white at rest, white-gold under load. Scrolls left one column per sample. |
| Memory | `gauge` | Sweep angle = used/total; inner tick ring = wired; dim band = compressed. | Pressure warms the sweep from the base color toward amber. |
| Network | `curves` | Two curves over 3 min, `log_norm` with a 100 MB/s ceiling, a dot per sample. | rx in the cool accent, tx in the warm one. At a trickle the curves lie flat and faint. |
| Load 1/5/15 | `dots` | Three dot traces, each panel a different time base. | Sparse; a dot every few samples, so idle reads as stillness rather than noise. |
| Thermal | palette-wide | Four tiers. | Nominal and fair use the base palette; serious brings `ledger` in and reddens the frames; critical is the only time anything blinks. |
| Uptime | `counters` | Days, hours, minutes as ring text and a numeral. | The MAGI orange lives here and nowhere else. |

Two palettes, both in `palette.gd`, chosen by one constant:

| name | NERV (references) | Yggdrasil (proposed) | role |
|---|---|---|---|
| ground | `#07050A` | `#05070D` | background, or transparent |
| frame | `#C8321E` | `#6F7FA8` | hairlines, brackets, rings |
| light | `#D8D2C8` | `#DCE6FF` | text, bright arcs |
| core | `#F2C230` | `#F2D48A` | the filled triangle, sweeps |
| cool | `#3A5BD9` | `#9EF0C8` | rack at rest, rx curve |
| alarm | `#FF3A1A` | `#FF7A1A` | thermal ≥ 2 only |
| breath period | 12 s | 10 s | every idle motion is a multiple of this |

Design pass, 2026-09-09: four more palettes in `palette.gd`, cycled by P.
Kingdom Hearts (command-menu blue, crown gold, cyan glow, heart red for
alarms) and Tears of the Kingdom (Zonai teal on shrine slate, Zonai stone
gold, Gloom for alarms) at Josh's request; Gilliam (Outlaw Star wireframe
amber) and Swordfish (Bebop phosphor green, CRT amber, cockpit blue) as
the two remaining shows from the original list; Terra Trance (Final
Fantasy VI Esper glow: violet ground, orchid hairlines, magenta-pink core)
at Josh's request. Seven palettes. Yggdrasil stays default.

Font: a thin condensed uppercase sans, chosen by setting it beside
`core_ring`. The references use one weight, small, letterspaced. Still
Godot's default as of Phase 2; this is the largest remaining gap between
the piece and the references.

## Tools

- `tools/stats_probe.gd` (headless, `--quit-after`): starts
  `HelperStatSource`, collects four samples within four seconds, asserts
  `cores.size() == perf + eff`, every fraction in 0..1, `used ≤ total`,
  rates ≥ 0, `t` increasing. Then runs every synthetic scenario for two
  simulated minutes at 20× speed with the same asserts. Exit 0 or 1. This
  is also where the pipe blocking question and the E-first core order get
  answered.
- `tools/shots.gd`: loads `main.tscn` with the synthetic source, plays
  each scenario to a representative moment, saves
  `screenshots/<scenario>.png`. `idle.png` is the Phase 0 exit criterion.
- `helper/build.sh`: compiles, then runs `yggstat --once` and checks the
  line parses.

## Phases

**Phase 0 — the idle frame.** Built 2026-09-09; palette chosen: Yggdrasil.
`project.godot`, `Palette` with both palettes, `Stats` with the synthetic source only, `core_ring` as the first
glyph, glow configured, `shots.gd`. Exit: `idle.png`, rendered in each
palette, is something you would hang on a wall. Pick the palette here. If
neither works, nothing later will rescue it; stay here.

**Phase 1 — real data.** Done 2026-09-09. `helper/main.swift` with the six
metrics, `HelperStatSource`, `stats_probe.gd` green. The ring moves with
the actual machine.

**Phase 2 — the composition.** Done 2026-09-09: `gauge`, `rack`, `curves`,
`dots`, `counters` on a shared `Glyph` base; `yggdrasil.tscn` arranges
them on a 1440x900 panel; the frame color reddens at thermal ≥ 2. Two
lessons from the renders: dense emitters (a rack of bars, a long curve)
must be capped well below the arcs' heat or they bloom into a slab, and
the screenshot tool backfills three minutes of history so stills show the
past. Optional helper fields (disk, battery, top) remain unbuilt and get a
glyph only if they earn a place.

**Phase 3 — living on the desktop.** Started 2026-09-09. Desktop mode (B):
transparent, borderless, always on top, drag anywhere to move, Q/Escape
to quit; a smoked-glass backing per panel (G) for bright wallpapers; mode,
palette and window position persist in `user://prefs.cfg`. Completed the
same day: 30 fps awake and 3 fps minimized with low-processor mode;
`tools/build_app.sh` exports `dist/NERViewer.app` (ad-hoc signed, helper
copied into Contents/MacOS, found beside the executable at runtime);
`tools/launch_agent.sh install|remove` starts it at login. Functionality is
complete; what remains is the design pass.

## Risks and open questions

- ~~`FileAccess.get_line()` pipe semantics~~ Answered 2026-09-09: the
  thread loop delivers samples at the helper's 500 ms cadence and the
  kill-close-join order in `stop()` leaves no orphan. Whichever way the
  read blocks, the design holds.
- ~~Core ordering~~ Confirmed 2026-09-09 by the probe: under light load the
  first four cores carried it, so efficiency cores come first.
- Temperatures are off the table without private APIs. Thermal state is
  the honest public substitute and maps better to a "mood" anyway.
- A transparent always-on-top window on macOS can steal clicks. Phase 3
  should test `mouse_passthrough` before committing to the widget form.
- Bloom on a transparent background composites against whatever is behind
  the window; the idle frame must be judged on both a dark and a light
  desktop.
- Measured 2026-09-09 (`tools/alpha_probe.gd`): the glow pass writes color
  into the framebuffer but leaves alpha at zero. Whether the halo shows
  over the desktop therefore depends on macOS compositing the window as
  premultiplied or not. Josh confirmed by eye: the halo vanishes. Fixed
  the same day with a drawn halo pass in `Glyph` (`halo_arc`, `halo_line`,
  `halo_circle`, `halo_polyline`, `halo_polygon`): three wider, fainter
  echoes under every emitting element, scaled by its heat, enabled only in
  desktop mode so the windowed HDR look is unchanged. `alpha_probe` is
  green. The rule for new glyphs: anything drawn above 1.0 also draws its
  halo. Two more lessons from Josh's desktop screenshots the same day:
  dense traces (a hundred dots, a 360-point line) must not draw per-point
  halos, because the overlaps stack into a cloud; and the HDR glow pass
  must be switched off in desktop mode, because its `glow_bloom` fraction
  of everything leaks through as a banded disc around the core. Desktop
  mode's only glow is the drawn one.
