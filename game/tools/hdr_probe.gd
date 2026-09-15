extends Node
## Is the window getting HDR output, and how far past white can this screen
## go right now? Prints and quits. Run windowed, at whatever brightness:
##   Godot --path game res://tools/hdr_probe.tscn
## The headroom is 1.0 at full brightness and grows as the slider comes down.


func _ready() -> void:
	OS.low_processor_usage_mode = false
	for i in 3:
		await RenderingServer.frame_post_draw
	var w := get_window().get_window_id()
	print("hdr_probe: supported %s, requested %s, enabled %s, headroom x%.2f, reference %.0f nits, max %.0f nits, transparent %s" % [
		DisplayServer.window_is_hdr_output_supported(w), DisplayServer.window_is_hdr_output_requested(w),
		DisplayServer.window_is_hdr_output_enabled(w), get_window().get_output_max_linear_value(),
		DisplayServer.window_get_hdr_output_current_reference_luminance(w),
		DisplayServer.window_get_hdr_output_current_max_luminance(w), get_window().transparent])
	get_tree().quit()
