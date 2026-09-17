extends Glyph
## Network as two curves over the last three minutes, log-scaled, with a
## dot every few samples. rx in the cool accent, tx in the warm one. At a
## trickle both lie flat and faint.

const CEILING := 1.0e8
const DOT_EVERY := 12


const GRID := [[1.0e3, "1K"], [1.0e6, "1M"], [1.0e8, "100M"]]


## The grid and the curves follow the history, so they are a data layer,
## painted when a sample lands; _draw keeps the text and runs when the
## caption changes.
func _ready() -> void:
	super()
	add_data_layer(_paint_curves)
	add_frame_layer(_paint_frame)


func _inner() -> Rect2:
	var h := half()
	return Rect2(-h.x + 44.0, -h.y + 26.0, size.x - 64.0, size.y - 46.0)


func _caption() -> String:
	var s: StatSample = Stats.smooth
	return "RX %s   TX %s" % [fmt_bytes(s.net_rx_bps), fmt_bytes(s.net_tx_bps)]


func _live_key() -> Variant:
	return _caption()


func _draw() -> void:
	var frame := Palette.color("frame")
	var inner := _inner()
	for pair in GRID:
		var y: float = inner.end.y - Stats.log_norm(pair[0], CEILING) * inner.size.y
		label(Vector2(inner.position.x - 6.0, y + 4.0), pair[1], Palette.dim(frame, 0.6), HORIZONTAL_ALIGNMENT_RIGHT, 9)
	draw_caption("NET  3 MIN", _caption(), frame, Palette.color("light"))


func _paint_frame(on: Layer) -> void:
	draw_brackets(Palette.dim(Color.WHITE, 0.85), 18.0, on)
	draw_ruler(half().y - 8.0, Palette.dim(Color.WHITE, 0.35), 60, true, on)


func _paint_curves(on: Layer) -> void:
	var frame := Palette.color("frame")
	var inner := _inner()
	# Log grid.
	for pair in GRID:
		var y: float = inner.end.y - Stats.log_norm(pair[0], CEILING) * inner.size.y
		on.draw_line(Vector2(inner.position.x, y), Vector2(inner.end.x, y), Palette.dim(frame, 0.14), 1.0, true)
	# Minute dividers.
	for m in [1, 2]:
		var x: float = inner.end.x - inner.size.x * m / 3.0
		on.draw_line(Vector2(x, inner.position.y), Vector2(x, inner.end.y), Palette.dim(frame, 0.14), 1.0, true)
	on.draw_line(Vector2(inner.position.x, inner.end.y), Vector2(inner.end.x, inner.end.y), Palette.dim(frame, 0.3), 1.0, true)
	_draw_curve(on, "net_rx_bps", Palette.color("cool"), inner)
	_draw_curve(on, "net_tx_bps", Palette.color("core"), inner)


func _draw_curve(on: Layer, key: String, color: Color, inner: Rect2) -> void:
	var hist: History = Stats.history[key]
	var n := hist.size()
	if n < 2:
		return
	var cap := hist.capacity()
	var pts := PackedVector2Array()
	for i in n:
		var x := inner.end.x - (n - 1 - i) * inner.size.x / (cap - 1)
		var y := inner.end.y - Stats.log_norm(hist.at(i), CEILING) * inner.size.y
		pts.append(Vector2(x, y))
	var latest := Stats.log_norm(hist.latest(), CEILING)
	# The line always carries a soft halo; a real transfer brightens it.
	# The dots draw none: thirty stacked halos on one line become a cloud.
	halo_polyline(pts, color, 1.5, 0.3 + 0.5 * clampf((latest - 0.3) / 0.7, 0.0, 1.0), on)
	on.draw_polyline(pts, Palette.emit(color, 0.03 + 0.4 * latest), 1.5, true)
	var dot := Palette.emit(color, 0.15 + 0.45 * latest)
	var i := n - 1
	while i >= 0:
		on.draw_circle(pts[i], 1.8, dot)
		i -= DOT_EVERY

