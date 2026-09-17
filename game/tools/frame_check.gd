extends Node
## The piece at fixed moments, for comparing a drawing change stroke for
## stroke: breath and drift are pinned, the numbers are the synthetic
## ones, so two runs of the same code give the same pixels.
##   Godot --path game res://tools/frame_check.tscn -- --out <dir> [--view docked|window|desktop]
##   Godot --path game --headless res://tools/frame_check.tscn -- --diff <dirA> <dirB>

const RECT := Rect2i(40, 60, 520, 520)
const CASES := [["idle", 40.0, 0.0, 0.0], ["idle", 40.0, 0.37, 1.1], ["ramp", 30.0, 1.0, 2.9], ["spike", 5.6, 0.62, 4.0]]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() == 3 and args[0] == "--diff":
		_diff(args[1], args[2])
		get_tree().quit()
		return
	var out := "."
	var view := "docked"
	for i in args.size() - 1:
		if args[i] == "--out":
			out = args[i + 1]
		if args[i] == "--view":
			view = args[i + 1]
	DirAccess.make_dir_recursive_absolute(out)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.dockable = false
	main.persist = false
	add_child(main)
	OS.low_processor_usage_mode = false  # else a still frame is never drawn and frame_post_draw never fires
	await get_tree().process_frame
	var syn := SyntheticStatSource.new()
	Stats.use(syn)
	syn.stop()
	match view:
		"docked":
			main.set_docked(true, RECT)
		"desktop":
			main.set_desktop(true, false)
			main.set_backing(1)   # smoked glass on, so its place under the strokes is checked
	var ring: Node2D = main.get_node("Composition/CoreRing")
	ring.set_process(false)
	for c in CASES:
		syn.set_scenario(c[0])
		syn.seek(c[1])
		Stats.reset_history()
		syn.backfill(180.0)
		Stats.settle()
		Palette.breath_pin = c[2]
		ring._drift = c[3]
		if ring.has_method("_refresh"):
			ring._refresh()
		else:
			ring._pose()  # the drawing before 2026-09-17's base-class layers
		ring.queue_redraw()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%s_%s_%.2f.png" % [out, view, c[0], c[2]])
	print("frame_check: wrote %d frames to %s" % [CASES.size(), out])
	get_tree().quit()


func _diff(a: String, b: String) -> void:
	for f in DirAccess.get_files_at(a):
		if not f.ends_with(".png"):
			continue
		var ia := Image.load_from_file(a.path_join(f))
		var ib := Image.load_from_file(b.path_join(f))
		if ib == null or ia.get_size() != ib.get_size():
			print("%s: missing or another size" % f)
			continue
		var da := ia.get_data()
		var db := ib.get_data()
		var worst := 0
		var differing := 0
		var total := 0
		for i in da.size():
			var d := absi(da[i] - db[i])
			if d > 0:
				differing += 1
				total += d
				worst = maxi(worst, d)
		print("%s: %d of %d channel values differ, worst by %d of 255, %d in all" % [f, differing, da.size(), worst, total])
