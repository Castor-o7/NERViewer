extends Node
## Does the glow survive a transparent window? Renders the ramp scenario in
## desktop mode and reads the alpha channel along a ray from the outer CPU
## ring outward, where only bloom lives. Run windowed, not headless:
##   Godot --path game res://tools/alpha_probe.tscn


func _ready() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	main.set_desktop(true)
	main.set_minimal(true, true)
	var syn := SyntheticStatSource.new()
	Stats.use(syn)
	syn.stop()
	syn.set_scenario("ramp")
	syn.seek(30.0)
	Stats.reset_history()
	syn.backfill(180.0)
	Stats.settle()
	for i in 3:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var scale := img.get_width() / 1440.0
	var center := Vector2(720.0, 450.0) * scale
	var ring: Node2D = main.core_ring
	var r_arc: float = ring.outer_radius * ring.scale.x * scale
	print("image %dx%d, format %d, scale %.2f" % [img.get_width(), img.get_height(), img.get_format(), scale])
	# Sample along the ray at 45 degrees (through a P-core arc), from the arc outward.
	var d := Vector2.from_angle(deg_to_rad(-45.0))
	var halo_alpha := 0.0
	var halo_n := 0
	for px in range(0, 60, 4):
		var p := center + d * (r_arc + px * scale)
		var c := img.get_pixelv(Vector2i(p))
		print("  +%2d px  rgba %.2f %.2f %.2f  a=%.2f" % [px, c.r, c.g, c.b, c.a])
		if px >= 4 and px <= 24:  # bloom only; the scale ring starts near +30
			halo_alpha += c.a
			halo_n += 1
	var core_r: float = ring.core_radius * ring.scale.x * scale
	print("core glow profile (alpha), from the triangle's edge outward:")
	var line := "  "
	var last_a := 1.0
	var monotone := true
	for px in range(0, 100, 10):  # stop short of the inner ring
		var c := img.get_pixelv(Vector2i(center + Vector2.from_angle(deg_to_rad(20.0)) * (core_r + 14.0 * scale + px * scale)))
		line += "+%d:%.2f  " % [px, c.a]
		if c.a > last_a + 0.02:
			monotone = false
		last_a = c.a
	print(line)
	print("  monotone: %s, reaches zero: %s" % [monotone, last_a < 0.01])
	var far := img.get_pixelv(Vector2i(center + d * (r_arc + 200.0 * scale)))
	print("far background a=%.2f" % far.a)
	var ok := halo_n > 0 and halo_alpha / halo_n > 0.05 and far.a < 0.05
	print("alpha_probe: %s (mean bloom alpha %.2f)" % ["green" if ok else "RED: the glow pass writes color but no alpha", halo_alpha / maxf(halo_n, 1)])
	img.save_png(ProjectSettings.globalize_path("res://../screenshots/alpha_probe.png"))
	get_tree().quit(0 if ok else 1)

