extends Node
## Renders every synthetic scenario at a representative moment, in each
## palette, to screenshots/ beside the project. idle_<palette>.png is the
## Phase 0 exit criterion: hang it on a wall or stay in Phase 0.
##
## Run: /Applications/Godot.app/Contents/MacOS/Godot --path game res://tools/shots.tscn

const MOMENTS := {
	"idle": 40.0,
	"drift": 45.0,
	"ramp": 30.0,
	"spike": 5.6,
	"download": 30.0,
	"pressure": 40.0,
}


func _ready() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.dockable = false
	main.persist = false
	add_child(main)
	await get_tree().process_frame
	var syn := SyntheticStatSource.new()
	Stats.use(syn)
	syn.stop()  # we drive it by hand
	var dir := ProjectSettings.globalize_path("res://../screenshots")
	DirAccess.make_dir_recursive_absolute(dir)
	var written: Array[String] = []
	for palette in Palette.THEMES.keys():
		Palette.set_theme(palette)
		for name in MOMENTS:
			syn.set_scenario(name)
			syn.seek(MOMENTS[name])
			Stats.reset_history()
			syn.backfill(180.0)
			Stats.settle()
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var path := "%s/%s_%s.png" % [dir, name, palette]
			var err := get_viewport().get_texture().get_image().save_png(path)
			if err != OK:
				push_error("could not save %s (%d)" % [path, err])
			else:
				written.append(path)
	# Minimalist mode, idle, both palettes.
	main.set_minimal(true, true)
	syn.set_scenario("idle")
	syn.seek(MOMENTS["idle"])
	Stats.reset_history()
	syn.backfill(180.0)
	Stats.settle()
	for palette in Palette.THEMES.keys():
		Palette.set_theme(palette)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var path := "%s/minimal_%s.png" % [dir, palette]
		if get_viewport().get_texture().get_image().save_png(path) == OK:
			written.append(path)
	main.set_minimal(false, true)
	print("shots: wrote %d files" % written.size())
	for p in written:
		print("  ", p)
	get_tree().quit(0)

