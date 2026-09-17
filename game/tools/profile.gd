extends Node
## Where the cost goes: CPU of this process (ps) over ten seconds of the
## synthetic idle scenario, in a given mode.
##   Godot --path game res://tools/profile.tscn -- --mode <mode>
##   full    the whole piece in its window
##   docked  the sigil alone, as the cockpit docks it
##   nohalo  docked, halos off
##   frozen  docked, drawn once and never again: the engine's own floor
##   tick    docked, the sigil frozen and one dot redrawn each frame: the
##           fixed price of a frame. Variants switch one thing off:
##           tick-no3d (viewport 3D), tick-nohdr (HDR 2D buffers),
##           tick-noenv (the WorldEnvironment), tick-opaque (transparency)

const WARMUP := 3.0
const SECONDS := 10.0
const RECT := Rect2i(40, 60, 335, 335)


func _ready() -> void:
	var mode := "docked"
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--mode" and i + 1 < args.size():
			mode = args[i + 1]
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.dockable = false
	add_child(main)
	await get_tree().process_frame
	var syn := SyntheticStatSource.new()
	Stats.use(syn)
	syn.set_scenario("idle")
	if mode != "full":
		main.set_docked(true, RECT)
	if mode == "nohalo":
		Palette.halo = false
	await get_tree().create_timer(WARMUP).timeout
	if mode == "frozen" or mode.begins_with("tick"):
		main.get_node("Composition/CoreRing").set_process(false)
	if mode.begins_with("tick"):
		add_child(Tick.new())
	match mode:
		"tick-empty":
			main.get_node("Composition").visible = false
		"tick-empty-lean":
			main.get_node("Composition").visible = false
			main.get_node("Environment").queue_free()
			get_viewport().disable_3d = true
			get_viewport().use_hdr_2d = false
		"tick-no3d":
			get_viewport().disable_3d = true
		"tick-nohdr":
			get_viewport().use_hdr_2d = false
		"tick-noenv":
			main.get_node("Environment").queue_free()
		"tick-opaque":
			get_window().transparent = false
			get_viewport().transparent_bg = false
	var cpu0 := _cpu_seconds()
	var t0 := Time.get_ticks_usec()
	var f0 := Engine.get_frames_drawn()
	await get_tree().create_timer(SECONDS).timeout
	var wall := (Time.get_ticks_usec() - t0) / 1e6
	print("profile mode=%-7s fps %.1f  process cpu %.1f%%  canvas items %d  draw calls %d" % [
		mode, (Engine.get_frames_drawn() - f0) / wall, (_cpu_seconds() - cpu0) / wall * 100.0,
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
	get_tree().quit()


class Tick extends Node2D:
	func _process(_dt: float) -> void:
		queue_redraw()
	func _draw() -> void:
		draw_rect(Rect2(2, 2, 1, 1), Color(1, 1, 1, 0.02))


static func _cpu_seconds() -> float:
	var out := []
	OS.execute("/bin/ps", ["-o", "time=", "-p", str(OS.get_process_id())], out)
	if out.is_empty():
		return 0.0
	var s := 0.0
	for p in str(out[0]).strip_edges().split(":"):
		s = s * 60.0 + float(p)
	return s
