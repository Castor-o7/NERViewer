#!/usr/bin/env python3
# yggstat's Linux readings that stand in for a Mac's: memory pressure (and
# the ZFS ARC in it), zram, installed RAM and the thermal tiers, each against
# a fake /sys or /proc file or plain numbers. Standard library only.
#
#   python3 helper/test_readings.py -v

import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("yggstat", os.path.join(HERE, "yggstat.py"))
yggstat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(yggstat)  # reads this machine once; harmless

GIB = 1 << 30


class Tree(unittest.TestCase):
	def setUp(self):
		self.root = tempfile.mkdtemp(prefix="yggstat-")

	def tearDown(self):
		shutil.rmtree(self.root)

	def put(self, rel, text):
		path = os.path.join(self.root, rel)
		os.makedirs(os.path.dirname(path), exist_ok=True)
		with open(path, "w") as f:
			f.write(text + "\n")


class Pressure(unittest.TestCase):
	def test_rests_at_occupancy_like_a_mac(self):
		# This box, idle: 6.9 G of 31.25 G in use, no stalls.
		self.assertAlmostEqual(yggstat.mem_pressure(33559089152, 26652778496, 0.0), 0.206, places=3)

	def test_stalls_raise_it(self):
		self.assertAlmostEqual(yggstat.mem_pressure(100, 80, 6.25), 0.5)

	def test_occupancy_wins_over_small_stalls(self):
		self.assertAlmostEqual(yggstat.mem_pressure(100, 30, 1.0), 0.7)

	def test_without_psi(self):
		self.assertAlmostEqual(yggstat.mem_pressure(100, 75, None), 0.25)

	def test_clamped(self):
		self.assertEqual(yggstat.mem_pressure(100, 0, 90.0), 1.0)
		self.assertEqual(yggstat.mem_pressure(0, 0, None), 0.0)


class Arc(Tree):
	def arcstats(self, size, c_min):
		self.put("arcstats", "13 1 0x01 123 33456 1 2\nname                            type data\n"
			"hits                            4    100\n"
			"size                            4    %d\n"
			"c_min                           4    %d\n" % (size, c_min))
		return os.path.join(self.root, "arcstats")

	def test_shrinkable_arc_is_available(self):
		# A 32 G ZFS box at rest: a 16 G ARC with a 1 G floor.
		self.assertEqual(yggstat.arc_reclaimable(self.arcstats(16 * GIB, GIB)), 15 * GIB)

	def test_arc_at_its_floor(self):
		self.assertEqual(yggstat.arc_reclaimable(self.arcstats(GIB, 2 * GIB)), 0)

	def test_no_zfs(self):
		self.assertEqual(yggstat.arc_reclaimable(os.path.join(self.root, "missing")), 0)

	def test_sample_counts_it_as_available(self):
		m = {"MemTotal": 32 * GIB, "MemAvailable": 10 * GIB, "MemFree": 2 * GIB}
		path, arc = self.arcstats(16 * GIB, GIB), yggstat.arc_reclaimable
		with mock.patch.object(yggstat, "meminfo", lambda: m), \
				mock.patch.object(yggstat, "arc_reclaimable", lambda: arc(path)), \
				mock.patch.object(yggstat, "psi_some_avg10", lambda: 0.0):
			d = json.loads(yggstat.sample())
		self.assertEqual(d["mem"]["used"], 7 * GIB)
		self.assertAlmostEqual(d["mem"]["pressure"], 7 / 32, places=3)

	def test_available_never_passes_total(self):
		m = {"MemTotal": 32 * GIB, "MemAvailable": 20 * GIB}
		with mock.patch.object(yggstat, "meminfo", lambda: m), \
				mock.patch.object(yggstat, "arc_reclaimable", lambda: 16 * GIB):
			d = json.loads(yggstat.sample())
		self.assertEqual(d["mem"]["used"], 0)


class Zram(Tree):
	def test_device_added_later_counts(self):
		self.assertEqual(yggstat.zram_bytes(self.root), 0)
		# zramctl -f after the helper started: mem_used_total is field 3.
		self.put("block/zram0/mm_stat", "4096000 1024000 1200000 0 1200000 0 0 0 0")
		self.assertEqual(yggstat.zram_bytes(self.root), 1200000)


class Installed(Tree):
	def blocks(self, size_hex, online):
		self.put("devices/system/memory/block_size_bytes", size_hex)
		for i in range(online):
			self.put("devices/system/memory/memory%d/online" % i, "1")

	def memmap(self, *ranges):
		for i, (start, end, kind) in enumerate(ranges):
			self.put("firmware/memmap/%d/start" % i, "0x%x" % start)
			self.put("firmware/memmap/%d/end" % i, "0x%x" % end)
			self.put("firmware/memmap/%d/type" % i, kind)

	def test_online_blocks(self):
		self.blocks("8000000", 256)  # 128 MiB, hex
		self.put("devices/system/memory/memory999/online", "0")
		self.assertEqual(yggstat.installed_ram(self.root), 32 * GIB)

	def test_small_blocks_ignore_the_map(self):
		# This box: 128 MiB blocks already skip the PCI hole.
		self.blocks("8000000", 256)
		self.memmap((0, 0x9ffff, "System RAM"), (0x100000, 0xbfffffff, "System RAM"),
			(0x100000000, 0x83fffffff, "System RAM"))
		self.assertEqual(yggstat.installed_ram(self.root), 32 * GIB)

	def test_2g_blocks_read_the_firmware_map(self):
		# Bare-metal 64 GB: 2 GiB blocks, the hole below 4 GiB and the
		# remapped tail each online as a whole block, 33 of them.
		self.blocks("80000000", 33)
		self.memmap((0, 0x9ffff, "System RAM"), (0x9fc00, 0xfffff, "Reserved"),
			(0x100000, 0xbfffffff, "System RAM"), (0xc0000000, 0xffffffff, "Reserved"),
			(0x100000000, 0x103fffffff, "System RAM"))
		self.assertEqual(yggstat.installed_ram(self.root), 64 * GIB)

	def test_map_never_raises_the_blocks(self):
		self.blocks("80000000", 2)
		self.memmap((0, 0x1ffffffff, "System RAM"))
		self.assertEqual(yggstat.installed_ram(self.root), 4 * GIB)
		self.memmap((0, 0x2ffffffff, "System RAM"))
		self.assertEqual(yggstat.installed_ram(self.root), 4 * GIB)

	def test_large_blocks_without_a_map(self):
		# arm64 with 64K pages (512 MiB sections): blocks align to RAM.
		self.blocks("20000000", 16)
		self.assertEqual(yggstat.installed_ram(self.root), 8 * GIB)

	def test_no_memory_tree(self):
		self.assertEqual(yggstat.installed_ram(self.root), 0)


class Thermal(Tree):
	def hwmon(self, n, name, labels, crit=None, temps=None):
		self.put("class/hwmon/hwmon%d/name" % n, name)
		for i, lab in enumerate(labels, 1):
			if lab is not None:
				self.put("class/hwmon/hwmon%d/temp%d_label" % (n, i), lab)
			self.put("class/hwmon/hwmon%d/temp%d_input" % (n, i), str((temps or {}).get(i, 45000)))
			if crit:
				self.put("class/hwmon/hwmon%d/temp%d_crit" % (n, i), str(crit))

	def zone(self, n, kind, crit=None, passive=None):
		self.put("class/thermal/thermal_zone%d/type" % n, kind)
		self.put("class/thermal/thermal_zone%d/temp" % n, "45000")
		trips = [("passive", passive), ("critical", crit)]
		for i, (t, v) in enumerate(p for p in trips if p[1]):
			self.put("class/thermal/thermal_zone%d/trip_point_%d_type" % (n, i), t)
			self.put("class/thermal/thermal_zone%d/trip_point_%d_temp" % (n, i), str(v))

	def ends(self, paths, *tails):
		self.assertEqual(len(paths), len(tails), paths)
		for p, t in zip(paths, tails):
			self.assertTrue(p.endswith(t), (p, t))

	def test_zen3_k10temp_tctl_only(self):
		# The 5900X: Tctl, Tccd1, Tccd2 and no crit.
		self.hwmon(2, "k10temp", ["Tctl", "Tccd1", "Tccd2"])
		paths, crit, name = yggstat.find_cpu_sensor(self.root)
		self.ends(paths, "hwmon2/temp1_input")
		self.assertEqual((crit, name), (None, "k10temp"))
		self.assertEqual(yggstat.thresholds(crit, name), (80.0, 90.0, 95.0))

	def test_zen1_prefers_tdie(self):
		self.hwmon(0, "k10temp", ["Tctl", "Tdie"])
		paths, _, _ = yggstat.find_cpu_sensor(self.root)
		self.ends(paths, "hwmon0/temp2_input")

	def test_pre_zen_k10temp_unlabelled(self):
		# Phenom, FX, A-series: temp1 with no label, crit on some.
		self.hwmon(0, "k10temp", [None], crit=70000)
		paths, crit, name = yggstat.find_cpu_sensor(self.root)
		self.ends(paths, "hwmon0/temp1_input")
		self.assertEqual((crit, name), (70.0, "k10temp"))
		# That crit is HTC, and Tctl there tops out at 70 under ordinary
		# load: serious once it throttles, not at 55.
		self.assertEqual(yggstat.thresholds(crit, name), (60.0, 70.0, 75.0))

	def test_pre_zen_without_crit_tjmax_70(self):
		tj = self.cpu(0x15, 0x02, "AMD FX(tm)-8350 Eight-Core Processor")
		self.assertEqual(tj, 70.0)
		self.assertEqual(yggstat.thresholds(None, "k10temp", tj), (60.0, 70.0, 75.0))
		self.assertEqual(self.cpu(0x16, 0x30, "AMD A8-6410 APU with AMD Radeon R5 Graphics"), 70.0)
		self.assertEqual(self.cpu(0x10, 0x04, "AMD Phenom(tm) II X4 965 Processor"), 70.0)

	def test_intel_package_follows_tjmax(self):
		# coretemp's crit is Tjmax: a 13900K at 100 C under a compile is
		# serious (throttling), not critical.
		self.hwmon(1, "coretemp", ["Package id 0", "Core 0"], crit=100000)
		paths, crit, name = yggstat.find_cpu_sensor(self.root)
		self.ends(paths, "hwmon1/temp1_input")
		self.assertEqual((crit, name), (100.0, "coretemp"))
		self.assertEqual(yggstat.thresholds(crit, name), (90.0, 100.0, 105.0))

	def test_intel_without_crit_is_100(self):
		self.hwmon(1, "coretemp", ["Package id 0"])
		_, crit, name = yggstat.find_cpu_sensor(self.root)
		self.assertEqual(yggstat.thresholds(crit, name), (90.0, 100.0, 105.0))

	def test_intel_two_sockets(self):
		# One coretemp per package; both are read, the hottest counts.
		self.hwmon(1, "coretemp", ["Package id 0", "Core 0"], crit=100000)
		self.hwmon(2, "coretemp", ["Package id 1", "Core 0"], crit=100000)
		paths, _, _ = yggstat.find_cpu_sensor(self.root)
		self.ends(paths, "hwmon1/temp1_input", "hwmon2/temp1_input")

	def test_pre_sandy_bridge_reads_every_core(self):
		# Core 2 / Nehalem: no Package id, no x86_pkg_temp zone.
		self.hwmon(0, "coretemp", ["Core 0", "Core 1"], crit=105000)
		self.zone(0, "acpitz", crit=97000)
		paths, crit, name = yggstat.find_cpu_sensor(self.root)
		self.ends(paths, "hwmon0/temp1_input", "hwmon0/temp2_input")
		self.assertEqual((crit, name), (105.0, "coretemp"))

	def test_crit_wins_elsewhere(self):
		self.assertEqual(yggstat.thresholds(100.0, "cpu_thermal"), (70.0, 85.0, 95.0))
		self.assertEqual(yggstat.thresholds(90.0, "soc-thermal"), (65.0, 75.0, 85.0))
		# An AMD crit is a Tjmax stand-in, over the family table.
		self.assertEqual(yggstat.thresholds(90.0, "k10temp", 70.0), (80.0, 90.0, 95.0))

	def test_x86_pkg_temp_zone(self):
		# No coretemp driver: the package zone, Intel's tiers.
		self.zone(0, "acpitz", crit=105000)
		self.zone(1, "x86_pkg_temp", passive=0)
		paths, crit, name = yggstat.find_cpu_sensor(self.root)
		self.ends(paths, "thermal_zone1/temp")
		self.assertEqual(yggstat.thresholds(crit, name), (90.0, 100.0, 105.0))

	def test_pi_hwmon(self):
		self.hwmon(0, "cpu_thermal", [None], crit=110000)
		paths, crit, name = yggstat.find_cpu_sensor(self.root)
		self.ends(paths, "hwmon0/temp1_input")
		self.assertEqual((crit, name), (110.0, "cpu_thermal"))

	def test_rk3588_every_cpu_zone(self):
		# Rock 5 / Orange Pi 5: hyphenated zones, one per cluster; the
		# hwmon mirrors are named soc_thermal etc., not cpu_thermal.
		for n, kind in enumerate(["soc-thermal", "bigcore0-thermal", "bigcore1-thermal", "littlecore-thermal", "gpu-thermal"]):
			self.zone(n, kind, crit=(115000 if n else 120000))
			self.hwmon(n, kind.replace("-", "_"), [None])
		paths, crit, name = yggstat.find_cpu_sensor(self.root)
		self.ends(paths, *("thermal_zone%d/temp" % n for n in range(4)))
		self.assertEqual((crit, name), (115.0, "soc-thermal"))

	def test_arm_zone_names(self):
		for t in ("cpu0-thermal", "cpuss0-thermal", "cpu0-0-top-thermal", "cpu_little0-thermal", "CPU-therm",
				"cluster0-thermal", "x86_pkg_temp", "cpu_thermal", "soc_thermal"):
			self.assertTrue(yggstat.CPU_ZONE.match(t.lower().replace("-", "_")), t)
		for t in ("acpitz", "gpu-thermal", "cpu-0-0-usr", "soc_dts0", "iwlwifi_1", "TCPU"):
			self.assertFalse(yggstat.CPU_ZONE.match(t.lower().replace("-", "_")), t)

	def test_jetson(self):
		self.zone(0, "CPU-therm", crit=102500)
		self.zone(1, "GPU-therm", crit=102500)
		paths, crit, name = yggstat.find_cpu_sensor(self.root)
		self.ends(paths, "thermal_zone0/temp")
		self.assertEqual((crit, name), (102.5, "cpu-therm"))

	def test_acpitz_last(self):
		self.zone(0, "acpitz", crit=97000)
		paths, crit, name = yggstat.find_cpu_sensor(self.root)
		self.ends(paths, "thermal_zone0/temp")
		self.assertEqual((crit, name), (97.0, "acpitz"))

	def test_acpitz_placeholder_crit_is_ignored(self):
		# A Gigabyte desktop: acpitz at 16.8 C with a critical trip at 20.8 C.
		# Taken at its word, every sample would read critical.
		self.zone(0, "acpitz", crit=20800)
		paths, crit, name = yggstat.find_cpu_sensor(self.root)
		self.ends(paths, "thermal_zone0/temp")
		self.assertEqual((crit, name), (None, "acpitz"))
		self.assertEqual(yggstat.thresholds(crit, name), (70.0, 85.0, 95.0))

	def test_hottest_zone_sets_the_tier(self):
		for n, t in enumerate((45000, 101000, "garbage")):
			self.put("z%d" % n, str(t))
		saved = (yggstat.SENSOR, yggstat.THRESHOLDS, yggstat._tier)
		try:
			yggstat.SENSOR = [os.path.join(self.root, "z%d" % n) for n in range(3)]
			yggstat.THRESHOLDS, yggstat._tier = (70.0, 85.0, 95.0), 0
			self.assertEqual(yggstat.thermal(), 3)
			yggstat.SENSOR = [os.path.join(self.root, "z2")]
			self.assertEqual(yggstat.thermal(), 3)  # nothing readable: hold
		finally:
			yggstat.SENSOR, yggstat.THRESHOLDS, yggstat._tier = saved

	def cpu(self, family, model, name):
		self.put("cpuinfo", "processor\t: 0\ncpu family\t: %d\nmodel\t\t: %d\nmodel name\t: %s\n\nprocessor\t: 1" % (family, model, name))
		return yggstat.amd_tjmax(os.path.join(self.root, "cpuinfo"))

	def test_zen3_desktop_tjmax_90(self):
		tj = self.cpu(0x19, 0x21, "AMD Ryzen 9 5900X 12-Core Processor")
		self.assertEqual(yggstat.thresholds(None, "k10temp", tj), (80.0, 90.0, 95.0))

	def test_zen4_desktop_tjmax_95(self):
		# A 7950X holds 95 C through a compile: serious, not critical.
		tj = self.cpu(0x19, 0x61, "AMD Ryzen 9 7950X 16-Core Processor")
		self.assertEqual(yggstat.thresholds(None, "k10temp", tj), (85.0, 95.0, 100.0))
		self.assertEqual(self.cpu(0x1a, 0x44, "AMD Ryzen 7 9700X 8-Core Processor"), 95.0)

	def test_mobile_tjmax_100(self):
		self.assertEqual(self.cpu(0x19, 0x50, "AMD Ryzen 7 5800H with Radeon Graphics"), 100.0)
		self.assertEqual(self.cpu(0x1a, 0x24, "AMD Ryzen AI 9 HX 370 w/ Radeon 890M"), 100.0)
		self.assertEqual(yggstat.thresholds(None, "zenpower", 100.0), (90.0, 100.0, 105.0))

	def test_handhelds_tjmax_100(self):
		# The Steam Deck games at 90-100 C; so do the Ally and Legion Go.
		self.assertEqual(self.cpu(0x17, 0x90, "AMD Custom APU 0405"), 100.0)
		self.assertEqual(self.cpu(0x17, 0x91, "AMD Custom APU 0932"), 100.0)
		self.assertEqual(self.cpu(0x19, 0x74, "AMD Ryzen Z1 Extreme"), 100.0)
		self.assertEqual(self.cpu(0x19, 0x44, "AMD Ryzen Z2 Go"), 100.0)

	def test_zen4_hedt_and_server_tjmax_95(self):
		self.assertEqual(self.cpu(0x19, 0x18, "AMD Ryzen Threadripper 7980X 64-Cores"), 95.0)
		self.assertEqual(self.cpu(0x19, 0x11, "AMD EPYC 9654 96-Core Processor"), 95.0)
		self.assertEqual(self.cpu(0x17, 0x31, "AMD Ryzen Threadripper 3990X 64-Core Processor"), 90.0)
		# Zen 3 is family 0x19 too: Milan and the 5000WX stay at 90.
		self.assertEqual(self.cpu(0x19, 0x01, "AMD EPYC 7763 64-Core Processor"), 90.0)
		self.assertEqual(self.cpu(0x19, 0x08, "AMD Ryzen Threadripper PRO 5995WX 64-Cores"), 90.0)

	def test_unreadable_cpuinfo_is_90(self):
		self.assertEqual(yggstat.amd_tjmax(os.path.join(self.root, "missing")), 90.0)

	def test_no_sensor(self):
		self.assertEqual(yggstat.find_cpu_sensor(self.root), ([], None, None))


if __name__ == "__main__":
	unittest.main()
