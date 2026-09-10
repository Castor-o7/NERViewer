extends Glyph
## Memory as a ring gauge with an opening at the bottom. Sweep angle =
## used/total; the inner tick ring = wired; the dim band = compressed.
## Pressure warms the sweep from gold toward alarm.


func _draw() -> void:
	draw_backing()
	var s: StatSample = Stats.smooth
	var frame := Palette.color("frame")
	var light := Palette.color("light")
	var core := Palette.color("core")
	var alarm := Palette.color("alarm")
	var breath := Palette.breath()

	var r := minf(size.x, size.y) * 0.5 - 44.0
	var open := deg_to_rad(70.0)
	var start := PI * 0.5 + open * 0.5
	var span := TAU - open
	var total := maxf(float(s.mem_total), 1.0)
	var used_f := clampf(s.mem_used / total, 0.0, 1.0)
	var wired_f := clampf(s.mem_wired / total, 0.0, 1.0)
	var comp_f := clampf(s.mem_compressed / total, 0.0, 1.0)
	var pressure := s.mem_pressure

	# Track and scale.
	draw_arc(Vector2.ZERO, r, start, start + span, 120, Palette.dim(frame, 0.2 + 0.2 * breath), 1.0, true)
	for i in 21:
		var a := start + span * i / 20.0
		var d := Vector2.from_angle(a)
		var len := 8.0 if i % 5 == 0 else 3.5
		draw_line(d * (r + 5.0), d * (r + 5.0 + len), Palette.dim(frame, 0.35 + 0.15 * Palette.breath()), 1.0, true)

	# Compressed: a dim band inside the track.
	if comp_f > 0.002:
		draw_arc(Vector2.ZERO, r - 12.0, start, start + span * comp_f, 64, Palette.dim(core, 0.28), 5.0, true)

	# Wired: the inner tick ring, lit in proportion.
	var ticks := 40
	var lit := int(round(ticks * wired_f))
	for i in ticks:
		var a := start + span * (i + 0.5) / ticks
		var d := Vector2.from_angle(a)
		var c := Palette.dim(light, 0.55) if i < lit else Palette.dim(frame, 0.15)
		draw_line(d * (r - 27.0), d * (r - 21.0), c, 1.0, true)

	# The sweep.
	var warm := clampf((pressure - 0.3) / 0.5, 0.0, 1.0)
	var sweep := core.lerp(alarm, warm)
	var k := lerpf(0.7, 3.0, pressure) * (0.92 + 0.16 * breath)
	var sweep_lit := Color(sweep.r * k, sweep.g * k, sweep.b * k, 1.0)
	var sweep_heat := clampf((pressure - 0.13) / 0.87, 0.0, 1.0)
	halo_arc(Vector2.ZERO, r, start, start + span * used_f, 120, sweep, 2.5, sweep_heat)
	draw_arc(Vector2.ZERO, r, start, start + span * used_f, 120, sweep_lit, 2.5, true)
	var tip := Vector2.from_angle(start + span * used_f) * r
	halo_circle(tip, 2.5, sweep, 0.2 + 0.6 * pressure)
	draw_circle(tip, 2.5, Palette.emit(sweep, 0.2 + 0.6 * pressure))

	# Readouts inside the ring, and pressure in the opening.
	label(Vector2(0.0, -4.0), fmt_gib(s.mem_used), Palette.dim(light, 0.8), HORIZONTAL_ALIGNMENT_CENTER, 20)
	label(Vector2(0.0, 12.0), "OF %s GIB" % fmt_gib(s.mem_total), Palette.dim(frame, 0.7), HORIZONTAL_ALIGNMENT_CENTER)
	label(Vector2(0.0, r + 4.0), "PRESSURE %02d" % int(round(pressure * 100.0)), Palette.dim(sweep, 0.6 + 0.3 * pressure), HORIZONTAL_ALIGNMENT_CENTER)

	draw_brackets(Palette.dim(frame, 0.85))
	draw_caption("MEM", "WIRED %s  COMP %s" % [fmt_gib(s.mem_wired), fmt_gib(s.mem_compressed)], frame, light)

