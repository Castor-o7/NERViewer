extends Glyph
## CPU as concentric rings. P-cores on the outer ring, E-cores (or, on a
## CPU without them, the cache cluster carrying the light load, or on a
## one-cluster SMT CPU each core's second thread under its first) on the
## inner, arc length = utilization. The central triangle glows with the
## total. Geometry carries the data; luminance carries the feeling.

const DRIFT_PERIOD := 180.0  # one revolution of the dashed rings, seconds

@export var outer_radius := 210.0
@export var inner_radius := 150.0
@export var core_radius := 34.0
## The caption (CPU, TOTAL) and the core-count line. Off while docked in the
## cockpit: at sigil size they are unreadable and sit on the turning ring.
@export var captions := true

## The gap between two cores' slices. Up to 25 cores a ring it is 7
## degrees, as it always was (every Apple Silicon ring, the 5900X's 6/6);
## past that it is half the slice, so a 64-core ring still has arcs.
var _gap := deg_to_rad(7.0)
## Readouts past this many outer cores stand for a run of neighbours
## each (their mean), so the labels never crowd into each other.
const READOUTS_MAX := 24
## Docked (Palette.lift), a ring of more cores than this reads as a ring
## of dashes, so neighbours merge into runs showing their mean, as the
## readouts do. Only a many-core Linux box gets here; never the Mac.
const DOCKED_SLICES_MAX := 32
var _drift := 0.0


func _init() -> void:
	dim_without_signal = false


func _process(dt: float) -> void:
	_drift = fmod(_drift + dt * TAU / DRIFT_PERIOD, TAU)
	super(dt)


func _draw() -> void:
	draw_backing()
	var s: StatSample = Stats.smooth
	var frame := Palette.color("frame")
	var light := Palette.color("light")
	var core := Palette.color("core")
	var breath := Palette.breath()

	# Guide rings: the track the arcs run on. At idle this is the geometry.
	var guide := Palette.dim(frame, 0.18 + 0.22 * breath)
	draw_arc(Vector2.ZERO, outer_radius, 0.0, TAU, 160, guide, Palette.hair, true)
	var n := s.cpu_cores.size()
	var inner := clampi(s.cpu_inner_cores, 0, n)
	# No signal: the geometry alone, a hollow core and the words, so
	# frozen or missing readings never pass for the machine's. This glyph
	# says it because docked it is the only thing on screen.
	var lost := Stats.no_signal()
	if n > 0 and inner == 0 and not lost:
		# Nothing for the inner ring (one cluster, no SMT, no E-cores): its
		# track is lit and breathes instead of lying dark, so it reads as
		# part of the machine rather than a missing half. Apple Silicon
		# always has E-cores there and never comes here.
		var lit := frame.lerp(light, 0.35 + 0.25 * breath)
		halo_arc(Vector2.ZERO, inner_radius, 0.0, TAU, 160, lit, Palette.hair, 0.15 + 0.2 * breath)
		draw_arc(Vector2.ZERO, inner_radius, 0.0, TAU, 160, Palette.emit(Palette.dim(lit, 0.45 + 0.35 * breath), 0.2 * breath), Palette.hair, true)
	else:
		draw_arc(Vector2.ZERO, inner_radius, 0.0, TAU, 160, guide, Palette.hair, true)
	_draw_dashed_ring((outer_radius + inner_radius) * 0.5, 48, Palette.dim(frame, 0.12 + 0.1 * breath), _drift)
	_draw_dashed_ring(inner_radius - 30.0, 24, Palette.dim(frame, 0.12 + 0.1 * breath), -_drift * 1.5)
	# The scale ring breathes. Dark at the bottom of the breath; at the top,
	# in light rather than frame color and fully opaque, about twice as
	# bright as the old heartbeat's peak. One rise and fall per breath
	# period (10 s in Yggdrasil). Replaced the per-sample heartbeat on
	# 2026-09-10 at Josh's request: a beat is discrete, a breath flows.
	var swell := smoothstep(0.0, 1.0, breath)
	_draw_scale_ring(outer_radius + 26.0, Palette.dim(frame.lerp(light, 0.6 * swell), lerpf(0.04, 1.0, swell)))

	if lost:
		_draw_no_signal(frame, breath)
		return

	if n > 0:
		var outer_vals := s.cpu_cores.slice(inner, n)
		var inner_vals := s.cpu_cores.slice(0, inner)
		if Palette.lift:
			outer_vals = _runs(outer_vals, DOCKED_SLICES_MAX)
			inner_vals = _runs(inner_vals, DOCKED_SLICES_MAX)
		_draw_group(outer_vals, outer_radius, frame, light, 3.0)
		_draw_group(inner_vals, inner_radius, frame, light, 2.5)

	# Spokes from the inner ring to the core, one per inner-ring boundary.
	for i in maxi(inner, 1):
		var a := -PI * 0.5 + i * TAU / maxi(inner, 1)
		var d := Vector2.from_angle(a)
		draw_line(d * (core_radius + 16.0), d * (inner_radius - 36.0), Palette.dim(frame, 0.22), Palette.hair, true)

	# The core: the only filled shapes. A triangle split Sierpinski-wise
	# once: three corner triangles around an empty middle one. Below 1.0
	# it is a dim gold ember; past a quarter load it starts to emit; at
	# full load it is the brightest thing on screen.
	var total := s.cpu_total
	var r := core_radius * (1.0 + 0.07 * breath)
	var pts := PackedVector2Array()
	for i in 3:
		pts.append(Vector2.from_angle(-PI * 0.5 + i * TAU / 3.0) * r)
	var k := lerpf(0.6, 3.2, total) * (0.85 + 0.3 * breath)
	halo_glow(Vector2.ZERO, core_radius * 3.4, core, clampf((total - 0.15) / 0.85, 0.0, 1.0) * (0.85 + 0.3 * breath))
	var fill := Color(core.r * k, core.g * k, core.b * k, 1.0)
	for i in 3:
		var a := pts[i]
		var b := pts[(i + 1) % 3]
		var c := pts[(i + 2) % 3]
		draw_colored_polygon(PackedVector2Array([a, (a + b) * 0.5, (a + c) * 0.5]), fill)
	draw_arc(Vector2.ZERO, core_radius + 10.0, 0.0, TAU, 96, Palette.dim(core, 0.2 + 0.5 * total), Palette.hair, true)

	draw_brackets(Palette.dim(frame, 0.85), 22.0)
	draw_ruler(half().y - 8.0, Palette.dim(frame, 0.35), 20)
	draw_ruler(-half().y + 8.0, Palette.dim(frame, 0.35), 20, false)
	if captions:
		draw_caption("CPU", "TOTAL %04.1f" % (total * 100.0), frame, light)
		var names := s.group_names()
		var counts := [s.cpu_perf_cores, s.cpu_eff_cores] if names[1] == "E" else [n - inner, inner]
		var groups := "%s %d" % [names[0], counts[0]] if names[1] == "" else "%s %d  %s %d" % [names[0], counts[0], names[1], counts[1]]
		label(Vector2(-half().x + 6.0, -half().y + 29.0), groups, Palette.dim(light, 0.55))
	_draw_readouts(s, light)


func _draw_no_signal(frame: Color, breath: float) -> void:
	var pts := PackedVector2Array()
	for i in 4:
		pts.append(Vector2.from_angle(-PI * 0.5 + i * TAU / 3.0) * core_radius)
	draw_polyline(pts, Palette.dim(frame, 0.35), Palette.hair, true)
	# Docked the sigil is a few hundred pixels across: the words go large.
	var px := SMALL if captions else 30
	var alarm := Palette.dim(Palette.color("alarm"), 0.55 + 0.3 * breath)
	label(Vector2(0.0, core_radius + 14.0 + px), "NO SIGNAL", alarm, HORIZONTAL_ALIGNMENT_CENTER, px)
	draw_brackets(Palette.dim(frame, 0.85), 22.0)
	draw_ruler(half().y - 8.0, Palette.dim(frame, 0.35), 20)
	draw_ruler(-half().y + 8.0, Palette.dim(frame, 0.35), 20, false)
	if captions:
		draw_caption("CPU", "NO SIGNAL", frame, Palette.color("alarm"))


## One ring of cores. Each core owns an equal slice; its arc fills the
## slice in proportion to its utilization.
func _draw_group(vals: PackedFloat32Array, radius: float, frame: Color, light: Color, width: float) -> void:
	var count := vals.size()
	if count == 0:
		return
	var slice := TAU / count
	var gap := minf(_gap, slice * 0.5)
	var span := slice - gap
	for i in count:
		var start := -PI * 0.5 + i * slice + gap * 0.5
		var v := clampf(vals[i], 0.0, 1.0)
		var d := Vector2.from_angle(start)
		draw_line(d * (radius - 5.0), d * (radius + 5.0), Palette.dim(frame, 0.4 + 0.2 * Palette.breath()), Palette.hair, true)
		# Never shorter than a dot, so an idle core still exists.
		var end := start + maxf(span * v, 0.012)
		var tint := frame.lerp(light, v * 0.85)
		var pts := maxi(int(64 * v) + 4, 4)
		halo_arc(Vector2.ZERO, radius, start, end, pts, tint, width, v)
		draw_arc(Vector2.ZERO, radius, start, end, pts, Palette.emit(tint, v), width, true)


## `vals` in at most `most` runs of neighbours, each the run's mean; as
## they are when they already fit.
func _runs(vals: PackedFloat32Array, most: int) -> PackedFloat32Array:
	if vals.size() <= most:
		return vals
	var per := ceili(float(vals.size()) / most)
	var out := PackedFloat32Array()
	var i := 0
	while i < vals.size():
		var run := mini(per, vals.size() - i)
		var sum := 0.0
		for j in run:
			sum += vals[i + j]
		out.append(sum / run)
		i += run
	return out


## Ticks every 5 degrees, longer every 15, a hairline circle to hang them on.
func _draw_scale_ring(radius: float, color: Color) -> void:
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 180, Palette.dim(color, color.a * 0.5), Palette.hair, true)
	for i in 72:
		var a := i * TAU / 72.0
		var d := Vector2.from_angle(a)
		var len := 6.0 if i % 3 == 0 else 3.0
		draw_line(d * radius, d * (radius + len), color, Palette.hair, true)


func _draw_dashed_ring(radius: float, dashes: int, color: Color, offset: float = 0.0) -> void:
	var step := TAU / dashes
	for i in dashes:
		var a := i * step + offset
		draw_arc(Vector2.ZERO, radius, a, a + step * 0.45, 6, color, Palette.hair, true)


## Per-core readouts at each outer slice, outside the outer ring. Past
## READOUTS_MAX cores each label covers a run of `per` neighbours and reads
## their mean, centred on the run.
func _draw_readouts(s: StatSample, light: Color) -> void:
	if Palette.lift:
		return  # docked below the Mac's density the readouts are 4 px grey squares
	var n := s.cpu_cores.size()
	var inner := clampi(s.cpu_inner_cores, 0, n)
	var perf := n - inner
	if perf <= 0:
		return
	var slice := TAU / perf
	var per := ceili(float(perf) / READOUTS_MAX)
	var i := 0
	while i < perf:
		var run := mini(per, perf - i)
		var sum := 0.0
		for j in run:
			sum += s.cpu_cores[inner + i + j]
		var a := -PI * 0.5 + (i + run * 0.5) * slice
		var p := Vector2.from_angle(a) * (outer_radius + 44.0)
		var txt := "%02d" % int(round(sum / run * 99.0))
		label(p + Vector2(0.0, 4.0), txt, Palette.dim(light, 0.35), HORIZONTAL_ALIGNMENT_CENTER)
		i += run

