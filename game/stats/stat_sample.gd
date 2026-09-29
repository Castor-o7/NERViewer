class_name StatSample
extends RefCounted
## One tick of everything the piece knows about the machine.
## Sizes in bytes, rates in bytes per second, fractions in 0..1.

var t: float = 0.0                        ## unix seconds, the source's clock
## The core rings' values and what they are; the full contract is in
## helper/yggstat.py's header. perf + eff is always the physical core
## count; cpu_cores holds one value per core, plus one per inner-ring
## thread when cpu_inner_kind is "smt".
var cpu_cores := PackedFloat32Array()     ## 0..1 each, source order: the inner ring's cpu_inner_cores first
var cpu_total: float = 0.0                ## mean over physical cores, SMT threads merged, in every kind
var cpu_perf_cores: int = 0               ## physical P-cores (all of them where there are no E-cores)
var cpu_eff_cores: int = 0                ## physical E-cores; 0 unless the CPU really has them
var cpu_inner_cores: int = 0              ## values on the inner ring, from the front of cpu_cores
## What the inner ring holds: "eff" the E-cores, "cluster" the preferred
## cache cluster (a Ryzen CCD), "smt" each core's second thread (the
## outer ring then holds each core's first), "none" nothing.
var cpu_inner_kind: String = "none"
var cpu_threads: int = 0                  ## logical CPUs; 0 from helpers that do not send it (see logical_cpus)
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


## The two CPU groups every glyph shows, by what they really are: P and E
## where the CPU has efficiency cores (Apple Silicon, hybrid Intel, ARM
## big.LITTLE); O and I, the outer and inner ring, for a Ryzen's cache
## clusters; T1 and T2, each core's first and second thread, under SMT; C
## and nothing when the inner ring is empty (kind none), so an absent
## group is not read as idle E-cores. Never "E" for cores that are not
## efficiency cores.
func group_names() -> PackedStringArray:
	match cpu_inner_kind:
		"cluster":
			return PackedStringArray(["O", "I"])
		"smt":
			return PackedStringArray(["T1", "T2"])
		"none":
			return PackedStringArray(["C", ""])  # no second group to name
	return PackedStringArray(["P", "E"])


## Logical CPUs: what a load average is measured against, as uptime and
## top measure it, so 1.0 per CPU is every hardware thread busy on Linux
## and on a Mac alike. Apple Silicon sends no threads field: its values
## are one per logical CPU, and so are an Intel Mac's.
func logical_cpus() -> int:
	return cpu_threads if cpu_threads > 0 else cpu_cores.size()


## How many values cpu_cores must hold, by the contract.
func expected_values() -> int:
	return cpu_perf_cores + cpu_eff_cores + (cpu_inner_cores if cpu_inner_kind == "smt" else 0)


static func from_json(d: Dictionary) -> StatSample:
	var s := StatSample.new()
	s.t = float(d.get("t", 0.0))
	var cpu: Dictionary = d.get("cpu", {})
	s.cpu_cores = PackedFloat32Array(cpu.get("cores", []))
	s.cpu_total = float(cpu.get("total", 0.0))
	s.cpu_perf_cores = int(cpu.get("perf", 0))
	s.cpu_eff_cores = int(cpu.get("eff", 0))
	s.cpu_inner_cores = int(cpu.get("inner", s.cpu_eff_cores))  # Apple Silicon sends none: the E-cores
	s.cpu_inner_kind = str(cpu.get("inner_kind", ""))
	s.cpu_threads = int(cpu.get("threads", 0))
	if s.cpu_inner_kind.is_empty():
		# Apple Silicon, and helpers from before the kind was sent.
		s.cpu_inner_kind = "eff" if s.cpu_eff_cores > 0 else ("cluster" if s.cpu_inner_cores > 0 else "none")
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

