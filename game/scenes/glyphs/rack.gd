extends Glyph
## CPU history as two racks of bars, P-cores above E-cores. One column per
## 500 ms sample: the last sixty seconds. Blue at rest, white under load.

const COLUMNS := 120
const ROW_GAP := 12.0
const ROWS := [["P", "cpu_perf"], ["E", "cpu_eff"]]


## The bars follow the history, so they are a data layer, painted when a
## sample lands; _draw keeps the text and runs when the caption changes.
func _ready() -> void:
	super()
	add_data_layer(_paint_bars)
	add_frame_layer(_paint_frame)


func _inner() -> Rect2:
	var h := half()
	return Rect2(-h.x + 26.0, -h.y + 28.0, size.x - 36.0, size.y - 48.0)


func _caption() -> String:
	var s: StatSample = Stats.smooth
	return "P %02d  E %02d" % [int(round(_group_mean(s, true) * 99.0)), int(round(_group_mean(s, false) * 99.0))]


func _live_key() -> Variant:
	return _caption()


func _draw() -> void:
	var frame := Palette.color("frame")
	var inner := _inner()
	var row_h := (inner.size.y - ROW_GAP) * 0.5
	for r in 2:
		var top := inner.position.y + r * (row_h + ROW_GAP)
		label(Vector2(-half().x + 8.0, top + row_h * 0.5 + 4.0), ROWS[r][0], Palette.dim(frame, 0.7))
	draw_caption("CPU  60 S", _caption(), frame, Palette.color("light"))


func _paint_frame(on: Layer) -> void:
	draw_brackets(Palette.dim(Color.WHITE, 0.85), 18.0, on)
	draw_ruler(half().y - 8.0, Palette.dim(Color.WHITE, 0.35), 24, true, on)


func _paint_bars(on: Layer) -> void:
	var frame := Palette.color("frame")
	var light := Palette.color("light")
	var cool := Palette.color("cool")
	var inner := _inner()
	var row_h := (inner.size.y - ROW_GAP) * 0.5
	var col_w := inner.size.x / COLUMNS
	for r in 2:
		var top := inner.position.y + r * (row_h + ROW_GAP)
		var base := top + row_h
		var hist: History = Stats.history[ROWS[r][1]]
		on.draw_line(Vector2(inner.position.x, base), Vector2(inner.end.x, base), Palette.dim(frame, 0.3), 1.0, true)
		var n := hist.size()
		for i in COLUMNS:
			var idx := n - COLUMNS + i
			var x := inner.position.x + (i + 0.5) * col_w
			if idx < 0:
				# The rack exists before the data does.
				on.draw_line(Vector2(x, base), Vector2(x, base - 1.5), Palette.dim(frame, 0.15), 1.0, true)
				continue
			var v := clampf(hist.at(idx), 0.0, 1.0)
			var bar := maxf(v * row_h, 1.5)
			# Bars are dense, so their glow is capped well below the arcs':
			# a hundred adjacent emitters would bloom into a slab.
			var tint := cool.lerp(light, v * 0.85)
			var k := lerpf(0.75, 1.5, v)
			var c := Color(tint.r * k, tint.g * k, tint.b * k, 1.0)
			halo_line(Vector2(x, base), Vector2(x, base - bar), tint, 1.0, clampf((v - 0.4) / 0.6, 0.0, 1.0) * 0.2, on)
			# Columns nearly touch: Godot 4.7 stopped feathering antialiased
			# lines, so the 1.3 px gap that read as one slab in 4.3 showed as
			# stripes; 0.3 px keeps the slab (upgrade, 2026-09-15).
			on.draw_line(Vector2(x, base), Vector2(x, base - bar), c, maxf(col_w - 0.3, 1.0), true)


static func _group_mean(s: StatSample, perf: bool) -> float:
	var n := s.cpu_cores.size()
	var eff := clampi(s.cpu_eff_cores, 0, n)
	var from := eff if perf else 0
	var to := n if perf else eff
	if to <= from:
		return 0.0
	var sum := 0.0
	for i in range(from, to):
		sum += s.cpu_cores[i]
	return sum / (to - from)

