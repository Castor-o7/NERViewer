extends Glyph
## Uptime and thermal state. The one place the original MAGI orange lives,
## and the one thing that ticks once a second.

const THERMAL_WORDS := ["NOMINAL", "FAIR", "SERIOUS", "CRITICAL"]


## The second ring moves once a second, with the sample that carries the
## uptime, so its ticks are data layers: the dark ticks and the current
## one in their colors, the lit ones in white so they can breathe by tint.
## The hairline ring only breathes. _draw keeps the text.
var _lit: Layer
var _ring: Layer


func _ready() -> void:
	super()
	add_data_layer(_paint_ticks.bind(false))
	_lit = add_data_layer(_paint_ticks.bind(true))
	_ring = add_layer(_paint_ring)
	add_frame_layer(_paint_frame)


func _radius() -> float:
	return minf(size.x, size.y) * 0.5 - 40.0


func _pose() -> void:
	var breath := Palette.breath()
	_lit.modulate = Palette.dim(Palette.color("magi"), 0.45 + 0.15 * breath)
	_ring.modulate = Palette.dim(Palette.color("frame"), 0.15 + 0.15 * breath)


## The second ring: sixty ticks, lit up to the current second. Painted as
## the sample lands, a moment before Stats copies it into `smooth`, so it
## reads the sample itself.
func _paint_ticks(on: Layer, lit: bool) -> void:
	var magi := Palette.color("magi")
	var secs := int(fmod(maxf(Stats.raw.uptime, 0.0), 60.0))
	var r := _radius()
	for i in 60:
		if (i < secs) != lit:
			continue
		var d := Vector2.from_angle(-PI * 0.5 + i * TAU / 60.0)
		var len := 7.0 if i % 5 == 0 else 4.0
		var c := Color.WHITE
		if not lit:
			c = Palette.emit(magi, 0.5) if i == secs else Palette.dim(Palette.color("frame"), 0.18)
		if i == secs:
			halo_line(d * r, d * (r + len), magi, 1.0, 0.5, on)
		on.draw_line(d * r, d * (r + len), c, 1.0, true)


func _paint_ring(on: Layer) -> void:
	on.draw_arc(Vector2.ZERO, _radius() - 3.0, 0.0, TAU, 120, Color.WHITE, 1.0, true)


func _paint_frame(on: Layer) -> void:
	draw_brackets(Palette.dim(Color.WHITE, 0.85), 18.0, on)
	draw_ruler(half().y - 8.0, Palette.dim(Color.WHITE, 0.35), 24, true, on)


func _draw() -> void:
	var s: StatSample = Stats.smooth
	var frame := Palette.color("frame")
	var light := Palette.color("light")
	var magi := Palette.color("magi")
	var alarm := Palette.color("alarm")
	var core := Palette.color("core")
	var breath := Palette.breath()

	var up := maxf(s.uptime, 0.0)
	var days := int(up / 86400.0)
	var hours := int(fmod(up, 86400.0) / 3600.0)
	var mins := int(fmod(up, 3600.0) / 60.0)
	var r := _radius()

	label(Vector2(0.0, 2.0), "%03d : %02d : %02d" % [days, hours, mins], Palette.dim(magi, 0.8 + 0.2 * breath), HORIZONTAL_ALIGNMENT_CENTER, 20)
	label(Vector2(0.0, 18.0), "D          H          M", Palette.dim(frame, 0.6), HORIZONTAL_ALIGNMENT_CENTER, 8)

	var tier := clampi(s.thermal, 0, 3)
	var word_color: Color = [Palette.dim(light, 0.55), Palette.dim(core, 0.8), Palette.emit(alarm, 0.4), Palette.emit(alarm, 0.9)][tier]
	label(Vector2(0.0, r + 22.0), THERMAL_WORDS[tier], word_color, HORIZONTAL_ALIGNMENT_CENTER)

	draw_caption("SYS", "THERMAL %d" % tier, frame, light)

