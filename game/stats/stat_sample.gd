class_name StatSample
extends RefCounted
## One tick of everything the piece knows about the machine.
## Sizes in bytes, rates in bytes per second, fractions in 0..1.

var t: float = 0.0                        ## unix seconds, the source's clock
var cpu_cores := PackedFloat32Array()     ## 0..1 per logical core, source order (E-cores first)
var cpu_total: float = 0.0
var cpu_perf_cores: int = 0               ## hw.perflevel0.logicalcpu
var cpu_eff_cores: int = 0                ## hw.perflevel1.logicalcpu
var load := Vector3.ZERO                  ## 1, 5, 15 minute averages
var mem_total: int = 0
var mem_used: int = 0                     ## wired + active + compressed
var mem_wired: int = 0
var mem_compressed: int = 0
var mem_free: int = 0
var mem_pressure: float = 0.0             ## 1 - kern.memorystatus_level / 100
var net_rx_bps: float = 0.0
var net_tx_bps: float = 0.0
var thermal: int = 0                      ## 0 nominal, 1 fair, 2 serious, 3 critical
var uptime: float = 0.0


static func from_json(d: Dictionary) -> StatSample:
	var s := StatSample.new()
	s.t = float(d.get("t", 0.0))
	var cpu: Dictionary = d.get("cpu", {})
	s.cpu_cores = PackedFloat32Array(cpu.get("cores", []))
	s.cpu_total = float(cpu.get("total", 0.0))
	s.cpu_perf_cores = int(cpu.get("perf", 0))
	s.cpu_eff_cores = int(cpu.get("eff", 0))
	var l: Array = d.get("load", [0, 0, 0])
	s.load = Vector3(float(l[0]), float(l[1]), float(l[2]))
	var m: Dictionary = d.get("mem", {})
	s.mem_total = int(m.get("total", 0))
	s.mem_used = int(m.get("used", 0))
	s.mem_wired = int(m.get("wired", 0))
	s.mem_compressed = int(m.get("compressed", 0))
	s.mem_free = int(m.get("free", 0))
	s.mem_pressure = float(m.get("pressure", 0.0))
	var n: Dictionary = d.get("net", {})
	s.net_rx_bps = float(n.get("rx_bps", 0.0))
	s.net_tx_bps = float(n.get("tx_bps", 0.0))
	s.thermal = int(d.get("thermal", 0))
	s.uptime = float(d.get("uptime", 0.0))
	return s


func copy() -> StatSample:
	var s := StatSample.new()
	for prop in get_property_list():
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			s.set(prop.name, get(prop.name))
	s.cpu_cores = cpu_cores.duplicate()
	return s

