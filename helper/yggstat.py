#!/usr/bin/env python3
# yggstat — the NERViewer stat daemon, Linux edition.
#
# The same contract as main.swift (the macOS helper): one JSON object per
# line at a fixed interval, every field always present, flushed per line.
# Exits when its stdout closes (EPIPE on the next write) or when its parent
# dies. Python 3 standard library only; everything comes from /proc and
# /sys. helper/build.sh copies this to game/bin/yggstat on Linux.
#
#   yggstat [--interval 500] [--once]
#
# How each field maps onto Linux (macOS source in brackets):
#
#   cpu          The values the core rings show, and what they are. The
#                inner ring shows the first `inner` values, the outer ring
#                the rest; `inner_kind` says what the inner ring holds:
#
#     kind     when                         cores (inner first)       perf        eff      inner
#     eff      hybrid Intel (cpu_core and   E-cores, then P-cores,    P-cores     E-cores  eff
#              cpu_atom), or ARM big.LITTLE one per physical core
#              (cpu_capacity differs)
#     cluster  2+ last-level-cache clusters the preferred cluster,    physical    0        its cores
#              (Ryzen CCDs, Threadripper)   then the rest, per core   cores
#     smt      one cluster, every core has  each core's second        physical    0        physical
#              an SMT sibling               thread(s), then each      cores                cores
#                                           core's first thread
#     none     one cluster, no SMT          one per physical core     physical    0        0
#
#                So len(cores) == perf + eff, plus inner when the kind is
#                smt: the only kind where a value is a thread, not a core.
#                perf + eff is always the physical core count. Everywhere
#                but smt a core's SMT threads merge as 1 - prod(idle share),
#                the chance at least one of them was busy, so an SMT core
#                reads like an Apple core. Values come from /proc/stat
#                per-cpu jiffy deltas. [host_processor_info]
#                  `total` is the mean over physical cores, SMT threads
#                merged, in every kind: under smt the two values of a core
#                are merged back before averaging, so the headline means
#                the same on every CPU while the rings show threads.
#                  The E-cores and the preferred cluster carry the light
#                load as the E-cluster does on Apple Silicon; the preferred
#                cluster is the one holding the scheduler's favourite core
#                (amd_pstate prefcore ranking, else CPPC highest_perf).
#                  macOS on Apple Silicon sends no inner/inner_kind: its
#                cores are one per logical CPU (no SMT), perf/eff are
#                hw.perflevel0/1.logicalcpu, and the reader takes inner =
#                eff, kind eff. An Intel Mac sends kind smt or none, as
#                here (see main.swift).
#                  What the inner ring shows on a one-cluster SMT CPU is a
#                choice: INNER_WHEN_SINGLE_CLUSTER below.
#                  The topology is read under $YGGSTAT_SYSFS (default /sys),
#                so test_topology.py can hand it fake machines.
#                  `threads` is the logical CPU count, online ones: the
#                load glyph's scale. [Apple Silicon sends none; the reader
#                takes the value count, which is one per logical CPU there]
#   load         os.getloadavg(), read against `threads` as uptime reads it.
#                Linux counts tasks waiting on disk (D state) as load too;
#                macOS counts runnable threads only. Deliberate: it is the
#                kernel's own number on each. [getloadavg]
#   mem.total    MemTotal. [hw.memsize]
#   mem.used     MemTotal - MemAvailable: what the kernel says it could not
#                hand to a new program without swapping. [wire+active+compressed]
#   mem.wired    Memory the kernel cannot page out: Unevictable (which already
#                contains Mlocked, so Mlocked is not added twice) plus the
#                kernel's own unreclaimable slab, stacks and page tables.
#                [wire_count]
#   mem.compressed  RAM holding compressed pages: the zswap pool (Zswap:) plus
#                each zram device's mem_used_total. 0 when neither is in use.
#                [compressor_page_count]
#   mem.free     MemFree: pages holding nothing at all, like macOS's free +
#                speculative. Cache is neither used nor free here, as there.
#   mem.pressure PSI, /proc/pressure/memory "some avg10": the share of the last
#                ten seconds in which at least one task stalled on memory.
#                It is 0 on a healthy machine and a few percent is already
#                felt, so it is shown as 2*sqrt(share), clamped to 0..1:
#                1% stall reads 0.2, 6% reads 0.5, 25% and up reads 1. Without
#                PSI (kernel built without it) 1 - MemAvailable/MemTotal
#                stands in. [1 - kern.memorystatus_level/100]
#   net          /proc/net/dev byte counters, per-interface deltas, summed
#                over interfaces backed by hardware (/sys/class/net/X/device),
#                so bridge, veth and tunnel traffic is not counted twice; if
#                there are none, every interface but lo. [ifmib, all but lo0]
#   thermal      The CPU package sensor (k10temp Tctl/Tdie, zenpower Tdie,
#                coretemp Package id 0, else an x86_pkg_temp or cpu thermal
#                zone), in tiers: 0 below 70 C, 1 from 70, 2 from 85, 3 from
#                95 (or, when the sensor reports a crit, from crit-5, and 2
#                from crit-15). A tier only drops once the temperature is 3 C
#                below its threshold, so the frame does not flicker on a
#                boundary. No sensor: 0. [ProcessInfo.thermalState]
#   uptime       /proc/uptime, first field. [systemUptime]

import glob
import json
import os
import signal
import sys
import time

# MARK: - Arguments

interval_ms = 500
once = False
_args = iter(sys.argv[1:])
for _a in _args:
	if _a == "--interval":
		try:
			_n = int(next(_args, ""))
			if _n >= 50:
				interval_ms = _n
		except ValueError:
			pass
	elif _a == "--once":
		once = True


def read(path):
	try:
		with open(path) as f:
			return f.read()
	except OSError:
		return ""


def parse_cpulist(text):
	"""'0-3,8,10-11' -> [0, 1, 2, 3, 8, 10, 11]"""
	out = []
	for part in text.strip().split(","):
		if not part:
			continue
		if "-" in part:
			a, b = part.split("-", 1)
			out.extend(range(int(a), int(b) + 1))
		else:
			out.append(int(part))
	return out


# MARK: - CPU

def cpu_ticks():
	"""{cpu index: (idle, total)} from /proc/stat."""
	out = {}
	for line in read("/proc/stat").splitlines():
		if not line.startswith("cpu") or line.startswith("cpu "):
			continue
		f = line.split()
		try:
			idx = int(f[0][3:])
			v = [int(x) for x in f[1:9]]  # guest time is already inside user
		except (ValueError, IndexError):
			continue
		v += [0] * (8 - len(v))
		out[idx] = (v[3] + v[4], sum(v))  # idle + iowait
	return out


## Where the CPU topology is read from. Only the topology: the fixtures in
## test_topology.py are fake /sys trees holding just that.
SYSFS = os.environ.get("YGGSTAT_SYSFS", "/sys")

## What the inner ring shows on a CPU of one cache cluster, no E-cores:
##   "smt"      (a) each core's second thread, the outer ring each core's
##              first, so every logical CPU is on screen as itself. A CPU
##              without SMT has nothing to put there: kind none, inner 0.
##   "average"  (b) not built yet. The outer ring would show each physical
##              core now, the inner ring the same cores' busy share over
##              the last half minute or so, a slower hand on the same dial.
##              To build it: core_order returns (cores, n, 0, n, "average")
##              for the physical cores; sample() keeps an exponential mean
##              per core of cpu_util's values and sends mean + now, so
##              len(cores) == perf + eff + inner holds for it as for smt
##              (widen that rule in build.sh and stats_probe.gd); and
##              StatSample.group_names gives the pair a name of its own.
## Anything else, "average" included until it is built, reads as "none".
## (a) was chosen on 2026-09-29; (b) is kept in case per-thread rings stop
## reading as the machine's load.
INNER_WHEN_SINGLE_CLUSTER = "smt"

## ARM big.LITTLE: cores whose cpu_capacity is below this share of the
## biggest are efficiency cores. x86 reports 1024 everywhere, or close to
## it where a kernel scales capacity by boost rank, so it never trips.
CAPACITY_SPLIT = 0.8


def _cpu_sys(c, leaf):
	return read("%s/devices/system/cpu/cpu%d/%s" % (SYSFS, c, leaf))


def _rank(c):
	"""How much the scheduler prefers this CPU: amd_pstate's preferred-core
	ranking, else CPPC highest_perf, else 0 (no preference known)."""
	for leaf in ("cpufreq/amd_pstate_prefcore_ranking", "acpi_cppc/highest_perf"):
		try:
			return int(_cpu_sys(c, leaf).strip())
		except ValueError:
			pass
	return 0


def _little_cores(cores):
	"""The physical cores of the lowest cpu_capacity class, when capacities
	differ enough to call them efficiency cores (ARM big.LITTLE, DynamIQ);
	else []. On three tiers (prime, big, little) only the little ones."""
	caps = {}
	for k in cores:
		try:
			caps[k] = int(_cpu_sys(k[0], "cpu_capacity").strip())
		except ValueError:
			return []  # unknown for some core: no claim either way
	if not caps:
		return []
	lo, hi = min(caps.values()), max(caps.values())
	if hi <= 0 or lo >= hi * CAPACITY_SPLIT:
		return []
	return [k for k in cores if caps[k] < lo * 1.1]


def core_order(present=None):
	"""What the rings show, as (slots, perf, eff, inner, kind): slots in
	display order, inner ring first, each a tuple of logical CPUs whose busy
	shares merge into one value; the rest is the contract in the header.
	`present` is the online CPUs, from /proc/stat unless given."""
	if present is None:
		present = sorted(cpu_ticks().keys())
	cores, seen = [], set()
	for c in present:
		if c in seen:
			continue
		sib = [x for x in parse_cpulist(_cpu_sys(c, "topology/thread_siblings_list")) if x in present] or [c]
		sib = sorted(set(sib) | {c})
		seen.update(sib)
		cores.append(tuple(sib))
	# E-cores first, as on Apple Silicon: hybrid Intel names its own, ARM
	# says it through capacity.
	p_cpus = parse_cpulist(read(SYSFS + "/devices/cpu_core/cpus"))
	e_cpus = set(parse_cpulist(read(SYSFS + "/devices/cpu_atom/cpus")))
	if p_cpus and e_cpus:
		e = [k for k in cores if k[0] in e_cpus]
	else:
		e = _little_cores(cores)
	if e:
		p = [k for k in cores if k not in e]
		if p:
			return e + p, len(p), len(e), len(e), "eff"
	# No E-cores: the clusters that share a last-level cache. The one
	# holding the scheduler's preferred core goes first, on the inner ring.
	clusters = {}
	for k in cores:
		key = _cpu_sys(k[0], "cache/index3/shared_cpu_list").strip() or _cpu_sys(k[0], "topology/die_id").strip()
		clusters.setdefault(key, []).append(k)
	groups = list(clusters.values())
	if len(groups) >= 2:
		first = max(groups, key=lambda g: (max(_rank(c) for k in g for c in k), -g[0][0]))
		rest = [k for k in cores if k not in first]
		return first + rest, len(cores), 0, len(first), "cluster"
	# One cluster. The switch point between (a) and (b): see above.
	if INNER_WHEN_SINGLE_CLUSTER == "smt" and cores and all(len(k) >= 2 for k in cores):
		return [k[1:] for k in cores] + [k[:1] for k in cores], len(cores), 0, len(cores), "smt"
	return cores, len(cores), 0, 0, "none"


ORDER, PERF, EFF, INNER, KIND = core_order()


def cpu_util(prev, cur):
	"""Busy share per slot of ORDER: 1 - prod(idle share of its CPUs)."""
	out = []
	for core in ORDER:
		idle_all = 1.0
		for c in core:
			p, n = prev.get(c), cur.get(c)
			if p is None or n is None or n[1] - p[1] <= 0:
				continue  # offline between readings: counts as idle
			idle_all *= max(0.0, min(1.0, (n[0] - p[0]) / (n[1] - p[1])))
		out.append(1.0 - idle_all)
	return out


def cpu_total(cores, kind, inner):
	"""The headline total: the mean over physical cores, SMT threads merged,
	in every kind. Under smt value i (a core's second thread) and value
	i + inner (its first) are one core, and 1 - (1-a)(1-b) is exactly the
	product of idle shares the unsplit core would have given, so a 6c/12t
	CPU with every core busy reads full, as it does in the other kinds."""
	if kind == "smt" and inner and len(cores) >= 2 * inner:
		return sum(1.0 - (1.0 - cores[i]) * (1.0 - cores[i + inner]) for i in range(inner)) / inner
	return sum(cores) / len(cores) if cores else 0.0


# MARK: - Memory

def meminfo():
	out = {}
	for line in read("/proc/meminfo").splitlines():
		k, _, rest = line.partition(":")
		f = rest.split()
		if f:
			try:
				out[k] = int(f[0]) * (1024 if len(f) > 1 else 1)
			except ValueError:
				pass
	return out


ZRAM = glob.glob("/sys/block/zram*/mm_stat")


def zram_bytes():
	total = 0
	for path in ZRAM:
		f = read(path).split()
		if len(f) >= 3:
			total += int(f[2])  # mem_used_total: RAM the device occupies
	return total


def psi_some_avg10():
	"""Percent, or None without PSI."""
	for line in read("/proc/pressure/memory").splitlines():
		if line.startswith("some"):
			for kv in line.split()[1:]:
				k, _, v = kv.partition("=")
				if k == "avg10":
					try:
						return float(v)
					except ValueError:
						return None
	return None


# MARK: - Network

def hw_interfaces():
	names = [os.path.basename(p) for p in glob.glob("/sys/class/net/*")]
	return {n for n in names if n != "lo" and os.path.exists("/sys/class/net/%s/device" % n)}


def net_bytes():
	"""{interface: (rx, tx)} for every interface but lo."""
	out = {}
	for line in read("/proc/net/dev").splitlines()[2:]:
		name, _, rest = line.partition(":")
		name = name.strip()
		f = rest.split()
		if name == "lo" or len(f) < 9:
			continue
		out[name] = (int(f[0]), int(f[8]))
	return out


def net_rate(prev, cur, dt):
	hw = hw_interfaces()
	names = [n for n in cur if n in hw] or list(cur)
	rx = tx = 0
	for n in names:
		if n in prev:
			# A counter that went backwards is an interface that was reset.
			rx += max(0, cur[n][0] - prev[n][0])
			tx += max(0, cur[n][1] - prev[n][1])
	return rx / dt, tx / dt


# MARK: - Thermal

def find_cpu_sensor():
	"""(input path, crit in C or None) for the CPU package, else (None, None)."""
	wanted = {
		"k10temp": ("Tctl", "Tdie"),
		"zenpower": ("Tdie", "Tctl"),
		"coretemp": ("Package id 0",),
		"cpu_thermal": (None,),
	}
	for hw in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
		name = read(hw + "/name").strip()
		if name not in wanted:
			continue
		for label in wanted[name]:
			for lab in sorted(glob.glob(hw + "/temp*_label")) if label else [hw + "/temp1_label"]:
				if label and read(lab).strip() != label:
					continue
				inp = lab[:-len("_label")] + "_input"
				if os.path.exists(inp):
					crit = read(lab[:-len("_label")] + "_crit").strip()
					return inp, (int(crit) / 1000.0 if crit.isdigit() and int(crit) > 0 else None)
	for zone in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
		t = read(zone + "/type").strip().lower()
		if t in ("x86_pkg_temp", "cpu-thermal", "cpu_thermal", "soc_thermal"):
			return zone + "/temp", None
	return None, None


SENSOR, CRIT = find_cpu_sensor()
if CRIT:
	THRESHOLDS = (min(70.0, CRIT - 25.0), CRIT - 15.0, CRIT - 5.0)
else:
	THRESHOLDS = (70.0, 85.0, 95.0)
HYSTERESIS = 3.0
_tier = 0


def thermal():
	global _tier
	if not SENSOR:
		return 0
	raw = read(SENSOR).strip()
	if not raw.lstrip("-").isdigit():
		return _tier
	c = int(raw) / 1000.0
	up = sum(1 for th in THRESHOLDS if c >= th)
	down = sum(1 for th in THRESHOLDS if c >= th - HYSTERESIS)
	# Rise at once; fall only past the hysteresis band.
	if up > _tier:
		_tier = up
	elif down < _tier:
		_tier = down
	return _tier


# MARK: - Sample

def fmt(v, places=3):
	if v != v or v in (float("inf"), float("-inf")):
		return "0"
	return "%.*f" % (places, v)


prev_ticks = cpu_ticks()
prev_net = net_bytes()
prev_time = time.time()


def sample():
	global prev_ticks, prev_net, prev_time, ORDER, PERF, EFF, INNER, KIND
	now = time.time()
	dt = max(now - prev_time, 0.001)

	ticks = cpu_ticks()
	if set(ticks) != set(prev_ticks):
		# A CPU came online or went offline (SMT toggled, hotplug): the
		# cores and clusters are read again, so none is shown as idle
		# while it is gone and a returning one is counted.
		ORDER, PERF, EFF, INNER, KIND = core_order()
	cores = cpu_util(prev_ticks, ticks)
	prev_ticks = ticks
	total = cpu_total(cores, KIND, INNER)

	try:
		load = os.getloadavg()
	except OSError:
		load = (0.0, 0.0, 0.0)

	m = meminfo()
	mem_total = m.get("MemTotal", 0)
	avail = m.get("MemAvailable", m.get("MemFree", 0))
	used = max(0, mem_total - avail)
	wired = (m.get("Unevictable", 0) + m.get("SUnreclaim", 0)
		+ m.get("KernelStack", 0) + m.get("PageTables", 0) + m.get("SecPageTables", 0))
	wired = min(wired, used)
	compressed = m.get("Zswap", 0) + zram_bytes()
	free = m.get("MemFree", 0)
	psi = psi_some_avg10()
	if psi is None:
		pressure = 1.0 - avail / mem_total if mem_total else 0.0
	else:
		pressure = 2.0 * (psi / 100.0) ** 0.5
	pressure = max(0.0, min(1.0, pressure))

	net = net_bytes()
	rx_bps, tx_bps = net_rate(prev_net, net, dt)
	prev_net = net
	prev_time = now

	try:
		uptime = float(read("/proc/uptime").split()[0])
	except (IndexError, ValueError):
		uptime = 0.0

	return ('{"t":%s,' % fmt(now)
		+ '"cpu":{"cores":[%s],"total":%s,"perf":%d,"eff":%d,"inner":%d,"inner_kind":"%s","threads":%d},' % (",".join(fmt(c) for c in cores), fmt(total), PERF, EFF, INNER, KIND, len(ticks))
		+ '"load":[%s,%s,%s],' % (fmt(load[0], 2), fmt(load[1], 2), fmt(load[2], 2))
		+ '"mem":{"total":%d,"used":%d,"wired":%d,' % (mem_total, used, wired)
		+ '"compressed":%d,"free":%d,"pressure":%s},' % (compressed, free, fmt(pressure))
		+ '"net":{"rx_bps":%s,"tx_bps":%s},' % (fmt(max(0.0, rx_bps), 1), fmt(max(0.0, tx_bps), 1))
		+ '"thermal":%d,' % thermal()
		+ '"uptime":%s}' % fmt(uptime, 1))


# MARK: - Loop

def main():
	# A closed pipe ends the process quietly, as SIGPIPE does the Swift one.
	signal.signal(signal.SIGPIPE, signal.SIG_DFL)
	signal.signal(signal.SIGINT, signal.SIG_DFL)
	parent = os.getppid()

	# The first reading needs a baseline; wait one short interval so the
	# first line carries real rates instead of zeros.
	time.sleep(min(interval_ms, 250) / 1000.0)

	next_at = time.monotonic()
	while True:
		try:
			sys.stdout.write(sample() + "\n")
			sys.stdout.flush()
		except (BrokenPipeError, ValueError):
			os._exit(0)
		# Orphaned: reparented to init or to a subreaper (systemd --user).
		if once or os.getppid() != parent:
			break
		next_at += interval_ms / 1000.0
		wait = next_at - time.monotonic()
		if wait < 0:
			next_at = time.monotonic()  # fell behind (suspend); do not burst
			wait = 0.0
		time.sleep(wait)


if __name__ == "__main__":
	main()
