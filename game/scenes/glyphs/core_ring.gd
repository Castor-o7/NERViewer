extends Glyph
## CPU as concentric rings. P-cores on the outer ring, E-cores on the
## inner, arc length = utilization. The central triangle glows with the
## total. Geometry carries the data; luminance carries the feeling.

const DRIFT_PERIOD := 180.0  # one revolution of the dashed rings, seconds

@export var outer_radius := 210.0
@export var inner_radius := 150.0
@export var core_radius := 34.0

var _gap := deg_to_rad(7.0)
var _drift := 0.0


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
	draw_arc(Vector2.ZERO, outer_radius, 0.0, TAU, 160, guide, 1.0, true)
	draw_arc(Vector2.ZERO, inner_radius, 0.0, TAU, 160, guide, 1.0, true)
	_draw_dashed_ring((outer_radius + inner_radius) * 0.5, 48, Palette.dim(frame, 0.12 + 0.1 * breath), _drift)
	_draw_dashed_ring(inner_radius - 30.0, 24, Palette.dim(frame, 0.12 + 0.1 * breath), -_drift * 1.5)
	# The scale ring pulses each time a sample arrives: the heartbeat.
	_draw_scale_ring(outer_radius + 26.0, Palette.dim(frame, 0.22 + 0.4 * _pulse))

	var n := s.cpu_cores.size()
	var eff := clampi(s.cpu_eff_cores, 0, n)
	if n > 0:
		_draw_group(s.cpu_cores.slice(eff, n), outer_radius, frame, light, 3.0)
		_draw_group(s.cpu_cores.slice(0, eff), inner_radius, frame, light, 2.5)

	# Spokes from the inner ring to the core, one per E-core boundary.
	for i in maxi(eff, 1):
		var a := -PI * 0.5 + i * TAU / maxi(eff, 1)
		var d := Vector2.from_angle(a)
		draw_line(d * (core_radius + 16.0), d * (inner_radius - 36.0), Palette.dim(frame, 0.22), 1.0, true)

	# The core: the only filled shape. Below 1.0 it is a dim gold ember;
	# past a quarter load it starts to emit; at full load it is the
	# brightest thing on screen.
	var total := s.cpu_total
	var r := core_radius * (1.0 + 0.07 * breath)
	var pts := PackedVector2Array()
	for i in 3:
		pts.append(Vector2.from_angle(-PI * 0.5 + i * TAU / 3.0) * r)
	var k := lerpf(0.6, 3.2, total) * (0.85 + 0.3 * breath)
	halo_glow(Vector2.ZERO, core_radius * 3.4, core, clampf((total - 0.15) / 0.85, 0.0, 1.0) * (0.85 + 0.3 * breath))
	draw_colored_polygon(pts, Color(core.r * k, core.g * k, core.b * k, 1.0))
	draw_arc(Vector2.ZERO, core_radius + 10.0, 0.0, TAU, 96, Palette.dim(core, 0.2 + 0.5 * total), 1.0, true)

	draw_brackets(Palette.dim(frame, 0.85), 22.0)
	draw_ruler(half().y - 8.0, Palette.dim(frame, 0.35), 20)
	draw_ruler(-half().y + 8.0, Palette.dim(frame, 0.35), 20, false)
	draw_caption("CPU", "TOTAL %04.1f" % (total * 100.0), frame, light)
	label(Vector2(-half().x + 6.0, -half().y + 29.0), "P %d  E %d" % [s.cpu_perf_cores, s.cpu_eff_cores], Palette.dim(light, 0.55))
	_draw_readouts(s, light)


## One ring of cores. Each core owns an equal slice; its arc fills the
## slice in proportion to its utilization.
func _draw_group(vals: PackedFloat32Array, radius: float, frame: Color, light: Color, width: float) -> void:
	var count := vals.size()
	if count == 0:
		return
	var slice := TAU / count
	var span := slice - _gap
	for i in count:
		var start := -PI * 0.5 + i * slice + _gap * 0.5
		var v := clampf(vals[i], 0.0, 1.0)
		var d := Vector2.from_angle(start)
		draw_line(d * (radius - 5.0), d * (radius + 5.0), Palette.dim(frame, 0.45 + 0.5 * _pulse), 1.0, true)
		# Never shorter than a dot, so an idle core still exists.
		var end := start + maxf(span * v, 0.012)
		var tint := frame.lerp(light, v * 0.85)
		var pts := maxi(int(64 * v) + 4, 4)
		halo_arc(Vector2.ZERO, radius, start, end, pts, tint, width, v)
		draw_arc(Vector2.ZERO, radius, start, end, pts, Palette.emit(tint, v), width, true)


## Ticks every 5 degrees, longer every 15, a hairline circle to hang them on.
func _draw_scale_ring(radius: float, color: Color) -> void:
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 180, Palette.dim(color, color.a * 0.5), 1.0, true)
	for i in 72:
		var a := i * TAU / 72.0
		var d := Vector2.from_angle(a)
		var len := 6.0 if i % 3 == 0 else 3.0
		draw_line(d * radius, d * (radius + len), color, 1.0, true)


func _draw_dashed_ring(radius: float, dashes: int, color: Color, offset: float = 0.0) -> void:
	var step := TAU / dashes
	for i in dashes:
		var a := i * step + offset
		draw_arc(Vector2.ZERO, radius, a, a + step * 0.45, 6, color, 1.0, true)


## Per-core readouts at each P-core slice, outside the outer ring.
func _draw_readouts(s: StatSample, light: Color) -> void:
	var n := s.cpu_cores.size()
	var eff := clampi(s.cpu_eff_cores, 0, n)
	var perf := n - eff
	if perf <= 0:
		return
	var slice := TAU / perf
	for i in perf:
		var a := -PI * 0.5 + i * slice + slice * 0.5
		var p := Vector2.from_angle(a) * (outer_radius + 44.0)
		var txt := "%02d" % int(round(s.cpu_cores[eff + i] * 99.0))
		label(p + Vector2(0.0, 4.0), txt, Palette.dim(light, 0.35), HORIZONTAL_ALIGNMENT_CENTER)

