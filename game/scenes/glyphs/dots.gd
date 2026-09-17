extends Glyph
## Load average as three sparse dot traces over the last three minutes:
## 1, 5 and 15 minutes, each at its own cadence so the slow ones are
## sparser. Height is load over core count, so 1.0 is every core busy.


## The grid and the traces follow the history, so they are a data layer,
## painted when a sample lands; _draw keeps the text and runs when the
## caption changes.
func _ready() -> void:
	super()
	add_data_layer(_paint_traces)
	add_frame_layer(_paint_frame)


func _inner() -> Rect2:
	var h := half()
	return Rect2(-h.x + 30.0, -h.y + 26.0, size.x - 50.0, size.y - 46.0)


func _cores() -> int:
	return maxi(Stats.raw.cpu_perf_cores + Stats.raw.cpu_eff_cores, 1)


func _caption() -> String:
	var s: StatSample = Stats.smooth
	return "%.2f   %.2f   %.2f" % [s.load.x, s.load.y, s.load.z]


func _live_key() -> Variant:
	return "%s %d" % [_caption(), _cores()]


func _draw() -> void:
	var frame := Palette.color("frame")
	var inner := _inner()
	for f in [0.5, 1.0]:
		var y: float = inner.end.y - f * inner.size.y
		label(Vector2(inner.position.x - 6.0, y + 4.0), str(int(_cores() * f)), Palette.dim(frame, 0.6), HORIZONTAL_ALIGNMENT_RIGHT, 9)
	draw_caption("LOAD  3 MIN", _caption(), frame, Palette.color("light"))


func _paint_frame(on: Layer) -> void:
	draw_brackets(Palette.dim(Color.WHITE, 0.85), 18.0, on)
	draw_ruler(half().y - 8.0, Palette.dim(Color.WHITE, 0.35), 24, true, on)


func _paint_traces(on: Layer) -> void:
	var frame := Palette.color("frame")
	var inner := _inner()
	var cores := _cores()
	for f in [0.5, 1.0]:
		var y: float = inner.end.y - f * inner.size.y
		on.draw_line(Vector2(inner.position.x, y), Vector2(inner.end.x, y), Palette.dim(frame, 0.14), 1.0, true)
	for m in [1, 2]:
		var x: float = inner.end.x - inner.size.x * m / 3.0
		on.draw_line(Vector2(x, inner.position.y), Vector2(x, inner.end.y), Palette.dim(frame, 0.14), 1.0, true)
	on.draw_line(Vector2(inner.position.x, inner.end.y), Vector2(inner.end.x, inner.end.y), Palette.dim(frame, 0.3), 1.0, true)
	_draw_trace(on, "load1", Palette.color("light"), 3, inner, cores)
	_draw_trace(on, "load5", Palette.color("cool"), 6, inner, cores)
	_draw_trace(on, "load15", frame, 12, inner, cores)


func _draw_trace(on: Layer, key: String, color: Color, stride: int, inner: Rect2, cores: int) -> void:
	var hist: History = Stats.history[key]
	var n := hist.size()
	if n == 0:
		return
	var cap := hist.capacity()
	var i := n - 1
	while i >= 0:
		var v := clampf(hist.at(i) / cores, 0.0, 1.0)
		var x := inner.end.x - (n - 1 - i) * inner.size.x / (cap - 1)
		var y := inner.end.y - v * inner.size.y
		on.draw_circle(Vector2(x, y), 1.6, Palette.emit(color, 0.15 + 0.6 * v))
		i -= stride

