class_name SyntheticStatSource
extends StatSource
## Scripted machines. This is the art-direction tool: the piece is designed
## against these scenarios before real data ever arrives. Noise is layered
## on everything so nothing is sterile.
##
## Each scenario runs on an architecture from ARCHS, shaped as the real
## helpers would send it (the contract is in helper/yggstat.py's header),
## so the core glyph can be seen on a CPU this machine is not. The A key
## cycles them (main.gd); `-- --arch=5600x` on the command line starts
## on one (Stats). The default is the M2 the piece was designed on.

const INTERVAL := 0.5
const GIB := 1024 * 1024 * 1024
## perf, eff: physical cores. inner: values on the inner ring. kind: what
## the inner ring holds. Under "smt" there are perf + eff + inner values.
## threads: logical CPUs, the load glyph's scale.
const ARCHS := {
	"m2": {"perf": 4, "eff": 4, "inner": 4, "kind": "eff", "threads": 8},              # Apple M2, 4P + 4E
	"intel_mac": {"perf": 8, "eff": 0, "inner": 8, "kind": "smt", "threads": 16},       # i9-9880H, 8c/16t
	"5900x": {"perf": 12, "eff": 0, "inner": 6, "kind": "cluster", "threads": 24},      # two CCDs
	"5600x": {"perf": 6, "eff": 0, "inner": 6, "kind": "smt", "threads": 12},           # one CCD, 6c/12t
	"9700k": {"perf": 8, "eff": 0, "inner": 0, "kind": "none", "threads": 8},          # 8c, no SMT
	"12700": {"perf": 8, "eff": 4, "inner": 4, "kind": "eff", "threads": 20},           # 8P (HT merged) + 4E
	"big_little": {"perf": 4, "eff": 4, "inner": 4, "kind": "eff", "threads": 8},      # ARM 4 + 4 by cpu_capacity
	"3990x": {"perf": 64, "eff": 0, "inner": 4, "kind": "cluster", "threads": 128},      # 64c; Zen 2 L3 is per 4-core CCX
}
const DEFAULT_ARCH := "m2"

const SCENARIOS := ["idle", "drift", "ramp", "spike", "download", "pressure"]

var scenario := "idle"
var arch := DEFAULT_ARCH
var speed := 1.0

var _t := 0.0
var _acc := 0.0
var _noise := FastNoiseLite.new()


func _init() -> void:
	_noise.seed = 7
	_noise.frequency = 0.35


func source_name() -> String:
	if arch == DEFAULT_ARCH:
		return "synthetic/" + scenario
	return "synthetic/%s/%s" % [arch, scenario]


func start() -> void:
	set_process(true)


func stop() -> void:
	set_process(false)


func seek(t: float) -> void:
	_t = t
	_acc = 0.0


func set_scenario(name: String) -> void:
	if name in SCENARIOS:
		scenario = name
		seek(0.0)


func next_scenario() -> void:
	set_scenario(SCENARIOS[(SCENARIOS.find(scenario) + 1) % SCENARIOS.size()])


func set_arch(name: String) -> void:
	if ARCHS.has(name):
		arch = name


func next_arch() -> void:
	var names := ARCHS.keys()
	set_arch(names[(names.find(arch) + 1) % names.size()])


func _process(dt: float) -> void:
	_acc += dt * speed
	while _acc >= INTERVAL:
		_acc -= INTERVAL
		_t += INTERVAL
		emit_now()


func emit_now() -> void:
	sample.emit(build(_t))


## Emit every sample from `seconds` ago up to now, so history is full.
func backfill(seconds: float) -> void:
	var t := _t - seconds  # negative t is simply 'before the scenario began'
	while t < _t:
		sample.emit(build(t))
		t += INTERVAL
	emit_now()


## 0..1 smooth noise, distinct per channel.
func _n(t: float, channel: float) -> float:
	return 0.5 + 0.5 * _noise.get_noise_2d(t, channel * 41.7)


func build(t: float) -> StatSample:
	var s := StatSample.new()
	s.t = 1_757_444_000.0 + t
	var a: Dictionary = ARCHS[arch]
	s.cpu_perf_cores = a["perf"]
	s.cpu_eff_cores = a["eff"]
	s.cpu_inner_cores = a["inner"]
	s.cpu_inner_kind = a["kind"]
	s.cpu_threads = a["threads"]
	var inner: int = a["inner"]
	var outer := s.expected_values() - inner
	s.uptime = 812_345.0 + t
	s.mem_total = 16 * GIB
	s.load = Vector3(1.2, 1.4, 1.5)
	s.thermal = 0

	# Idle is the ground everything else is built on: the inner ring (the
	# E-cores) takes the light load, the outer ring is nearly dark.
	var cores := PackedFloat32Array()
	for i in inner:
		cores.append(0.03 + 0.05 * _n(t, i))
	for i in outer:
		cores.append(0.005 + 0.02 * _n(t, inner + i))
	var used := 9.1 * GIB + 0.2 * GIB * _n(t * 0.2, 20)
	var pressure := 0.17
	var rx := 3_000.0 + 20_000.0 * pow(_n(t, 30), 3.0)
	var tx := 1_000.0 + 4_000.0 * pow(_n(t, 31), 3.0)

	match scenario:
		"drift":
			cores[mini(inner + 1, cores.size() - 1)] = 0.02 + 0.4 * (0.5 - 0.5 * cos(TAU * t / 60.0))
		"ramp":
			var k := clampf(t / 20.0, 0.0, 1.0)
			for i in cores.size():
				cores[i] = lerpf(cores[i], 0.85 + 0.12 * _n(t, i), k)
			s.load = Vector3(1.2 + 6.0 * k, 1.4 + 3.0 * k, 1.5 + 1.0 * k)
			s.thermal = 0 if t < 10.0 else (1 if t < 25.0 else 2)
		"spike":
			if t >= 5.0 and t < 6.0:
				for i in range(inner, cores.size()):
					cores[i] = 0.97 + 0.03 * _n(t * 4.0, i)
			elif t >= 6.0 and t < 9.0:
				for i in range(inner, cores.size()):
					cores[i] = lerpf(0.6, cores[i], (t - 6.0) / 3.0)
		"download":
			var k := clampf(t / 30.0, 0.0, 1.0)
			rx = pow(10.0, lerpf(4.0, 7.7, k)) * (0.8 + 0.4 * _n(t * 2.0, 32))
			tx = rx * 0.03
			cores[0] += 0.15 * k
			cores[1] += 0.1 * k
		"pressure":
			var k := clampf(t / 40.0, 0.0, 1.0)
			used = lerpf(9.1 * GIB, 15.6 * GIB, k)
			pressure = lerpf(0.17, 0.7, k)
			cores[0] += 0.2 * k

	s.cpu_cores = cores
	## The total is per physical core, as the helpers send it: under smt a
	## core's two threads (i and i + inner) merge as 1 - (1-a)(1-b).
	var sum := 0.0
	if s.cpu_inner_kind == "smt" and inner > 0:
		for i in inner:
			sum += 1.0 - (1.0 - clampf(cores[i], 0.0, 1.0)) * (1.0 - clampf(cores[i + inner], 0.0, 1.0))
		s.cpu_total = sum / inner
	else:
		for v in cores:
			sum += v
		s.cpu_total = sum / cores.size()
	s.mem_used = int(used)
	s.mem_wired = int(2.1 * GIB)
	s.mem_compressed = int(lerpf(0.45 * GIB, 2.4 * GIB, pressure))
	s.mem_free = s.mem_total - s.mem_used
	s.mem_pressure = pressure
	s.net_rx_bps = rx
	s.net_tx_bps = tx
	return s

