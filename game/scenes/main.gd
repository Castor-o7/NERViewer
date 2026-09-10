extends Node2D
## The piece. The composition is laid out in a fixed 1440x900 space that
## the window scales; the ground is the palette's ground color; a quiet
## status line says where the numbers come from.
##
## Keys: Tab cycles synthetic scenarios, P cycles the palettes,
## M toggles minimalist mode (the sigil alone), B toggles desktop mode
## (no ground, no border, floating on the desktop), S saves a screenshot
## beside the project, G cycles the smoked-glass backing behind each panel
## in desktop mode, Q or Escape quits. In desktop mode, drag anywhere
## to move the window. Mode, palette and window position persist.
##
## Docked: another app (the Yggdrasil System cockpit) can write
## user://dock.cfg with a screen rect; while that file exists the piece is
## the sigil alone, filling that rect, borderless and on top. When the
## file goes away the piece returns to its own prefs. Nothing about
## docking is saved.

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
const FPS_AWAKE := 30
## Over the desktop or docked in the cockpit the piece runs all day, and
## nothing on it moves faster than the breath and the samples arriving:
## half the frames, half the cost (measured 2026-09-09: 30 fps docked was
## 40% of an M2 core, most of it drawing halo arcs and submitting frames).
const FPS_REST := 15
const FPS_MINIMIZED := 3
const DESIGN := Vector2i(1440, 900)
const DOCK_FILE := "user://dock.cfg"
const DOCK_POLL := 1.0
## Design units of the square the sigil fills when docked: the scale ring
## sits at radius 236, the core halo a little past it.
const DOCK_DIAMETER := 520

var minimal := false
var desktop := false
var backing := 0
var docked := false
var _dock_mtime := -1
var _dock_timer := DOCK_POLL
var _core_home := Vector2.ZERO
var _tween: Tween
var _dragging := false


func _ready() -> void:
	Palette.changed.connect(_apply_palette)
	Stats.source_changed.connect(func(_n: String) -> void: _update_status())
	# This runs all day: cap the frame rate and let the process sleep
	# between frames instead of spinning.
	Engine.max_fps = FPS_AWAKE
	OS.low_processor_usage_mode = true
	_core_home = core_ring.position
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
		get_window().position = pos


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


func _process(dt: float) -> void:
	_dock_timer -= dt
	if _dock_timer <= 0.0:
		_dock_timer = DOCK_POLL
		_poll_dock()
	if Stats.source is SyntheticStatSource:
		_update_status()
	# Minimized, nobody is looking: a few frames a second keep the
	# history current and cost almost nothing.
	var minimized := get_window().mode == Window.MODE_MINIMIZED
	var resting := (docked or desktop) and not _dragging
	var want := FPS_MINIMIZED if minimized else (FPS_REST if resting else FPS_AWAKE)
	if Engine.max_fps != want:
		Engine.max_fps = want
		print("fps ", want, " (docked ", docked, ", desktop ", desktop, ")")


## Docking. The file is polled once a second; its modified time is the
## only thing compared, so rewriting the same rect costs nothing.
func _poll_dock() -> void:
	var mtime := FileAccess.get_modified_time(DOCK_FILE) if FileAccess.file_exists(DOCK_FILE) else 0
	if mtime == _dock_mtime:
		return
	_dock_mtime = mtime
	if mtime == 0:
		set_docked(false, Rect2i())
		return
	var cfg := ConfigFile.new()
	if cfg.load(DOCK_FILE) != OK:
		return
	var rect = cfg.get_value("dock", "rect", null)
	var pid := int(cfg.get_value("dock", "pid", 0))
	if pid > 0 and not OS.is_process_running(pid):
		# The cockpit died without cleaning up; the file is stale.
		_dock_mtime = -1
		set_docked(false, Rect2i())
		return
	if rect is Rect2i and rect.size.x > 0 and rect.size.y > 0:
		print("docked to ", rect)
		set_docked(true, rect)


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
	win.content_scale_size = DESIGN
	win.size = DESIGN
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


## A borderless window has nothing to grab, so the whole piece is the handle.
func _unhandled_input(event: InputEvent) -> void:
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
			var path := ProjectSettings.globalize_path("res://../screenshots/manual.png")
			get_viewport().get_texture().get_image().save_png(path)
			print("saved ", path)
