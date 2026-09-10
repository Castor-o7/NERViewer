extends Node
## "Stats" autoload. Owns whichever source is active, eases toward each
## sample every frame, and keeps history. Glyphs read `smooth` and
## `history` and never touch a source.

signal sampled(s: StatSample)
signal source_changed(name: String)

const HISTORY_LEN := 360  # 3 minutes at 500 ms
const HISTORY_KEYS := ["cpu_total", "cpu_perf", "cpu_eff", "mem_used", "net_rx_bps", "net_tx_bps", "load1", "load5", "load15"]

## Per-field easing rate. Higher follows faster. The breath is the tween.
const RATE := {
	"cpu_cores": 4.0,
	"cpu_total": 4.0,
	"mem_used": 1.0,
	"mem_pressure": 1.0,
	"net_rx_bps": 6.0,
	"net_tx_bps": 6.0,
	"load": 0.5,
}

var raw := StatSample.new()
var smooth := StatSample.new()
var history := {}
var source: StatSource
var status := ""

var _has_raw := false


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


static func _k(rate: float, dt: float) -> float:
	return 1.0 - exp(-rate * dt)


func _process(dt: float) -> void:
	if not _has_raw:
		return
	var k := _k(RATE["cpu_cores"], dt)
	if smooth.cpu_cores.size() != raw.cpu_cores.size():
		smooth.cpu_cores = raw.cpu_cores.duplicate()
	for i in raw.cpu_cores.size():
		smooth.cpu_cores[i] = lerpf(smooth.cpu_cores[i], raw.cpu_cores[i], k)
	smooth.cpu_total = lerpf(smooth.cpu_total, raw.cpu_total, _k(RATE["cpu_total"], dt))
	smooth.mem_used = int(lerpf(smooth.mem_used, raw.mem_used, _k(RATE["mem_used"], dt)))
	smooth.mem_compressed = int(lerpf(smooth.mem_compressed, raw.mem_compressed, _k(RATE["mem_used"], dt)))
	smooth.mem_pressure = lerpf(smooth.mem_pressure, raw.mem_pressure, _k(RATE["mem_pressure"], dt))
	smooth.net_rx_bps = lerpf(smooth.net_rx_bps, raw.net_rx_bps, _k(RATE["net_rx_bps"], dt))
	smooth.net_tx_bps = lerpf(smooth.net_tx_bps, raw.net_tx_bps, _k(RATE["net_tx_bps"], dt))
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

