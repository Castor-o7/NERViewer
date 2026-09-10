class_name HelperStatSource
extends StatSource
## Spawns yggstat and reads one JSON sample per line off a thread.
## Phase 1 builds the helper; until then this fails on start and Stats
## falls back to the synthetic source.

const HELPER := "res://bin/yggstat"
const INTERVAL_MS := 500

var _proc: Dictionary = {}
var _thread: Thread
var _running := false


func source_name() -> String:
	return "yggstat"


## In the editor the helper sits in the project's bin/. In an exported
## app it sits beside the executable, inside Contents/MacOS.
static func helper_path() -> String:
	var beside_exe := OS.get_executable_path().get_base_dir().path_join("yggstat")
	if FileAccess.file_exists(beside_exe):
		return beside_exe
	return ProjectSettings.globalize_path(HELPER)


func start() -> void:
	var path := helper_path()
	if not FileAccess.file_exists(path):
		failed.emit("helper missing at %s; run helper/build.sh" % path)
		return
	_proc = OS.execute_with_pipe(path, ["--interval", str(INTERVAL_MS)])
	if _proc.is_empty():
		failed.emit("could not spawn helper")
		return
	_running = true
	_thread = Thread.new()
	_thread.start(_read_loop)


func _read_loop() -> void:
	var pipe: FileAccess = _proc["stdio"]
	while _running and pipe.is_open():
		var line := pipe.get_line()
		if line.is_empty():
			if pipe.eof_reached():
				break
			OS.delay_msec(10)
			continue
		_on_line.call_deferred(line)
	_on_closed.call_deferred()


func _on_line(line: String) -> void:
	var d = JSON.parse_string(line)
	if d is Dictionary:
		sample.emit(StatSample.from_json(d))


func _on_closed() -> void:
	if _running:
		_running = false
		failed.emit("helper exited")


func stop() -> void:
	_running = false
	if _proc.has("pid"):
		OS.kill(_proc["pid"])  # first: unblocks a blocking get_line
	if _proc.has("stdio"):
		_proc["stdio"].close()
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


func _exit_tree() -> void:
	stop()

