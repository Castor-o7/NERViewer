#!/usr/bin/env python3
# yggstat's Linux readings that stand in for a Mac's: memory pressure,
# installed RAM and the thermal tiers, each against a fake /sys or plain
# numbers. Standard library only.
#
#   python3 helper/test_readings.py -v

import importlib.util
import os
import shutil
import tempfile
import unittest

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


class Installed(Tree):
	def test_online_blocks(self):
		self.put("devices/system/memory/block_size_bytes", "8000000")  # 128 MiB, hex
		for i in range(256):
			self.put("devices/system/memory/memory%d/online" % i, "1")
		self.put("devices/system/memory/memory999/online", "0")
		self.assertEqual(yggstat.installed_ram(self.root), 32 * GIB)

	def test_no_memory_tree(self):
		self.assertEqual(yggstat.installed_ram(self.root), 0)


class Thermal(Tree):
	def hwmon(self, n, name, labels, crit=None):
		self.put("class/hwmon/hwmon%d/name" % n, name)
		for i, lab in enumerate(labels, 1):
			self.put("class/hwmon/hwmon%d/temp%d_label" % (n, i), lab)
			self.put("class/hwmon/hwmon%d/temp%d_input" % (n, i), "45000")
			if crit:
				self.put("class/hwmon/hwmon%d/temp%d_crit" % (n, i), str(crit))

	def test_zen3_k10temp_tctl_only(self):
		# The 5900X: Tctl, Tccd1, Tccd2 and no crit.
		self.hwmon(2, "k10temp", ["Tctl", "Tccd1", "Tccd2"])
		path, crit, name = yggstat.find_cpu_sensor(self.root)
		self.assertTrue(path.endswith("hwmon2/temp1_input"))
		self.assertEqual((crit, name), (None, "k10temp"))
		self.assertEqual(yggstat.thresholds(crit, name), (80.0, 90.0, 95.0))

	def test_zen1_prefers_tdie(self):
		self.hwmon(0, "k10temp", ["Tctl", "Tdie"])
		path, _, _ = yggstat.find_cpu_sensor(self.root)
		self.assertTrue(path.endswith("hwmon0/temp2_input"))

	def test_intel_keeps_its_tiers(self):
		self.hwmon(1, "coretemp", ["Package id 0", "Core 0"])
		path, crit, name = yggstat.find_cpu_sensor(self.root)
		self.assertTrue(path.endswith("hwmon1/temp1_input"))
		self.assertEqual(yggstat.thresholds(crit, name), (70.0, 85.0, 95.0))

	def test_crit_wins(self):
		self.hwmon(1, "coretemp", ["Package id 0"], crit=100000)
		_, crit, name = yggstat.find_cpu_sensor(self.root)
		self.assertEqual(yggstat.thresholds(crit, name), (70.0, 85.0, 95.0))
		self.assertEqual(yggstat.thresholds(90.0, "k10temp"), (65.0, 75.0, 85.0))

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

	def test_unreadable_cpuinfo_is_90(self):
		self.assertEqual(yggstat.amd_tjmax(os.path.join(self.root, "missing")), 90.0)

	def test_no_sensor(self):
		self.assertEqual(yggstat.find_cpu_sensor(self.root), (None, None, None))


if __name__ == "__main__":
	unittest.main()
