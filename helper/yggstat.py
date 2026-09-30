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
#   mem.total    Installed RAM: the online memory blocks under
#                /sys/devices/system/memory, as hw.memsize counts it; the
#                firmware's and kernel's reserve is neither used nor free,
#                as there. Blocks above 128 MiB (bare-metal x86 from 64 GB
#                uses 2 GiB) count the PCI hole and the top of RAM as whole
#                blocks, so there the firmware map's System RAM, rounded up
#                to a GiB, is used instead. MemTotal when neither is readable.
#                [hw.memsize]
#   mem.used     MemTotal - available: what the kernel says it could not
#                hand to a new program without swapping. Available is
#                MemAvailable plus the shrinkable ZFS ARC (size - c_min),
#                which the kernel does not count though it gives it back,
#                as htop and btop count it. [wire+active+compressed]
#   mem.wired    Memory the kernel cannot page out: Unevictable (which already
#                contains Mlocked, so Mlocked is not added twice) plus the
#                kernel's own unreclaimable slab, stacks and page tables.
#                [wire_count]
#   mem.compressed  RAM holding compressed pages: the zswap pool (Zswap:) plus
#                each zram device's mem_used_total. 0 when neither is in use.
#                [compressor_page_count]
#   mem.free     MemFree: pages holding nothing at all, like macOS's free +
#                speculative. Cache is neither used nor free here, as there.
#   mem.pressure 1 - available/MemTotal, the resting level, as the Mac's
#                is 1 - (free + pageable + purgeable)/total: a healthy machine
#                rests around 0.2-0.5 on both. PSI raises it: /proc/pressure/
#                memory "some avg10", the share of the last ten seconds in
#                which a task stalled on memory, is 0 when healthy and a few
#                percent is already felt, so it counts as 2*sqrt(share)
#                (1% stall 0.2, 6% 0.5, 25% and up 1) and the higher of the
#                two is sent, clamped to 0..1. [1 - kern.memorystatus_level/100]
#   net          /proc/net/dev byte counters, per-interface deltas, summed
#                over interfaces backed by hardware (/sys/class/net/X/device),
#                so bridge, veth and tunnel traffic is not counted twice; if
#                there are none, every interface but lo. Rates over
#                CLOCK_MONOTONIC, so a wall-clock step (NTP, a VM restored)
#                cannot spike them. [ifmib, all but lo0]
#   thermal      The CPU package sensor (k10temp Tdie/Tctl, else its
#                unlabelled temp1 on pre-Zen parts; zenpower Tdie; coretemp's
#                hottest Package id N, else its hottest Core N on parts
#                before Sandy Bridge; the Pi's cpu_thermal; else the hottest
#                CPU thermal zone: x86_pkg_temp, cpu/soc/bigcore/littlecore/
#                cpuss/cluster*-thermal on ARM SoCs; acpitz last), in tiers:
#                0 below 70 C, 1 from 70, 2 from 85, 3 from 95 (or, when the
#                sensor reports a crit, from crit-5, and 2 from crit-15; a
#                zone's crit is its lowest critical trip point). A package
#                that runs up to its Tjmax under ordinary load by design
#                has its tiers follow Tjmax (tj-10, tj, tj+5): serious means
#                it has reached Tjmax and throttles, critical that it has
#                gone past (a part that clamps at Tjmax never gets there),
#                as the Mac means them. Intel (coretemp, x86_pkg_temp): its
#                crit is Tjmax, not a shutdown point; 100 C without one. AMD
#                (k10temp, zenpower): pre-Zen k10temp's crit is its HTC
#                limit, where it throttles, so it stands in for Tjmax. Else
#                Tjmax from /proc/cpuinfo: 70 C before Zen (Tctl's relative
#                scale), 90 C (Zen 1-3 desktop, the 5900X), 95 C (Zen 4 and
#                later, family 0x19 model 0x60+ or 0x1a+; Threadripper and
#                EPYC from family 0x19), 100 C for a mobile or handheld part
#                (U/H/HS/HX, Ryzen AI, Ryzen Z, the Steam Deck's Custom APU).
#                Tdie before Tctl, since Tctl carries a +10/+20 C offset on
#                Zen 1 X parts. A tier only drops once the temperature is
#                3 C below its threshold, so the frame does not flicker on a
#                boundary. No sensor: 0. [ProcessInfo.thermalState]
#   uptime       CLOCK_MONOTONIC: time awake since boot, suspend excluded,
#                as the Mac's is (/proc/uptime would count the night the
#                machine slept). [systemUptime]

import glob
import json
import os
import re
import signal
import sys
import time
import traceback

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
	# surrogateescape: an interface name need not be UTF-8, and one odd
	# byte in /proc/net/dev must not fail every sample.
	try:
		with open(path, errors="surrogateescape") as f:
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
	# says it through capacity. Arrow Lake-H puts its LP E-cores under a
	# third PMU, cpu_lowpower; they are E-cores too.
	p_cpus = parse_cpulist(read(SYSFS + "/devices/cpu_core/cpus"))
	e_cpus = set(parse_cpulist(read(SYSFS + "/devices/cpu_atom/cpus")))
	e_cpus |= set(parse_cpulist(read(SYSFS + "/devices/cpu_lowpower/cpus")))
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
	# A cluster of one core is no cluster: a VM of N single-core sockets
	# gets an L3 per vCPU from QEMU, and would put cpu0 alone inside.
	if len(groups) >= 2 and min(len(g) for g in groups) >= 2:
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


def zram_bytes(sysfs="/sys"):
	# Globbed per sample: a device set up after login counts too.
	total = 0
	for path in glob.glob(sysfs + "/block/zram*/mm_stat"):
		f = read(path).split()
		if len(f) >= 3:
			total += int(f[2])  # mem_used_total: RAM the device occupies
	return total


SECTION = 128 << 20
GIB = 1 << 30


def firmware_ram(sysfs="/sys"):
	"""System RAM in the firmware's memory map, in bytes; 0 without one."""
	total = 0
	for d in glob.glob(sysfs + "/firmware/memmap/*"):
		if read(d + "/type").strip() != "System RAM":
			continue
		try:
			total += int(read(d + "/end").strip(), 16) - int(read(d + "/start").strip(), 16) + 1
		except ValueError:
			pass
	return total


## Online memory blocks under this sysfs root, in bytes: installed RAM.
def installed_ram(sysfs="/sys"):
	try:
		block = int(read(sysfs + "/devices/system/memory/block_size_bytes").strip(), 16)
	except ValueError:
		return 0
	n = sum(1 for p in glob.glob(sysfs + "/devices/system/memory/memory*/online") if read(p).strip() == "1")
	if block > SECTION:
		# A block with any RAM in it is online whole: 2 GiB blocks count
		# the PCI hole and the top of RAM in full, 66 GiB on a 64 GB box.
		# The firmware's own map, summed and rounded up to a GiB, does not
		# (reserved RAM is well under one). No map (not x86): the blocks,
		# which elsewhere are aligned to the RAM they hold.
		fw = firmware_ram(sysfs)
		if fw:
			return min(block * n, -(-fw // GIB) * GIB)
	return block * n


INSTALLED = installed_ram()


def arc_reclaimable(path="/proc/spl/kstat/zfs/arcstats"):
	"""Bytes of the ZFS ARC the kernel would give back (size - c_min); 0
	without ZFS. The ARC sits outside the page cache, so MemAvailable leaves
	it out, and a ZFS box would read half full at rest."""
	stats = {}
	for line in read(path).splitlines()[2:]:
		f = line.split()
		if len(f) == 3:
			try:
				stats[f[0]] = int(f[2])
			except ValueError:
				pass
	return max(0, stats.get("size", 0) - max(stats.get("c_min", 0), 0))


def mem_pressure(mem_total, avail, psi):
	"""The Mac's resting level (occupancy), raised by PSI stalls; 0..1."""
	pressure = 1.0 - avail / mem_total if mem_total else 0.0
	if psi is not None:
		pressure = max(pressure, 2.0 * (max(psi, 0.0) / 100.0) ** 0.5)
	return max(0.0, min(1.0, pressure))


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

## AMD package drivers: Tjmax (amd_tjmax) is where the part sits at work; the
## only crit is pre-Zen k10temp's HTC limit, which plays the same part.
AMD_SENSORS = ("k10temp", "zenpower")
## Intel package sensors: crit, when there is one, is Tjmax, where the part sits at work.
INTEL_SENSORS = ("coretemp", "x86_pkg_temp")

## CPU thermal zones by type, lower-cased with '-' as '_': x86 and the ARM
## SoCs (RK3588 soc/bigcore0/littlecore, Qualcomm cpu0/cpuss0, Snapdragon X
## cpu0_0_top, MediaTek cpu_little0, Jetson CPU-therm). Not gpu, not acpitz.
CPU_ZONE = re.compile(r"(x86_pkg_temp|(cpu|soc|bigcore|littlecore|cpuss|cluster)\w*_therm)")


def _millic(path):
	"""A sysfs millidegree file in C, or None."""
	raw = read(path).strip()
	return int(raw) / 1000.0 if raw.isdigit() and int(raw) > 0 else None


def _zone_crit(zone):
	"""The zone's lowest critical trip point in C, or None. Below 60 C it
	is a firmware placeholder (desktop acpitz zones report 20.8 C), not a
	shutdown point, and would read critical at room temperature."""
	crits = []
	for tp in glob.glob(zone + "/trip_point_*_type"):
		if read(tp).strip() == "critical":
			c = _millic(tp[:-len("_type")] + "_temp")
			if c and c >= 60.0:
				crits.append(c)
	return min(crits) if crits else None


def _coretemp(hwmons):
	"""coretemp's (inputs, crit): every package, over every socket's hwmon;
	before Sandy Bridge there is no package sensor, so every core."""
	labels = {lab: read(lab).strip() for hw in hwmons for lab in sorted(glob.glob(hw + "/temp*_label"))}
	for prefix in ("Package id ", "Core "):
		bases = [lab[:-len("_label")] for lab, text in labels.items() if text.startswith(prefix)]
		bases = [b for b in bases if os.path.exists(b + "_input")]
		if bases:
			crits = [c for c in (_millic(b + "_crit") for b in bases) if c]
			return [b + "_input" for b in bases], (max(crits) if crits else None)
	return [], None


def find_cpu_sensor(sysfs="/sys"):
	"""([input paths], crit in C or None, driver name) for the CPU package,
	read as the hottest of the paths; ([], None, None) without one."""
	wanted = {
		# None: temp1 unlabelled, as k10temp is before Zen.
		"k10temp": ("Tdie", "Tctl", None),
		"zenpower": ("Tdie", "Tctl"),
		"cpu_thermal": (None,),
	}
	hwmons = sorted(glob.glob(sysfs + "/class/hwmon/hwmon*"))
	names = {hw: read(hw + "/name").strip() for hw in hwmons}
	for hw in hwmons:
		name = names[hw]
		if name == "coretemp":
			inputs, crit = _coretemp([h for h in hwmons if names[h] == name])
			if inputs:
				return inputs, crit, name
			continue
		if name not in wanted:
			continue
		for label in wanted[name]:
			for lab in sorted(glob.glob(hw + "/temp*_label")) if label else [hw + "/temp1_label"]:
				if label and read(lab).strip() != label:
					continue
				inp = lab[:-len("_label")] + "_input"
				if os.path.exists(inp):
					return [inp], _millic(lab[:-len("_label")] + "_crit"), name
	# No hwmon driver: the CPU thermal zones, all of them (an ARM SoC has
	# one per cluster), else acpitz, coarse but better than a permanent 0.
	zones = sorted(glob.glob(sysfs + "/class/thermal/thermal_zone*"))
	types = {z: read(z + "/type").strip().lower() for z in zones}
	for match in (lambda t: CPU_ZONE.match(t.replace("-", "_")), lambda t: t == "acpitz"):
		hit = [z for z in zones if match(types[z])]
		if hit:
			crits = [c for c in (_zone_crit(z) for z in hit) if c]
			return [z + "/temp" for z in hit], (min(crits) if crits else None), types[hit[0]]
	return [], None, None


def amd_tjmax(cpuinfo="/proc/cpuinfo"):
	"""An AMD part's Tjmax in C, from its family, model and name: 70 before
	Zen (Tctl there is a relative scale topping out at 70), 90 for Zen 1-3
	desktop parts, 95 for Zen 4 and later, 100 for a mobile or handheld
	part (most run 100-105). A rough table, but tiers only need the right
	side of normal; anything unreadable counts as 90."""
	fam = mod = -1
	name = ""
	for line in read(cpuinfo).splitlines():
		k, _, v = line.partition(":")
		k, v = k.strip(), v.strip()
		if k == "cpu family" and fam < 0 and v.isdigit():
			fam = int(v)
		elif k == "model" and mod < 0 and v.isdigit():
			mod = int(v)
		elif k == "model name" and not name:
			name = v
		elif not line.strip() and fam >= 0:
			break               # the first processor says it for all
	if 0 <= fam < 0x17:
		return 70.0             # Phenom, FX, A-series: when k10temp has no HTC crit
	if re.search(r"\b\d{4}(U|H|HS|HX)\b|Ryzen AI|Ryzen Z\d|Custom APU", name):
		return 100.0            # the handhelds too: Steam Deck, ROG Ally, Legion Go
	if fam >= 0x1a or (fam == 0x19 and mod >= 0x60):
		return 95.0
	if fam == 0x19 and mod >= 0x10 and re.search(r"Threadripper|EPYC", name):
		return 95.0             # Zen 4 HEDT and server sit below model 0x60;
		                        # Zen 3's (Milan 0x01, 5000WX 0x08) stay at 90
	return 90.0


def thresholds(crit, name, tj=90.0):
	"""The temperatures tiers 1, 2 and 3 start at."""
	if name in INTEL_SENSORS:
		tj = crit or 100.0      # Tjmax, where a boosting Intel part sits by design
	elif name in AMD_SENSORS:
		tj = crit or tj         # pre-Zen k10temp's crit is HTC, where it throttles
	elif crit:
		return (min(70.0, crit - 25.0), crit - 15.0, crit - 5.0)
	else:
		return (70.0, 85.0, 95.0)
	return (tj - 10.0, tj, tj + 5.0)


SENSOR, CRIT, SENSOR_NAME = find_cpu_sensor()
THRESHOLDS = thresholds(CRIT, SENSOR_NAME, amd_tjmax() if SENSOR_NAME in AMD_SENSORS else 90.0)
HYSTERESIS = 3.0
_tier = 0


def thermal():
	global _tier
	if not SENSOR:
		return 0
	raws = [read(p).strip() for p in SENSOR]
	temps = [int(r) for r in raws if r.lstrip("-").isdigit()]
	if not temps:
		return _tier
	c = max(temps) / 1000.0
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
prev_mono = time.monotonic()  # the rates' clock: the wall clock can step


def sample():
	global prev_ticks, prev_net, prev_mono, ORDER, PERF, EFF, INNER, KIND
	now = time.time()  # the "t" field only
	mono = time.monotonic()
	dt = max(mono - prev_mono, 0.001)

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
	avail = min(mem_total, m.get("MemAvailable", m.get("MemFree", 0)) + arc_reclaimable())
	used = max(0, mem_total - avail)
	installed = max(INSTALLED, mem_total)
	wired = (m.get("Unevictable", 0) + m.get("SUnreclaim", 0)
		+ m.get("KernelStack", 0) + m.get("PageTables", 0) + m.get("SecPageTables", 0))
	wired = min(wired, used)
	compressed = m.get("Zswap", 0) + zram_bytes()
	free = m.get("MemFree", 0)
	pressure = mem_pressure(mem_total, avail, psi_some_avg10())

	net = net_bytes()
	rx_bps, tx_bps = net_rate(prev_net, net, dt)
	prev_net = net
	prev_mono = mono

	uptime = time.clock_gettime(time.CLOCK_MONOTONIC)

	return ('{"t":%s,' % fmt(now)
		+ '"cpu":{"cores":[%s],"total":%s,"perf":%d,"eff":%d,"inner":%d,"inner_kind":"%s","threads":%d},' % (",".join(fmt(c) for c in cores), fmt(total), PERF, EFF, INNER, KIND, len(ticks))
		+ '"load":[%s,%s,%s],' % (fmt(load[0], 2), fmt(load[1], 2), fmt(load[2], 2))
		+ '"mem":{"total":%d,"used":%d,"wired":%d,' % (installed, used, wired)
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
	fails = printed = 0
	while True:
		# A bad reading skips one tick; it must not end the helper, which
		# the game would then replace with synthetic numbers for good.
		try:
			line = sample()
		except Exception:
			# Nobody reads stderr until the helper exits, so a full pipe
			# would block it here: three tracebacks, then a line now and
			# then, then silence. Well under 64 KiB, and the last line
			# still names the error.
			fails += 1
			if fails <= 3:
				traceback.print_exc(file=sys.stderr)
			elif fails % 600 == 0 and printed < 20:
				printed += 1
				e = sys.exc_info()[1]
				print("yggstat: %d samples failed, last %s: %s" % (fails, type(e).__name__, e), file=sys.stderr, flush=True)
			line = None
		if line is not None:
			try:
				sys.stdout.write(line + "\n")
				sys.stdout.flush()
			except (BrokenPipeError, ValueError):
				os._exit(0)  # stdout closed: the reader is gone
		if once and line is None:
			sys.exit(1)  # the smoke test must see it
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
