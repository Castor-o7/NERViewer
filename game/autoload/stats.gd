extends Node
## "Stats" autoload. Owns whichever source is active, eases toward each
## sample every frame, and keeps history. Glyphs read `smooth` and
## `history` and never touch a source.

signal sampled(s: StatSample)
signal source_changed(name: String)
## `live` or `status` changed.
signal status_changed

## Helper restarts back off 1, 2, 4 ... seconds, to this. The backoff
## starts over only once a helper has run this long, so one that sends a
## few lines and dies each time still backs off.
const RETRY_MAX := 30.0

const HISTORY_LEN := 360  # 3 minutes at 500 ms
## cpu_perf and cpu_eff hold the outer and inner ring groups (see
## StatSample.group_names): P and E on Apple Silicon, each core's first
## and second thread under SMT.
const HISTORY_KEYS := ["cpu_total", "cpu_perf", "cpu_eff", "mem_used", "net_rx_bps", "net_tx_bps", "load1", "load5", "load15"]

## The fast readings (CPU, network) move like a needle with inertia: a
## critically damped spring toward the latest sample, so their velocity
## is continuous and they never overshoot. OMEGA sets the stiffness: at
## 4.5 the needle has covered two thirds of a change when the next sample
## lands half a second later, so it is always gliding, never parked.
## Decided 2026-09-10: first-order easing at 4/s covered 86% of each step
## and then all but stopped, a lurch and a hold twice a second, which the
## heartbeat used to mask and which read as choppy once it was gone.
const OMEGA := 4.5

## First-order easing for the slow readings. Higher follows faster.
const RATE := {
	"mem_used": 1.0,
	"mem_pressure": 1.0,
	"load": 0.5,
}

var raw := StatSample.new()
var smooth := StatSample.new()
var history: Dictionary[String, History] = {}
var source: StatSource
## Why there is no signal; "" while there is, and before the first sample.
## While set, raw holds the last sample there was and the glyphs show NO
## SIGNAL over it: a monitor that has lost its source says so rather than
## pass off old or invented numbers as the machine's.
var status := ""
## The current source has sent a sample and has not failed since.
var live := false
## Synthetic data only when asked for: `-- --synthetic` or `-- --arch=`.
var synthetic := false

var _retry := 1.0
var _retry_timer: SceneTreeTimer
var _live_ms := 0

var _has_raw := false
var _vel_cores := PackedFloat32Array()
var _vel_total := 0.0
var _vel_rx := 0.0
var _vel_tx := 0.0


func _ready() -> void:
	for key in HISTORY_KEYS:
		history[key] = History.new(HISTORY_LEN)
	# `-- --synthetic` shows the scripted machine instead of this one, and
	# `-- --arch=<name>` one of that architecture (SyntheticStatSource.ARCHS).
	var arch := ""
	for arg in OS.get_cmdline_user_args():
		if arg == "--synthetic":
			synthetic = true
		elif arg.begins_with("--arch="):
			synthetic = true
			arch = arg.trim_prefix("--arch=")
	if synthetic:
		var syn := SyntheticStatSource.new()
		if not arch.is_empty():
			syn.set_arch(arch)
		use(syn)
		return
	_use_helper()


func no_signal() -> bool:
	return not status.is_empty()


func _use_helper() -> void:
	_retry_timer = null
	var helper := HelperStatSource.new()
	helper.failed.connect(_on_helper_failed.bind(helper))
	use(helper)


## Never a fallback to synthetic: the last sample stays, marked as no
## signal, and a fresh helper is tried with backoff. A helper that was
## missing is found once helper/build.sh has run.
func _on_helper_failed(reason: String, helper: HelperStatSource) -> void:
	if helper != source:
		return  # an old one, already replaced
	if live and Time.get_ticks_msec() - _live_ms >= RETRY_MAX * 1000.0:
		_retry = 1.0
	_set_live(false, reason)
	if _retry_timer:
		return
	print("Stats: %s; retrying in %d s" % [reason, _retry])
	# start() can fail inside use(), so the retry is never synchronous.
	_retry_timer = get_tree().create_timer(_retry)
	_retry_timer.timeout.connect(_use_helper)
	_retry = minf(_retry * 2.0, RETRY_MAX)


func _set_live(on: bool, why: String) -> void:
	if on == live and why == status:
		return
	live = on
	status = why
	status_changed.emit()


func use(next: StatSource) -> void:
	if _retry_timer:
		_retry_timer.timeout.disconnect(_use_helper)  # superseded
		_retry_timer = null
	if source:
		source.retire()
	source = next
	# A retry keeps the reason on screen until the new helper speaks.
	_set_live(false, status)
	add_child(source)
	source.sample.connect(_on_sample)
	source_changed.emit(source.source_name())
	source.start()


func _on_sample(s: StatSample) -> void:
	raw = s
	if not live:
		_live_ms = Time.get_ticks_msec()
		_set_live(true, "")
	if not _has_raw:
		_has_raw = true
		settle()
	history["cpu_total"].push(raw.cpu_total)
	history["cpu_perf"].push(_group_mean(raw, true))
	history["cpu_eff"].push(_group_mean(raw, false))
	history["mem_used"].push(float(raw.mem_used))
	history["net_rx_bps"].push(raw.net_rx_bps)
	history["net_tx_bps"].push(raw.net_tx_bps)
	history["load1"].push(raw.load.x)
	history["load5"].push(raw.load.y)
	history["load15"].push(raw.load.z)
	Palette.thermal = raw.thermal
	sampled.emit(s)


## The outer (perf) or inner (eff) group, split as core_ring splits it:
## on cpu_inner_cores, which is the E-cores wherever there are any.
## Under SMT a group is a thread of every core, so the two means together
## are the machine's per-thread load.
static func _group_mean(s: StatSample, perf: bool) -> float:
	var n := s.cpu_cores.size()
	var inner := clampi(s.cpu_inner_cores, 0, n)
	var from := inner if perf else 0
	var to := n if perf else inner
	if to <= from:
		return 0.0
	var sum := 0.0
	for i in range(from, to):
		sum += s.cpu_cores[i]
	return sum / (to - from)


## Forget the past. The screenshot tool uses this between scenarios.
func reset_history() -> void:
	for key in HISTORY_KEYS:
		history[key] = History.new(HISTORY_LEN)


## Snap the smoothed state to the latest raw sample.
func settle() -> void:
	smooth = raw.copy()
	_vel_cores = PackedFloat32Array()
	_vel_total = 0.0
	_vel_rx = 0.0
	_vel_tx = 0.0


static func _k(rate: float, dt: float) -> float:
	return 1.0 - exp(-rate * dt)


## One exact step of a critically damped spring: (x, v) toward target over
## dt. Closed form, so it is stable at any frame rate, 3 fps included.
static func _spring(x: float, v: float, target: float, dt: float) -> Vector2:
	var e := exp(-OMEGA * dt)
	var a := x - target
	var b := v + OMEGA * a
	return Vector2(target + (a + b * dt) * e, (b - OMEGA * (a + b * dt)) * e)


func _process(dt: float) -> void:
	if not _has_raw:
		return
	var n := raw.cpu_cores.size()
	if smooth.cpu_cores.size() != n:
		smooth.cpu_cores = raw.cpu_cores.duplicate()
	if _vel_cores.size() != n:
		_vel_cores.resize(n)
		_vel_cores.fill(0.0)
	for i in n:
		var s := _spring(smooth.cpu_cores[i], _vel_cores[i], raw.cpu_cores[i], dt)
		smooth.cpu_cores[i] = s.x
		_vel_cores[i] = s.y
	var st := _spring(smooth.cpu_total, _vel_total, raw.cpu_total, dt)
	smooth.cpu_total = st.x
	_vel_total = st.y
	smooth.mem_used = int(lerpf(smooth.mem_used, raw.mem_used, _k(RATE["mem_used"], dt)))
	smooth.mem_compressed = int(lerpf(smooth.mem_compressed, raw.mem_compressed, _k(RATE["mem_used"], dt)))
	smooth.mem_pressure = lerpf(smooth.mem_pressure, raw.mem_pressure, _k(RATE["mem_pressure"], dt))
	var rx := _spring(smooth.net_rx_bps, _vel_rx, raw.net_rx_bps, dt)
	smooth.net_rx_bps = rx.x
	_vel_rx = rx.y
	var tx := _spring(smooth.net_tx_bps, _vel_tx, raw.net_tx_bps, dt)
	smooth.net_tx_bps = tx.x
	_vel_tx = tx.y
	smooth.load = smooth.load.lerp(raw.load, _k(RATE["load"], dt))
	# Discrete fields are not eased.
	smooth.t = raw.t
	smooth.thermal = raw.thermal
	smooth.uptime = raw.uptime
	smooth.cpu_perf_cores = raw.cpu_perf_cores
	smooth.cpu_eff_cores = raw.cpu_eff_cores
	smooth.cpu_inner_cores = raw.cpu_inner_cores
	smooth.cpu_inner_kind = raw.cpu_inner_kind
	smooth.cpu_threads = raw.cpu_threads
	smooth.mem_total = raw.mem_total
	smooth.mem_wired = raw.mem_wired
	smooth.mem_free = raw.mem_free


## Bytes span six orders of magnitude; linear scales are useless.
static func log_norm(bps: float, ceiling_bps: float) -> float:
	return clampf(log(1.0 + bps) / log(1.0 + ceiling_bps), 0.0, 1.0)

