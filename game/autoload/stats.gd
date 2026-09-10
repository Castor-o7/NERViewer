extends Node
## "Stats" autoload. Owns whichever source is active, eases toward each
## sample every frame, and keeps history. Glyphs read `smooth` and
## `history` and never touch a source.

signal sampled(s: StatSample)
signal source_changed(name: String)

const HISTORY_LEN := 360  # 3 minutes at 500 ms
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
var history := {}
var source: StatSource
var status := ""

var _has_raw := false
var _vel_cores := PackedFloat32Array()
var _vel_total := 0.0
var _vel_rx := 0.0
var _vel_tx := 0.0


func _ready() -> void:
	for key in HISTORY_KEYS:
		history[key] = History.new(HISTORY_LEN)
	var helper := HelperStatSource.new()
	helper.failed.connect(_on_helper_failed)
	use(helper)


func _on_helper_failed(reason: String) -> void:
	status = reason
	print("Stats: helper failed (%s); falling back to synthetic" % reason)
	if source is HelperStatSource:
		use(SyntheticStatSource.new())


func use(next: StatSource) -> void:
	if source:
		source.stop()
		source.queue_free()
	source = next
	add_child(source)
	source.sample.connect(_on_sample)
	source.start()
	source_changed.emit(source.source_name())


func _on_sample(s: StatSample) -> void:
	raw = s
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


static func _group_mean(s: StatSample, perf: bool) -> float:
	var n := s.cpu_cores.size()
	var eff := clampi(s.cpu_eff_cores, 0, n)
	var from := eff if perf else 0
	var to := n if perf else eff
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
	smooth.mem_total = raw.mem_total
	smooth.mem_wired = raw.mem_wired
	smooth.mem_free = raw.mem_free


## Bytes span six orders of magnitude; linear scales are useless.
static func log_norm(bps: float, ceiling_bps: float) -> float:
	return clampf(log(1.0 + bps) / log(1.0 + ceiling_bps), 0.0, 1.0)

