extends Node2D
## The piece. The composition is laid out in a fixed 1440x900 space that
## the window scales; the ground is the palette's ground color; a quiet
## status line says where the numbers come from.
##
## Keys: Tab cycles synthetic scenarios, A the synthetic architectures
## (the core glyph as another CPU would draw it); both only in synthetic
## mode, which is never a fallback: start it with `-- --synthetic` or
## `-- --arch=<name>`. P cycles the palettes, M toggles minimalist mode
## (the sigil alone), B toggles desktop mode (no ground, no border,
## floating on the desktop), S saves a screenshot (screenshots/ beside the
## project in the editor, the Pictures folder in an export), G cycles the
## smoked-glass backing behind each panel in desktop mode, Q or Escape
## quits. In desktop mode, drag anywhere to move the window. Mode, palette
## and window position persist; a position on no connected screen is not
## restored, and the window shrinks to fit a screen smaller than it.
##
## Docked: another app (the Yggdrasil System cockpit) can write
## user://dock.cfg with a screen rect; while that file exists the piece is
## the sigil alone, filling that rect, borderless and on top. When the
## file goes away the piece returns to its own prefs. Nothing about
## docking is saved. The file may also say `hidden = true`: the cockpit's
## HUD is stowed, so the docked sigil stows with it (drawn as nothing and
## letting clicks through) until the key goes false or the file goes away.
## macOS also hides the whole app through System Events; Linux has no such
## thing, so there the key is the only way.
##
## Linux runs under X11 (XWayland on a Wayland desktop; project.godot sets
## display_server/driver.linuxbsd), because Godot's Wayland backend can
## neither keep a window on top nor place it: the dock rect is in global
## desktop pixels, which X11 window positions match at scale 1. Dragging
## there is handed to the window manager, which moves the window itself.

const SMALL := 10
const FADE := 0.6
const CENTER := Vector2(720.0, 450.0)
const MINIMAL_SCALE := 1.25

@onready var ground: ColorRect = $Ground
@onready var status: Label = $Status
@onready var header: Label = $Header
@onready var core_ring: Node2D = $Composition/CoreRing
@onready var environment: WorldEnvironment = $Environment

const PREFS := "user://prefs.cfg"
## 30 is the floor. A 15 fps rest over the desktop was tried on 2026-09-10
## and read as harsh; the rate is not a lever for cost.
const FPS_AWAKE := 30
const FPS_MINIMIZED := 3
const DESIGN := Vector2i(1440, 900)
const DOCK_FILE := "user://dock.cfg"
const DOCK_POLL := 0.2
## Design units of the square the sigil fills when docked: the scale ring
## sits at radius 236, the core halo a little past it.
const DOCK_DIAMETER := 520
## How long a macOS ps answer about the cockpit's pid stands.
const PS_TTL_MS := 2000
## Least overlap, in pixels, with a connected screen for a saved position
## to count as on it: enough of the window to grab or see.
const ON_SCREEN_AREA := 64 * 64

var minimal := false
var desktop := false
var backing := 0
var docked := false
## Tools that render the piece set this off before adding it, so a live
## cockpit's dock file cannot shrink their frame.
var dockable := true
var _dock_text := ""
var _dock_program := ""
## The cockpit that wrote the dock file, watched while docked.
var _dock_pid := 0
var _dock_timer := DOCK_POLL
var _core_home := Vector2.ZERO
var _tween: Tween
var _dragging := false
## Docked and stowed with the cockpit's HUD: drawn as nothing.
var stowed := false
## Where the window was when prefs were last saved; Linux saves again when
## the window manager has moved it (see _process and _unhandled_input).
var _saved_position := Vector2i.ZERO
## "pid|program" -> [alive, ticks_msec] for the macOS ps check; one entry,
## the cockpit of the moment.
static var _ps_cache := {}


func _ready() -> void:
	Palette.changed.connect(_apply_palette)
	Stats.source_changed.connect(func(_n: String) -> void: _update_status())
	Stats.status_changed.connect(_update_status)
	# This runs all day: cap the frame rate and let the process sleep
	# between frames instead of spinning.
	Engine.max_fps = FPS_AWAKE
	OS.low_processor_usage_mode = true
	_core_home = core_ring.position
	_fit_to_screen(true)
	_load_prefs()
	_apply_palette()
	_update_status()
	_poll_dock()


## Desktop mode: the window loses its ground, border and title bar and the
## glyphs composite straight onto the desktop, always on top.
func set_desktop(on: bool, save := true) -> void:
	desktop = on
	var win := get_window()
	win.transparent = on
	win.borderless = on
	win.always_on_top = on
	ground.visible = not on
	# The HDR glow pass writes color without alpha. Over the desktop that
	# leaks through as banded discs, so desktop mode turns it off and the
	# drawn halos are the only glow.
	environment.environment.glow_enabled = not on
	Palette.halo = on
	Palette.backing_alpha = Palette.BACKING_LEVELS[backing] if on else 0.0
	if save:
		_save_prefs()


func set_backing(level: int) -> void:
	backing = clampi(level, 0, Palette.BACKING_LEVELS.size() - 1)
	Palette.backing_alpha = Palette.BACKING_LEVELS[backing] if desktop else 0.0
	_save_prefs()


func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS) != OK:
		return
	Palette.set_theme(str(cfg.get_value("look", "palette", Palette.theme_name)))
	backing = int(cfg.get_value("look", "backing", 0))
	if bool(cfg.get_value("look", "minimal", false)):
		set_minimal(true, true)
	if bool(cfg.get_value("look", "desktop", false)):
		set_desktop(true)
	var pos = cfg.get_value("window", "position", null)
	if pos is Vector2i:
		if _on_a_screen(Rect2i(pos, get_window().size)):
			get_window().position = pos
			# A framed window is meant to be seen whole; a desktop-mode one
			# is clear at its edges and may hang over one on purpose.
			_fit_to_screen(false, not desktop)
		else:
			# Saved on a monitor that is gone: borderless in desktop mode,
			# it would be out of reach for good. Centre it and keep that.
			_fit_to_screen(true)
			_save_prefs()


## Does enough of `r` lie on some connected screen to see and grab?
## With no screen to ask (headless) it is taken as yes.
static func _on_a_screen(r: Rect2i) -> bool:
	var asked := false
	for i in DisplayServer.get_screen_count():
		var u := DisplayServer.screen_get_usable_rect(i)
		if u.has_area():
			asked = true
			if u.intersection(r).get_area() >= ON_SCREEN_AREA:
				return true
	return not asked


## The design size, or less on a screen too small for it (a 1366x768
## panel, a 1440x900 one under a taskbar); canvas_items stretch scales
## the composition, content_scale_size stays DESIGN. Centred, or with
## `keep_inside` pulled inside the screen's usable area.
func _fit_to_screen(recenter: bool, keep_inside := true) -> void:
	var win := get_window()
	var u := DisplayServer.screen_get_usable_rect(win.current_screen)
	if u.size.x <= 0 or u.size.y <= 0:
		return  # headless: no screen to fit
	var k := minf(1.0, minf(u.size.x * 0.95 / DESIGN.x, u.size.y * 0.95 / DESIGN.y))
	win.size = Vector2i(Vector2(DESIGN) * k)
	if recenter:
		win.position = u.position + (u.size - win.size) / 2
	elif keep_inside:
		win.position = win.position.clamp(u.position, u.position + u.size - win.size)


func _save_prefs() -> void:
	if docked:
		return  # the dock's geometry and modes are not ours to keep
	var cfg := ConfigFile.new()
	cfg.set_value("look", "palette", Palette.theme_name)
	cfg.set_value("look", "minimal", minimal)
	cfg.set_value("look", "desktop", desktop)
	cfg.set_value("look", "backing", backing)
	cfg.set_value("window", "position", get_window().position)
	cfg.save(PREFS)
	_saved_position = get_window().position


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_prefs()


## The outer panels: everything in the composition but the sigil.
func _outer_glyphs() -> Array[Node2D]:
	var out: Array[Node2D] = []
	for child in $Composition.get_children():
		if child != core_ring and child is Node2D:
			out.append(child)
	return out


## Minimalist mode: the sigil alone, centered and a little larger. The
## panels fade rather than vanish; the piece never cuts.
func set_minimal(on: bool, instant := false) -> void:
	minimal = on
	_save_prefs()
	if _tween:
		_tween.kill()
	var target_pos := CENTER if on else _core_home
	var target_scale := Vector2.ONE * (MINIMAL_SCALE if on else 1.0)
	var target_alpha := 0.0 if on else 1.0
	if instant:
		core_ring.position = target_pos
		core_ring.scale = target_scale
		for g in _outer_glyphs():
			g.modulate.a = target_alpha
			g.visible = not on
		header.visible = not on
		return
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(core_ring, "position", target_pos, FADE)
	_tween.tween_property(core_ring, "scale", target_scale, FADE)
	header.visible = true
	_tween.tween_property(header, "modulate:a", target_alpha, FADE)
	for g in _outer_glyphs():
		g.visible = true
		_tween.tween_property(g, "modulate:a", target_alpha, FADE)
	if on:
		_tween.chain().tween_callback(func() -> void:
			for g in _outer_glyphs():
				g.visible = false
			header.visible = false)


func _apply_palette() -> void:
	_save_prefs()
	ground.color = Palette.color("ground")
	status.add_theme_color_override("font_color", Palette.dim(Palette.color("cool"), 0.4))
	status.add_theme_font_size_override("font_size", SMALL)
	header.add_theme_color_override("font_color", Palette.dim(Palette.color("frame"), 0.7))
	header.add_theme_font_size_override("font_size", SMALL)


func _update_status() -> void:
	var name := Stats.source.source_name() if Stats.source else "none"
	status.text = "%s  ·  %s" % [name.to_upper(), Palette.theme_name.to_upper()]
	if Stats.no_signal():
		# The reason as the helper gave it: a path or a Python error.
		status.text += "  ·  NO SIGNAL  ·  " + Stats.status


func _process(dt: float) -> void:
	_dock_timer -= dt
	if _dock_timer <= 0.0:
		_dock_timer = DOCK_POLL
		_poll_dock()
		# A drag handed to the window manager ends without a button release
		# reaching us, so the new position is noticed here instead.
		if OS.get_name() == "Linux" and not docked and get_window().position != _saved_position:
			_save_prefs()
	if Stats.source is SyntheticStatSource:
		_update_status()
	# Minimized, nobody is looking: a few frames a second keep the
	# history current and cost almost nothing.
	var minimized := get_window().mode == Window.MODE_MINIMIZED
	var want := FPS_MINIMIZED if minimized or stowed else FPS_AWAKE
	if Engine.max_fps != want:
		Engine.max_fps = want


## Docking. The file is polled five times a second and its whole text is
## compared with the last one read, so rewriting the same rect costs
## nothing. Comparing mtime and size was not enough: mtime has one-second
## resolution, and two rects of the same length written within one second
## (a mid-ease rect, then the final one) left the sigil off its disc. The
## file is a few hundred bytes; reading it outright is cheaper than a stat
## was worth.
func _poll_dock() -> void:
	if not dockable:
		return
	var exists := FileAccess.file_exists(DOCK_FILE)
	var text := FileAccess.get_file_as_string(DOCK_FILE) if exists else ""
	if exists and text.strip_edges().is_empty():
		return  # caught mid-write (a cockpit from before the atomic rename)
	if text == _dock_text:
		# A cockpit that crashed or was killed leaves its file behind
		# unchanged, and the sigil would float on top of an empty desktop.
		# /proc is cheap enough for every poll; macOS's ps answer is cached.
		if not (docked and _dock_pid > 0 and not _pid_alive(_dock_pid, _dock_program)):
			return
	_dock_text = text
	if text.is_empty():
		set_docked(false, Rect2i())
		return
	var cfg := ConfigFile.new()
	if cfg.parse(text) != OK:
		# Caught mid-write; the next poll reads it whole.
		_dock_text = ""
		return
	var rect = cfg.get_value("dock", "rect", null)
	var pid := int(cfg.get_value("dock", "pid", 0))
	_dock_pid = pid
	_dock_program = str(cfg.get_value("dock", "program", ""))
	if pid > 0 and not _pid_alive(pid, _dock_program):
		# The cockpit died without cleaning up; the file is stale.
		set_docked(false, Rect2i())
		return
	if rect is Rect2i and rect.size.x > 0 and rect.size.y > 0:
		print("docked to ", rect)
		set_docked(true, rect)
		set_stowed(bool(cfg.get_value("dock", "hidden", false)))


## Is the cockpit that wrote the dock file still alive? Godot 4.7's
## OS.is_process_running answers only for its own children (it is waitpid
## underneath, and logs an error and reports any other pid as gone;
## verified on Linux 2026-09-28), and the cockpit is never one, so the
## piece would never dock. Linux asks /proc, macOS asks /bin/ps. Either
## way the process must still be the cockpit's program (newer cockpits
## write it), so a pid recycled after a crash does not count.
static func _pid_alive(pid: int, program: String = "") -> bool:
	match OS.get_name():
		"Linux":
			return _proc_alive(pid, program)
		"macOS":
			return _ps_alive(pid, program)
	return OS.is_process_running(pid)


## The cockpit writes `program` as its resolved executable's name (Godot
## reads it through /proc/self/exe), and argv[0] is whatever symlink or
## launcher started it, so the exe link is asked first. Under hidepid, or
## for another user, the link is unreadable and the command line decides.
## Read through a handle: proc files report a length of 0.
static func _proc_alive(pid: int, program: String) -> bool:
	var f := FileAccess.open("/proc/%d/cmdline" % pid, FileAccess.READ)
	if f == null:
		return false
	if program.is_empty():
		return true
	var d := DirAccess.open("/proc/%d" % pid)
	if d and d.is_link("exe") and d.read_link("exe").trim_suffix(" (deleted)").get_file() == program:
		return true
	var raw := f.get_buffer(4096)
	for i in raw.size():
		if raw[i] == 0:
			raw[i] = 32  # argv is NUL-separated
	return program in raw.get_string_from_utf8()


## ps costs 10-20 ms, so an answer stands for PS_TTL_MS: one spawn per
## dock-file change and at most one every two seconds while docked. ps
## prints the full .../Contents/MacOS/<program> path, so the name matches
## as a substring; its exit code is non-zero once the pid is gone. Not yet
## run on a Mac (docs/mac-checklist.md item 7).
static func _ps_alive(pid: int, program: String) -> bool:
	var key := "%d|%s" % [pid, program]
	var now := Time.get_ticks_msec()
	var hit = _ps_cache.get(key)
	if hit and now - int(hit[1]) < PS_TTL_MS:
		return hit[0]
	var out := []
	# stderr stays out of `out`, so an error text never passes for a command.
	var code := OS.execute("/bin/ps", ["-ww", "-p", str(pid), "-o", "command="], out, false)
	var cmd := str(out[0]).strip_edges() if not out.is_empty() else ""
	var alive := code == 0 and not cmd.is_empty() and (program.is_empty() or program in cmd)
	_ps_cache = {key: [alive, now]}
	return alive


func set_docked(on: bool, rect: Rect2i) -> void:
	var win := get_window()
	if on:
		docked = true
		if _tween:
			_tween.kill()
		win.transparent = true
		win.borderless = true
		win.always_on_top = true
		ground.visible = false
		header.visible = false
		status.visible = false
		for g in _outer_glyphs():
			g.visible = false
		environment.environment.glow_enabled = false
		Palette.halo = true
		Palette.backing_alpha = 0.0
		# Off the Mac: a hairline keeps its Mac weight in pixels at this
		# dock's scale (hair 1.67 at 197 px). The Mac keeps 1.0.
		# Only below the Mac's density: a dock as dense as a Retina one
		# draws exactly as the Mac does, readouts and all.
		var need := Palette.MAC_HAIR_PX * DOCK_DIAMETER / float(maxi(mini(rect.size.x, rect.size.y), 1))
		Palette.lift = OS.get_name() != "macOS" and need > 1.0
		Palette.hair = need if Palette.lift else 1.0
		win.content_scale_size = Vector2i(DOCK_DIAMETER, DOCK_DIAMETER)
		core_ring.position = Vector2(DOCK_DIAMETER, DOCK_DIAMETER) * 0.5
		core_ring.scale = Vector2.ONE
		core_ring.captions = false
		win.size = rect.size
		win.position = rect.position
		return
	if not docked:
		return
	docked = false
	Palette.lift = false
	Palette.hair = 1.0
	set_stowed(false)
	win.content_scale_size = DESIGN
	_fit_to_screen(true)
	status.visible = true
	header.visible = true
	core_ring.position = _core_home
	core_ring.scale = Vector2.ONE
	core_ring.captions = true
	for g in _outer_glyphs():
		g.visible = true
		g.modulate.a = 1.0
	minimal = false
	# Back to a plain window without saving: the prefs on disk are the
	# ones from before docking, and _load_prefs re-applies them.
	set_desktop(false, false)
	_load_prefs()
	_apply_palette()


## Stowed with the cockpit's HUD. Only ever while docked, where the sigil
## is all there is to see: hiding it leaves a transparent window, and mouse
## passthrough lets clicks fall to whatever is under it. The window itself
## stays mapped, so showing it again needs no placing, and a few frames a
## second keep the history current meanwhile.
func set_stowed(on: bool) -> void:
	on = on and docked
	if on == stowed:
		return
	stowed = on
	core_ring.visible = not on
	get_window().mouse_passthrough = on
	print("stowed" if on else "unstowed")


## A borderless window has nothing to grab, so the whole piece is the handle.
## On Linux the window manager does the moving (start_drag): under X11 the
## pointer's relative motion is measured against a window that is itself
## moving, and the window jitters and lags behind the cursor.
func _unhandled_input(event: InputEvent) -> void:
	if OS.get_name() == "Linux":
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
				and event.pressed and desktop and not docked:
			get_window().start_drag()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed and desktop and not docked
		if not event.pressed:
			_save_prefs()
	elif event is InputEventMouseMotion and _dragging:
		get_window().position += Vector2i(event.relative)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	match event.keycode:
		KEY_TAB:
			if Stats.source is SyntheticStatSource:
				Stats.source.next_scenario()
		KEY_A:
			if Stats.source is SyntheticStatSource:
				Stats.source.next_arch()
		KEY_P:
			Palette.next()
		KEY_M:
			if not docked:
				set_minimal(not minimal)
		KEY_B:
			if not docked:
				set_desktop(not desktop)
		KEY_G:
			if not docked:
				set_backing((backing + 1) % Palette.BACKING_LEVELS.size())
		KEY_Q, KEY_ESCAPE:
			_save_prefs()
			get_tree().quit()
		KEY_S:
			_save_screenshot()


## In the editor, screenshots/manual.png beside the project as always. An
## export's res:// is its own folder (inside the signed bundle on a Mac),
## so it saves a dated file to Pictures, or user:// without one.
func _save_screenshot() -> void:
	var dir := ""
	var file := "manual.png"
	if OS.has_feature("editor"):
		dir = ProjectSettings.globalize_path("res://../screenshots")
	else:
		dir = OS.get_system_dir(OS.SYSTEM_DIR_PICTURES)
		if dir.is_empty():
			dir = ProjectSettings.globalize_path("user://screenshots")
		file = "nerviewer_%s.png" % Time.get_datetime_string_from_system().replace(":", "-")
	DirAccess.make_dir_recursive_absolute(dir)  # a fresh clone has no screenshots/
	var path := dir.path_join(file)
	var err := get_viewport().get_texture().get_image().save_png(path)
	if err == OK:
		print("saved ", path)
	else:
		push_warning("screenshot not saved (%s): %s" % [error_string(err), path])
