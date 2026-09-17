class_name Glyph
extends Node2D
## Shared drawing vocabulary. A glyph draws in local space with its frame
## centered on the origin; `size` is the frame. Brackets, rulers and
## captions are the same on every panel, the way every reference screen
## is captioned the same way.

## There is no heartbeat. A per-sample pulse (tried as a snap, then as a
## swell) is discrete and sharp at two a second and made Josh anxious
## (2026-09-10). Everything that wants to move at idle rides
## Palette.breath(), the one slow breath, and nothing else.
const SMALL := 10

@export var size := Vector2(300.0, 200.0)

var _font: Font = Palette.FONT


func _ready() -> void:
	Palette.changed.connect(queue_redraw)


func _process(_dt: float) -> void:
	queue_redraw()


func half() -> Vector2:
	return size * 0.5


## A part of a glyph whose shape does not change from frame to frame:
## drawn once, in white, then tinted (modulate) and turned (rotation) as
## a node. Re-issuing the same strokes thirty times a second was half
## the cost of the docked sigil (tools/profile.tscn, 2026-09-17). Layers
## lie under the glyph's own _draw, in the order they were added.
class Layer extends Node2D:
	var paint: Callable

	func _draw() -> void:
		paint.call(self)


func add_layer(paint: Callable) -> Layer:
	var layer := Layer.new()
	layer.paint = paint
	layer.show_behind_parent = true
	add_child(layer)
	return layer


## Halo passes: [extra width, alpha], innermost first, scaled by heat.
## Twelve finely graded layers so the falloff reads as continuous; with
## fewer, each layer's edge shows as a step once the HDR blur is gone.
const HALO_LAYERS := 12
const HALO_REACH := 38.0
## Halos never go fully dark: at rest every emitter keeps this much of its
## glow, so the piece stays ethereal at idle and load brightens it from here.
const HALO_FLOOR := 0.15
var _halo: Array = _build_halo()


static func _build_halo() -> Array:
	var out := []
	for i in HALO_LAYERS:
		var t := float(i) / (HALO_LAYERS - 1)
		var width := 2.0 + HALO_REACH * pow(t, 1.5)
		var alpha := 0.11 * pow(1.0 - t, 2.0) + 0.006
		out.append([width, alpha])
	return out


func halo_arc(center: Vector2, radius: float, start: float, end: float, points: int, color: Color, width: float, heat: float) -> void:
	if not Palette.halo:
		return
	heat = maxf(heat, HALO_FLOOR)
	for layer in _halo:
		draw_arc(center, radius, start, end, points, Color(color.r, color.g, color.b, layer[1] * heat), width + layer[0], true)


func halo_line(from: Vector2, to: Vector2, color: Color, width: float, heat: float) -> void:
	if not Palette.halo:
		return
	heat = maxf(heat, HALO_FLOOR)
	for layer in _halo:
		draw_line(from, to, Color(color.r, color.g, color.b, layer[1] * heat), width + layer[0], true)


func halo_circle(center: Vector2, radius: float, color: Color, heat: float) -> void:
	if not Palette.halo:
		return
	heat = maxf(heat, HALO_FLOOR)
	for layer in _halo:
		draw_circle(center, radius + layer[0] * 0.5, Color(color.r, color.g, color.b, layer[1] * heat))


func halo_polyline(pts: PackedVector2Array, color: Color, width: float, heat: float) -> void:
	if not Palette.halo or pts.size() < 2:
		return
	heat = maxf(heat, HALO_FLOOR)
	for layer in _halo:
		draw_polyline(pts, Color(color.r, color.g, color.b, layer[1] * heat), width + layer[0], true)


## A smooth radial glow for compact shapes like the core, where layered
## echoes would band. One gradient texture, shared by every glyph.
static var _radial: GradientTexture2D


static func _radial_texture() -> GradientTexture2D:
	if _radial == null:
		var g := Gradient.new()
		# Linear stops shaped like an inverse-square falloff. Cubic overshoots
		# near the last stop and leaves a visible disc edge.
		g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_LINEAR
		g.offsets = PackedFloat32Array([0.0, 0.1, 0.2, 0.3, 0.45, 0.6, 0.8, 0.92, 1.0])
		g.colors = PackedColorArray([
			Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.7), Color(1, 1, 1, 0.45),
			Color(1, 1, 1, 0.28), Color(1, 1, 1, 0.14), Color(1, 1, 1, 0.06),
			Color(1, 1, 1, 0.015), Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.0)])
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(0.5, 0.0)
		t.width = 256
		t.height = 256
		_radial = t
	return _radial


func halo_glow(center: Vector2, radius: float, color: Color, heat: float) -> void:
	if not Palette.halo:
		return
	heat = maxf(heat, HALO_FLOOR)
	var rect := Rect2(center - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)
	draw_texture_rect(_radial_texture(), rect, false, Color(color.r, color.g, color.b, 0.6 * heat))


## Smoked glass under the panel, only in desktop mode with a backing level set.
func draw_backing() -> void:
	if Palette.backing_alpha <= 0.0:
		return
	draw_rect(Rect2(-half(), size), Palette.dim(Palette.color("ground"), Palette.backing_alpha), true)


## Corner brackets, not a box. The reference frames are open.
func draw_brackets(color: Color, arm: float = 18.0, on: CanvasItem = self) -> void:
	var h := half()
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var c := Vector2(sx * h.x, sy * h.y)
			on.draw_line(c, c + Vector2(-sx * arm, 0.0), color, 1.0, true)
			on.draw_line(c, c + Vector2(0.0, -sy * arm), color, 1.0, true)


## Hairline ticks along a horizontal edge, the reference's rulers.
func draw_ruler(y: float, color: Color, count: int = 20, up: bool = true, on: CanvasItem = self) -> void:
	var h := half()
	var dir := -1.0 if up else 1.0
	for i in count + 1:
		var x := -h.x + i * size.x / count
		var len := 5.0 if i % 5 == 0 else 2.5
		on.draw_line(Vector2(x, y), Vector2(x, y + dir * len), color, 1.0, true)


func label(pos: Vector2, text: String, color: Color, align := HORIZONTAL_ALIGNMENT_LEFT, px: int = SMALL) -> void:
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	match align:
		HORIZONTAL_ALIGNMENT_CENTER:
			pos.x -= w * 0.5
		HORIZONTAL_ALIGNMENT_RIGHT:
			pos.x -= w
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)


## Title top-left, readout top-right.
func draw_caption(title: String, readout: String, frame: Color, light: Color) -> void:
	var h := half()
	label(Vector2(-h.x + 6.0, -h.y + 16.0), title, Palette.dim(frame, 0.7))
	label(Vector2(h.x - 6.0, -h.y + 16.0), readout, Palette.dim(light, 0.55), HORIZONTAL_ALIGNMENT_RIGHT)


static func fmt_bytes(v: float) -> String:
	if v >= 1.0e9:
		return "%.2f GB/S" % (v / 1.0e9)
	if v >= 1.0e6:
		return "%.2f MB/S" % (v / 1.0e6)
	if v >= 1.0e3:
		return "%.1f KB/S" % (v / 1.0e3)
	return "%d B/S" % int(v)


static func fmt_gib(b: int) -> String:
	return "%.2f" % (b / 1073741824.0)

