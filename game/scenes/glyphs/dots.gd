extends Glyph
## Load average as three sparse dot traces over the last three minutes:
## 1, 5 and 15 minutes, each at its own cadence so the slow ones are
## sparser. Height is load over core count, so 1.0 is every core busy.


func _draw() -> void:
	draw_backing()
	var s: StatSample = Stats.smooth
	var frame := Palette.color("frame")
	var light := Palette.color("light")
	var cool := Palette.color("cool")
	var h := half()
	var inner := Rect2(-h.x + 30.0, -h.y + 26.0, size.x - 50.0, size.y - 46.0)
	var cores := maxi(s.cpu_perf_cores + s.cpu_eff_cores, 1)

	for f in [0.5, 1.0]:
		var y: float = inner.end.y - f * inner.size.y
		draw_line(Vector2(inner.position.x, y), Vector2(inner.end.x, y), Palette.dim(frame, 0.14), 1.0, true)
		label(Vector2(inner.position.x - 6.0, y + 4.0), str(int(cores * f)), Palette.dim(frame, 0.6), HORIZONTAL_ALIGNMENT_RIGHT, 9)
	for m in [1, 2]:
		var x: float = inner.end.x - inner.size.x * m / 3.0
		draw_line(Vector2(x, inner.position.y), Vector2(x, inner.end.y), Palette.dim(frame, 0.14), 1.0, true)
	draw_line(Vector2(inner.position.x, inner.end.y), Vector2(inner.end.x, inner.end.y), Palette.dim(frame, 0.3), 1.0, true)

	_draw_trace("load1", light, 3, inner, cores)
	_draw_trace("load5", cool, 6, inner, cores)
	_draw_trace("load15", frame, 12, inner, cores)

	draw_brackets(Palette.dim(frame, 0.85))
	draw_ruler(h.y - 8.0, Palette.dim(frame, 0.35), 24)
	draw_caption("LOAD  3 MIN", "%.2f   %.2f   %.2f" % [s.load.x, s.load.y, s.load.z], frame, light)


func _draw_trace(key: String, color: Color, stride: int, inner: Rect2, cores: int) -> void:
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
		draw_circle(Vector2(x, y), 1.6, Palette.emit(color, 0.15 + 0.6 * v))
		i -= stride

