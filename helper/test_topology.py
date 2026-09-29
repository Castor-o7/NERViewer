#!/usr/bin/env python3
# Fake machines for yggstat's core_order: each test builds a /sys tree
# holding only the topology a real one of that CPU has, points yggstat at
# it and checks what the rings would show. Standard library only.
#
#   python3 helper/test_topology.py -v

import importlib.util
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("yggstat", os.path.join(HERE, "yggstat.py"))
yggstat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(yggstat)  # reads this machine once; harmless


def cpulist(cpus):
	"""[0, 1, 2, 5] -> '0-2,5'"""
	cpus = sorted(cpus)
	out, i = [], 0
	while i < len(cpus):
		j = i
		while j + 1 < len(cpus) and cpus[j + 1] == cpus[j] + 1:
			j += 1
		out.append(str(cpus[i]) if i == j else "%d-%d" % (cpus[i], cpus[j]))
		i = j + 1
	return ",".join(out)


class Machine:
	"""A fake /sys. `cores` is a list of thread tuples (the SMT siblings of
	each physical core); `l3` a list of CPU lists sharing a last-level
	cache (omit for none); `rank`, `capacity` {cpu: value}; `hybrid`
	(p_cpus, e_cpus) for Intel's cpu_core / cpu_atom."""

	def __init__(self, root, cores, l3=None, rank=None, capacity=None, hybrid=None):
		self.root = root
		self.present = sorted(c for k in cores for c in k)
		for k in cores:
			for c in k:
				self.put(c, "topology/thread_siblings_list", cpulist(k))
				self.put(c, "topology/die_id", "0")
		for group in l3 or []:
			for c in group:
				self.put(c, "cache/index3/shared_cpu_list", cpulist(group))
		for c, v in (rank or {}).items():
			self.put(c, "cpufreq/amd_pstate_prefcore_ranking", str(v))
		for c, v in (capacity or {}).items():
			self.put(c, "cpu_capacity", str(v))
		if hybrid:
			self.write("devices/cpu_core/cpus", cpulist(hybrid[0]))
			self.write("devices/cpu_atom/cpus", cpulist(hybrid[1]))

	def write(self, rel, text):
		path = os.path.join(self.root, rel)
		os.makedirs(os.path.dirname(path), exist_ok=True)
		with open(path, "w") as f:
			f.write(text + "\n")

	def put(self, cpu, leaf, text):
		self.write("devices/system/cpu/cpu%d/%s" % (cpu, leaf), text)


class Topology(unittest.TestCase):
	def setUp(self):
		self.root = tempfile.mkdtemp(prefix="yggsys-")
		self._saved = (yggstat.SYSFS, yggstat.INNER_WHEN_SINGLE_CLUSTER)
		yggstat.SYSFS = self.root

	def tearDown(self):
		yggstat.SYSFS, yggstat.INNER_WHEN_SINGLE_CLUSTER = self._saved
		shutil.rmtree(self.root)

	def order(self, m):
		return yggstat.core_order(m.present)

	def contract(self, slots, perf, eff, inner, kind):
		"""The header's rules, true in every mode."""
		self.assertIn(kind, ("eff", "cluster", "smt", "none"))
		self.assertEqual(len(slots), perf + eff + (inner if kind == "smt" else 0))
		self.assertTrue(0 <= inner <= len(slots))
		if kind == "eff":
			self.assertEqual(inner, eff)
		else:
			self.assertEqual(eff, 0)
		self.assertEqual(inner == 0, kind == "none")
		flat = sorted(c for s in slots for c in s)
		self.assertEqual(len(flat), len(set(flat)), "a CPU shown twice")

	def test_ryzen_5900x(self):
		# 12 cores / 24 threads, two CCDs; Linux numbers the second threads
		# 12-23. The scheduler's favourite core is on the second CCD here.
		cores = [(k, k + 12) for k in range(12)]
		ccd0 = [c for k in cores[:6] for c in k]
		ccd1 = [c for k in cores[6:] for c in k]
		rank = {c: 166 for c in range(24)}
		rank[8] = 216
		m = Machine(self.root, cores, l3=[ccd0, ccd1], rank=rank)
		slots, perf, eff, inner, kind = self.order(m)
		self.contract(slots, perf, eff, inner, kind)
		self.assertEqual((perf, eff, inner, kind), (12, 0, 6, "cluster"))
		self.assertEqual(slots[:6], cores[6:])
		self.assertEqual(slots[6:], cores[:6])

	def test_ryzen_5900x_tie_keeps_first_ccd(self):
		cores = [(k, k + 12) for k in range(12)]
		m = Machine(self.root, cores, l3=[[c for k in cores[:6] for c in k], [c for k in cores[6:] for c in k]])
		slots, perf, eff, inner, kind = self.order(m)
		self.assertEqual((inner, kind), (6, "cluster"))
		self.assertEqual(slots, cores)

	def test_ryzen_5600x(self):
		# 6 cores / 12 threads, one CCD: (a) each core's second thread
		# inside, its first outside, slot for slot.
		cores = [(k, k + 6) for k in range(6)]
		m = Machine(self.root, cores, l3=[list(range(12))], rank={c: 200 for c in range(12)})
		slots, perf, eff, inner, kind = self.order(m)
		self.contract(slots, perf, eff, inner, kind)
		self.assertEqual((perf, eff, inner, kind), (6, 0, 6, "smt"))
		self.assertEqual(slots[:6], [(k + 6,) for k in range(6)])
		self.assertEqual(slots[6:], [(k,) for k in range(6)])

	def test_ryzen_5600x_average_is_not_built(self):
		# The switch point's other side reads as none until (b) exists.
		yggstat.INNER_WHEN_SINGLE_CLUSTER = "average"
		cores = [(k, k + 6) for k in range(6)]
		m = Machine(self.root, cores, l3=[list(range(12))])
		slots, perf, eff, inner, kind = self.order(m)
		self.contract(slots, perf, eff, inner, kind)
		self.assertEqual((perf, inner, kind), (6, 0, "none"))
		self.assertEqual(slots, cores)

	def test_intel_i7_9700k(self):
		# 8 cores, no SMT, one L3: nothing for the inner ring.
		cores = [(k,) for k in range(8)]
		m = Machine(self.root, cores, l3=[list(range(8))], capacity={c: 1024 for c in range(8)})
		slots, perf, eff, inner, kind = self.order(m)
		self.contract(slots, perf, eff, inner, kind)
		self.assertEqual((perf, eff, inner, kind), (8, 0, 0, "none"))
		self.assertEqual(slots, cores)

	def test_intel_i7_12700_hybrid(self):
		# 8 P-cores with HT (siblings adjacent, 0-15), 4 E-cores (16-19).
		p = [(2 * k, 2 * k + 1) for k in range(8)]
		e = [(16 + k,) for k in range(4)]
		m = Machine(self.root, p + e, l3=[list(range(20))],
			hybrid=(list(range(16)), list(range(16, 20))))
		slots, perf, eff, inner, kind = self.order(m)
		self.contract(slots, perf, eff, inner, kind)
		self.assertEqual((perf, eff, inner, kind), (8, 4, 4, "eff"))
		self.assertEqual(slots, e + p)

	def test_arm_big_little(self):
		# 4 little (capacity 446) + 4 big (1024), no L3 in sysfs.
		cores = [(k,) for k in range(8)]
		cap = {c: (446 if c < 4 else 1024) for c in range(8)}
		m = Machine(self.root, cores, capacity=cap)
		slots, perf, eff, inner, kind = self.order(m)
		self.contract(slots, perf, eff, inner, kind)
		self.assertEqual((perf, eff, inner, kind), (4, 4, 4, "eff"))
		self.assertEqual(slots, cores)

	def test_arm_big_little_listed_big_first(self):
		# Some SoCs number the big cores first; the littles still go inside.
		cores = [(k,) for k in range(8)]
		cap = {c: (1024 if c < 4 else 380) for c in range(8)}
		m = Machine(self.root, cores, capacity=cap)
		slots, perf, eff, inner, kind = self.order(m)
		self.assertEqual((perf, eff, inner, kind), (4, 4, 4, "eff"))
		self.assertEqual(slots, cores[4:] + cores[:4])

	def test_arm_three_tiers(self):
		# 1 prime + 3 big + 4 little: only the littles are E-cores.
		cores = [(k,) for k in range(8)]
		cap = {0: 400, 1: 400, 2: 400, 3: 400, 4: 860, 5: 860, 6: 860, 7: 1024}
		m = Machine(self.root, cores, capacity=cap)
		slots, perf, eff, inner, kind = self.order(m)
		self.contract(slots, perf, eff, inner, kind)
		self.assertEqual((perf, eff, inner, kind), (4, 4, 4, "eff"))

	def test_close_capacities_are_not_little(self):
		# A kernel that scales x86 capacity by boost rank: no E-cores.
		cores = [(k, k + 6) for k in range(6)]
		cap = {c: 1024 - 12 * (c % 6) for c in range(12)}
		m = Machine(self.root, cores, l3=[list(range(12))], capacity=cap)
		self.assertEqual(self.order(m)[4], "smt")

	def test_threadripper_3990x(self):
		# 64 cores / 128 threads. Zen 2 shares L3 per CCX (4 cores), two
		# per CCD: 8 CCDs are 16 cache clusters. Favourite core 37.
		cores = [(k, k + 64) for k in range(64)]
		l3 = [[c for k in cores[4 * g:4 * g + 4] for c in k] for g in range(16)]
		rank = {c: 150 for c in range(128)}
		rank[37] = 255
		m = Machine(self.root, cores, l3=l3, rank=rank)
		slots, perf, eff, inner, kind = self.order(m)
		self.contract(slots, perf, eff, inner, kind)
		self.assertEqual((perf, eff, inner, kind), (64, 0, 4, "cluster"))
		self.assertEqual(slots[:4], cores[36:40])

	def test_partial_smt_reads_as_none(self):
		# One sibling offlined: the rings would no longer pair up.
		cores = [(k, k + 4) for k in range(4)]
		m = Machine(self.root, cores, l3=[list(range(8))])
		present = [c for c in m.present if c != 7]
		slots, perf, eff, inner, kind = yggstat.core_order(present)
		self.contract(slots, perf, eff, inner, kind)
		self.assertEqual((perf, inner, kind), (4, 0, "none"))

	def test_util_per_thread_under_smt(self):
		# The smt slots carry one thread each: no merging.
		cores = [(k, k + 2) for k in range(2)]
		m = Machine(self.root, cores, l3=[list(range(4))])
		saved = yggstat.ORDER
		try:
			yggstat.ORDER = self.order(m)[0]
			prev = {c: (0, 0) for c in range(4)}
			cur = {0: (50, 100), 1: (100, 100), 2: (0, 100), 3: (75, 100)}
			self.assertEqual(yggstat.cpu_util(prev, cur), [1.0, 0.25, 0.5, 0.0])
		finally:
			yggstat.ORDER = saved

	def test_total_merges_threads_under_smt(self):
		# The headline under smt equals the old merged-core total.
		cores = [(k, k + 2) for k in range(2)]
		m = Machine(self.root, cores, l3=[list(range(4))])
		prev = {c: (0, 0) for c in range(4)}
		cur = {0: (50, 100), 1: (100, 100), 2: (0, 100), 3: (75, 100)}
		saved = yggstat.ORDER
		try:
			slots, perf, eff, inner, kind = self.order(m)
			yggstat.ORDER = slots
			split = yggstat.cpu_total(yggstat.cpu_util(prev, cur), kind, inner)
			yggstat.ORDER = cores  # the unsplit cores, threads merged
			merged = yggstat.cpu_util(prev, cur)
			self.assertAlmostEqual(split, sum(merged) / len(merged))
			self.assertAlmostEqual(split, 0.625)
		finally:
			yggstat.ORDER = saved


if __name__ == "__main__":
	unittest.main()
