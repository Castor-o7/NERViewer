extends Glyph
## CPU as concentric rings. P-cores on the outer ring, E-cores on the
## inner, arc length = utilization. The central triangle glows with the
## total. Geometry carries the data; luminance carries the feeling.

const DRIFT_PERIOD := 180.0  # one revolution of the dashed rings, seconds

@export var outer_radius := 210.0
@export var inner_radius := 150.0
@export var core_radius := 34.0
## The caption (CPU, TOTAL) and the core-count line. Off while docked in the
## cockpit: at sigil size they are unreadable and sit on the turning ring.
@export var captions := true

var _gap := deg_to_rad(7.0)
var _drift := 0.0

## The strokes that only breathe or turn are layers, drawn once (see
## Glyph.Layer); _pose() tints and turns them each frame. What follows the
## numbers (the arcs, the core, the text) is drawn each frame in _draw.
var _backing: Layer
var _guides: Layer
var _dashes_outer: Layer
var _dashes_inner: Layer
var _scale_circle: Layer
var _scale_ticks: Layer
var _core_ticks: Layer
var _statics: Layer
## The arcs' halos, one shader quad per ring (halo_ring.gdshader).
const HaloRing := preload("res://scenes/glyphs/halo_ring.gdshader")
const HALO_SLOTS := 16
var _halo_outer: Layer
var _halo_inner: Layer
var _backing_key := Color()
var _perf := -1
var _eff := -1


func _ready() -> void:
	super()
	_backing = add_layer(_paint_backing)
	_guides = add_layer(_paint_guides)
	_dashes_outer = add_layer(_paint_dashed_ring.bind((outer_radius + inner_radius) * 0.5, 48))
	_dashes_inner = add_layer(_paint_dashed_ring.bind(inner_radius - 30.0, 24))
	_scale_circle = add_layer(_paint_scale_circle)
	_scale_ticks = add_layer(_paint_scale_ticks)
	_core_ticks = add_layer(_paint_core_ticks)
	_statics = add_layer(_paint_statics)
	_halo_outer = _add_halo(outer_radius, 3.0)
	_halo_inner = _add_halo(inner_radius, 2.5)
	_pose()


func _add_halo(radius: float, width: float) -> Layer:
	var layer := add_layer(_paint_halo.bind(radius + Glyph.HALO_REACH))
	var mat := ShaderMaterial.new()
	mat.shader = HaloRing
	mat.set_shader_parameter("radius", radius)
	mat.set_shader_parameter("stroke", width)
	mat.set_shader_parameter("gap", _gap)
	layer.material = mat
	return layer


func _process(dt: float) -> void:
	_drift = fmod(_drift + dt * TAU / DRIFT_PERIOD, TAU)
	_pose()
	super(dt)


func _pose() -> void:
	var s: StatSample = Stats.smooth
	var frame := Palette.color("frame")
	var light := Palette.color("light")
	var breath := Palette.breath()
	# The layers whose shape follows the machine or the mode are drawn
	# again only when that changes.
	var backing := Palette.dim(Palette.color("ground"), Palette.backing_alpha)
	if backing != _backing_key:
		_backing_key = backing
		_backing.queue_redraw()
	var n := s.cpu_cores.size()
	var eff := clampi(s.cpu_eff_cores, 0, n)
	if eff != _eff or n - eff != _perf:
		_eff = eff
		_perf = n - eff
		_core_ticks.queue_redraw()
		_statics.queue_redraw()
	# Guide rings: the track the arcs run on. At idle this is the geometry.
	_guides.modulate = Palette.dim(frame, 0.18 + 0.22 * breath)
	var dash := Palette.dim(frame, 0.12 + 0.1 * breath)
	_dashes_outer.modulate = dash
	_dashes_outer.rotation = _drift
	_dashes_inner.modulate = dash
	_dashes_inner.rotation = -_drift * 1.5
	# The scale ring breathes. Dark at the bottom of the breath; at the top,
	# in light rather than frame color and fully opaque, about twice as
	# bright as the old heartbeat's peak. One rise and fall per breath
	# period (10 s in Yggdrasil). Replaced the per-sample heartbeat on
	# 2026-09-10 at Josh's request: a beat is discrete, a breath flows.
	var swell := smoothstep(0.0, 1.0, breath)
	var scale_color := Palette.dim(frame.lerp(light, 0.6 * swell), lerpf(0.04, 1.0, swell))
	_scale_ticks.modulate = scale_color
	_scale_circle.modulate = Palette.dim(scale_color, scale_color.a * 0.5)
	_core_ticks.modulate = Palette.dim(frame, 0.4 + 0.2 * breath)
	_statics.modulate = Palette.dim(frame, 1.0)
	_pose_halo(_halo_outer, s.cpu_cores.slice(eff, n), frame, light)
	_pose_halo(_halo_inner, s.cpu_cores.slice(0, eff), frame, light)


func _pose_halo(layer: Layer, vals: PackedFloat32Array, frame: Color, light: Color) -> void:
	var count := mini(vals.size(), HALO_SLOTS)
	layer.visible = Palette.halo and count > 0
	if not layer.visible:
		return
	var values := PackedFloat32Array()
	var tints := PackedColorArray()
	values.resize(HALO_SLOTS)
	tints.resize(HALO_SLOTS)
	for i in count:
		values[i] = vals[i]
		tints[i] = frame.lerp(light, clampf(vals[i], 0.0, 1.0) * 0.85)
	var mat := layer.material as ShaderMaterial
	mat.set_shader_parameter("count", count)
	mat.set_shader_parameter("values", values)
	mat.set_shader_parameter("tints", tints)


func _draw() -> void:
	var s: StatSample = Stats.smooth
	var frame := Palette.color("frame")
	var light := Palette.color("light")
	var core := Palette.color("core")
	var breath := Palette.breath()

	var n := s.cpu_cores.size()
	var eff := clampi(s.cpu_eff_cores, 0, n)
	if n > 0:
		_draw_group(s.cpu_cores.slice(eff, n), outer_radius, frame, light, 3.0)
		_draw_group(s.cpu_cores.slice(0, eff), inner_radius, frame, light, 2.5)

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
	draw_arc(Vector2.ZERO, core_radius + 10.0, 0.0, TAU, 96, Palette.dim(core, 0.2 + 0.5 * total), 1.0, true)

	if captions:
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
		# Never shorter than a dot, so an idle core still exists.
		var end := start + maxf(span * v, 0.012)
		var tint := frame.lerp(light, v * 0.85)
		var pts := maxi(int(64 * v) + 4, 4)
		draw_arc(Vector2.ZERO, radius, start, end, pts, Palette.emit(tint, v), width, true)


func _paint_backing(on: Layer) -> void:
	if _backing_key.a > 0.0:
		on.draw_rect(Rect2(-half(), size), _backing_key, true)


func _paint_guides(on: Layer) -> void:
	on.draw_arc(Vector2.ZERO, outer_radius, 0.0, TAU, 160, Color.WHITE, 1.0, true)
	on.draw_arc(Vector2.ZERO, inner_radius, 0.0, TAU, 160, Color.WHITE, 1.0, true)


## The scale ring: ticks every 5 degrees, longer every 15, and a hairline
## circle to hang them on, at half their alpha (so a layer of its own).
func _paint_scale_circle(on: Layer) -> void:
	on.draw_arc(Vector2.ZERO, outer_radius + 26.0, 0.0, TAU, 180, Color.WHITE, 1.0, true)


func _paint_scale_ticks(on: Layer) -> void:
	var radius := outer_radius + 26.0
	for i in 72:
		var a := i * TAU / 72.0
		var d := Vector2.from_angle(a)
		var len := 6.0 if i % 3 == 0 else 3.0
		on.draw_line(d * radius, d * (radius + len), Color.WHITE, 1.0, true)


func _paint_dashed_ring(on: Layer, radius: float, dashes: int) -> void:
	var step := TAU / dashes
	for i in dashes:
		var a := i * step
		on.draw_arc(Vector2.ZERO, radius, a, a + step * 0.45, 6, Color.WHITE, 1.0, true)


func _paint_halo(on: Layer, reach: float) -> void:
	on.draw_rect(Rect2(-reach, -reach, reach * 2.0, reach * 2.0), Color.WHITE)


## The tick at the start of each core's slice.
func _paint_core_ticks(on: Layer) -> void:
	for group in [[_perf, outer_radius], [_eff, inner_radius]]:
		var count: int = group[0]
		var radius: float = group[1]
		for i in count:
			var d := Vector2.from_angle(-PI * 0.5 + i * TAU / count + _gap * 0.5)
			on.draw_line(d * (radius - 5.0), d * (radius + 5.0), Color.WHITE, 1.0, true)


## Frame-colored strokes at fixed alphas: the spokes from the inner ring
## to the core, one per E-core boundary, then the brackets and rulers.
func _paint_statics(on: Layer) -> void:
	for i in maxi(_eff, 1):
		var a := -PI * 0.5 + i * TAU / maxi(_eff, 1)
		var d := Vector2.from_angle(a)
		on.draw_line(d * (core_radius + 16.0), d * (inner_radius - 36.0), Palette.dim(Color.WHITE, 0.22), 1.0, true)
	draw_brackets(Palette.dim(Color.WHITE, 0.85), 22.0, on)
	draw_ruler(half().y - 8.0, Palette.dim(Color.WHITE, 0.35), 20, true, on)
	draw_ruler(-half().y + 8.0, Palette.dim(Color.WHITE, 0.35), 20, false, on)


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

