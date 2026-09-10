extends Glyph
## Uptime and thermal state. The one place the original MAGI orange lives,
## and the one thing that ticks once a second.

const THERMAL_WORDS := ["NOMINAL", "FAIR", "SERIOUS", "CRITICAL"]


func _draw() -> void:
	draw_backing()
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
	var secs := int(fmod(up, 60.0))

	# The second ring: sixty ticks, lit up to the current second.
	var r := minf(size.x, size.y) * 0.5 - 40.0
	for i in 60:
		var a := -PI * 0.5 + i * TAU / 60.0
		var d := Vector2.from_angle(a)
		var c := Palette.dim(frame, 0.18)
		if i == secs:
			c = Palette.emit(magi, 0.5)
		elif i < secs:
			c = Palette.dim(magi, 0.45 + 0.15 * breath)
		var len := 7.0 if i % 5 == 0 else 4.0
		if i == secs:
			halo_line(d * r, d * (r + len), magi, 1.0, 0.5)
		draw_line(d * r, d * (r + len), c, 1.0, true)
	draw_arc(Vector2.ZERO, r - 3.0, 0.0, TAU, 120, Palette.dim(frame, 0.15 + 0.15 * breath), 1.0, true)

	label(Vector2(0.0, 2.0), "%03d : %02d : %02d" % [days, hours, mins], Palette.dim(magi, 0.8 + 0.2 * breath), HORIZONTAL_ALIGNMENT_CENTER, 20)
	label(Vector2(0.0, 18.0), "D          H          M", Palette.dim(frame, 0.6), HORIZONTAL_ALIGNMENT_CENTER, 8)

	var tier := clampi(s.thermal, 0, 3)
	var word_color: Color = [Palette.dim(light, 0.55), Palette.dim(core, 0.8), Palette.emit(alarm, 0.4), Palette.emit(alarm, 0.9)][tier]
	label(Vector2(0.0, r + 22.0), THERMAL_WORDS[tier], word_color, HORIZONTAL_ALIGNMENT_CENTER)

	draw_brackets(Palette.dim(frame, 0.85))
	draw_ruler(half().y - 8.0, Palette.dim(frame, 0.35), 24)
	draw_caption("SYS", "THERMAL %d" % tier, frame, light)

