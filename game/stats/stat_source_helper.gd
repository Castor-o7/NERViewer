class_name HelperStatSource
extends StatSource
## Spawns yggstat and reads one JSON sample per line off a thread.
## When the helper is missing, exits or stalls this emits `failed` with
## the reason, and Stats shows NO SIGNAL and starts a fresh one later. On
## macOS yggstat is the compiled Swift helper; on Linux it is
## helper/yggstat.py, copied without its extension and made executable by
## helper/build.sh, so the path and the JSON are the same on both.

const HELPER := "res://bin/yggstat"
const INTERVAL_MS := 500
## A helper that is alive but silent this long is stalled: SIGSTOPped,
## cgroup-frozen, or stuck in a sensor read. Counted from the spawn too, so
## one that never says a word trips it.
const STALL_MS := 6 * INTERVAL_MS
## A stall's report waits this long for the killed helper's stderr, which
## holds the traceback that stalled it; not longer, as a helper stuck in
## the kernel dies only when its read returns.
const TAIL_WAIT_MS := 1000

## What the reader thread hands the main thread. The reader touches only
## this, never the node, which frees itself once Stats has moved on.
class Link extends RefCounted:
	var proc: Dictionary
	var mutex := Mutex.new()
	var lines := PackedStringArray()
	var closed := false
	var tail := ""
	## Enough stderr to hold a whole traceback's last line.
	const TAIL_BYTES := 4096

	func _init(p: Dictionary) -> void:
		proc = p

	## The reader. Owns its pipes: the main thread never closes them under
	## a blocked read, and a kill ends the loop by closing the far end.
	## Static and handed its link, so the thread holds the link alive
	## whatever becomes of the node.
	static func run(link: Link) -> void:
		var proc := link.proc
		var mutex := link.mutex
		var pipe: FileAccess = proc["stdio"]
		while pipe.is_open():
			var line := pipe.get_line()
			if line.is_empty():
				# A pipe's end is never eof_reached() in Godot 4.7: get_line()
				# returns "" and get_error() goes to ERR_FILE_CANT_READ.
				if pipe.eof_reached() or pipe.get_error() != OK:
					break
				OS.delay_msec(10)
				continue
			mutex.lock()
			link.lines.append(line)
			mutex.unlock()
		pipe.close()
		# Why it died or stalled (a traceback, `env: python3: No such
		# file`) is on stderr. Read only now: the reads block until the
		# helper is gone, and it writes too little there to fill the pipe
		# while it runs.
		var last := ""
		var err: FileAccess = proc.get("stderr")
		if err and err.is_open():
			last = _last_line(err)
			err.close()
		mutex.lock()
		link.tail = last
		link.closed = true
		mutex.unlock()

	## The last line on stderr. Read to the end keeping a rolling tail: one
	## get_buffer is one read(), which on a helper that printed a few
	## tracebacks stops mid-way, well short of the exception line.
	static func _last_line(err: FileAccess) -> String:
		var tail := PackedByteArray()
		while true:
			var chunk := err.get_buffer(TAIL_BYTES)
			if chunk.is_empty():
				break
			tail.append_array(chunk)
			if tail.size() > TAIL_BYTES:
				tail = tail.slice(tail.size() - TAIL_BYTES)
		# Cut on bytes, so a tail that starts mid-character decodes cleanly.
		var end := tail.size()
		while end > 0 and tail[end - 1] <= 32:
			end -= 1
		var start := end
		while start > 0 and tail[start - 1] != 10:
			start -= 1
		while start < end and (tail[start] & 0xC0) == 0x80:
			start += 1
		return tail.slice(start, end).get_string_from_utf8().strip_edges()


var _proc: Dictionary = {}
var _link: Link
## The reader, kept past a stop until it has finished. It can stay blocked
## for as long as a kill takes to land (a process in a kernel read dies
## when the read returns), and joining it then would hang the HUD.
var _thread: Thread
## Children to reap: the helper, and the /bin/kill sent to it.
var _pids: Array[int] = []
var _running := false
var _retired := false
var _last_ms := 0
var _tick_ms := 0
## When a stall was cut off; 0 when none is waiting to be reported.
var _stalled_ms := 0


func source_name() -> String:
	return "yggstat"


## In the editor the helper sits in the project's bin/. In an exported
## app it sits beside the executable: inside Contents/MacOS on macOS,
## beside NERViewer.x86_64 in dist/linux on Linux.
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
		failed.emit("could not spawn helper at %s" % path)
		return
	_running = true
	_last_ms = Time.get_ticks_msec()
	_tick_ms = _last_ms
	_link = Link.new(_proc)
	_thread = Thread.new()
	_thread.start(Link.run.bind(_link))


func _on_line(line: String) -> void:
	var d = JSON.parse_string(line)
	if d is Dictionary:
		_last_ms = Time.get_ticks_msec()
		sample.emit(StatSample.from_json(d))


func _on_closed(tail: String) -> void:
	var reason := "helper exited"
	var code := OS.get_process_exit_code(_proc["pid"])  # also reaps it
	if code >= 0:
		reason += " (%d)" % code
	if not tail.is_empty():
		reason += ": " + tail
	_abandon(reason)


func _process(_dt: float) -> void:
	# Before _reap, which drops the link once the reader is done.
	if _stalled_ms > 0:
		_report_stall()
	_reap()
	if not _running:
		if _retired and _thread == null:
			queue_free()
		return
	_link.mutex.lock()
	var lines := _link.lines
	_link.lines = PackedStringArray()
	var closed := _link.closed
	var tail := _link.tail
	_link.mutex.unlock()
	for line in lines:
		_on_line(line)
	if closed:
		_on_closed(tail)
		return
	var now := Time.get_ticks_msec()
	# A frame this late means the HUD hitched, not the helper: its lines
	# are still queued behind the hitch.
	if now - _tick_ms > STALL_MS / 2:
		_last_ms = now
	_tick_ms = now
	if now - _last_ms > STALL_MS:
		_let_go()
		_stalled_ms = maxi(now, 1)


func _report_stall() -> void:
	var tail := ""
	if _link:
		_link.mutex.lock()
		var closed := _link.closed
		tail = _link.tail
		_link.mutex.unlock()
		if not closed and Time.get_ticks_msec() - _stalled_ms < TAIL_WAIT_MS:
			return
	_stalled_ms = 0
	failed.emit("helper stalled" + (": " + tail if not tail.is_empty() else ""))


## Stop without waiting on the reader, then say why.
func _abandon(reason: String) -> void:
	_let_go()
	failed.emit(reason)


## Kill the helper; its reader is joined later, by _reap. SIGKILL, so a
## stopped process dies too; its pipe then closes and the reader ends by
## itself. Sent by /bin/kill, not OS.kill: OS.kill waits for the death
## (waitpid, os_unix.cpp), which for a helper stuck in the kernel is a
## hung HUD.
func _let_go() -> void:
	_running = false
	var pid := int(_proc.get("pid", 0))
	_proc = {}
	if pid > 0 and OS.is_process_running(pid):
		var killer := OS.create_process("/bin/kill", ["-KILL", str(pid)])
		if killer > 0:
			_pids.append_array([pid, killer])
		else:
			OS.kill(pid)  # no /bin/kill: block rather than leave it running
	_reap()


## Join the reader once it has finished and reap the children, so neither
## threads nor zombies pile up across restarts.
func _reap() -> void:
	# is_process_running reaps a finished child (waitpid WNOHANG).
	for j in range(_pids.size() - 1, -1, -1):
		if not OS.is_process_running(_pids[j]):
			_pids.remove_at(j)
	# Only once stopped: a running reader's last lines and exit are
	# still to be read off its link.
	if not _running and _thread and not _thread.is_alive() and _pids.is_empty():
		_thread.wait_to_finish()
		_thread = null
		_link = null


func stop() -> void:
	_stalled_ms = 0  # moved on; nobody is waiting for why
	_let_go()


## Replaced by another source: this node frees itself once its reader is
## joined, since freeing it under a running thread is not safe.
func retire() -> void:
	stop()
	_retired = true


func _exit_tree() -> void:
	stop()
	# Quitting (a retired node has joined its reader before it frees
	# itself). A GDScript thread still running as the engine tears down
	# crashes it, so this waits: for the killed helper's pipe to close,
	# a few ms, or as long as a helper stuck in the kernel takes to die.
	if _thread:
		_thread.wait_to_finish()
		_thread = null
