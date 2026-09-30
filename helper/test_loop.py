#!/usr/bin/env python3
# yggstat's loop and clock: a bad reading skips a tick instead of ending the
# helper, a non-UTF-8 byte in a /proc file is no bad reading, and the net
# rates keep time on CLOCK_MONOTONIC. Standard library only.
#
#   python3 helper/test_loop.py -v

import importlib.util
import io
import json
import os
import shutil
import tempfile
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("yggstat", os.path.join(HERE, "yggstat.py"))
yggstat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(yggstat)  # reads this machine once; harmless


class Read(unittest.TestCase):
	def test_non_utf8_bytes_do_not_raise(self):
		# An interface name may be any bytes but '/' and whitespace.
		root = tempfile.mkdtemp(prefix="yggstat-")
		try:
			path = os.path.join(root, "dev")
			with open(path, "wb") as f:
				f.write(b"Inter-|\n face |\n  et\xffh0: 100 1 0 0 0 0 0 0 200 2 0 0 0 0 0 0\n")
			text = yggstat.read(path)
			_, _, rest = text.splitlines()[2].partition(":")
			self.assertEqual(rest.split()[0], "100")
		finally:
			shutil.rmtree(root)


class Loop(unittest.TestCase):
	def run_main(self, samples, ticks, once=False, interval=50):
		"""main() over `samples` (a str, or an exception to raise), ending
		after `ticks` passes by pretending the parent died; (stdout, stderr)."""
		it = iter(samples)

		def sample():
			s = next(it)
			if isinstance(s, Exception):
				raise s
			return s

		def _exit(code):
			# The real one would end this test run too, and with status 0.
			raise AssertionError("helper exited (%d)" % code)

		parent = os.getppid()
		ppids = iter([parent] + [parent] * (ticks - 1) + [1])
		out, err = io.StringIO(), io.StringIO()
		with mock.patch.object(yggstat, "sample", sample), \
				mock.patch.object(yggstat, "once", once), \
				mock.patch.object(yggstat, "interval_ms", interval), \
				mock.patch.object(yggstat.os, "getppid", lambda: next(ppids)), \
				mock.patch.object(yggstat.os, "_exit", _exit), \
				mock.patch.object(yggstat.signal, "signal", lambda *a: None), \
				mock.patch.object(yggstat.sys, "stdout", out), \
				mock.patch.object(yggstat.sys, "stderr", err):
			yggstat.main()
		return out.getvalue(), err.getvalue()

	def test_bad_sample_skips_a_tick(self):
		out, err = self.run_main([UnicodeDecodeError("utf-8", b"\xff", 0, 1, "bad"), '{"a":1}', '{"a":2}'], 3)
		self.assertEqual(out, '{"a":1}\n{"a":2}\n')
		self.assertIn("UnicodeDecodeError", err)

	def test_persistent_failure_is_rate_limited(self):
		out, err = self.run_main([ValueError("x")] * 8, 8)
		self.assertEqual(out, "")
		self.assertEqual(err.count("Traceback"), 3)

	def test_stderr_stays_bounded(self):
		# Nobody drains stderr while the helper runs: a helper failing for
		# days must not fill the pipe and block in the write.
		out, err = self.run_main([ValueError("x")] * 30000, 30000, interval=0)
		self.assertEqual(err.count("Traceback"), 3)
		self.assertEqual(err.count("samples failed"), 20)
		self.assertTrue(err.rstrip().endswith("ValueError: x"), err[-200:])
		self.assertLess(len(err), 16384)

	def test_once_fails_loudly(self):
		with self.assertRaises(SystemExit) as cm:
			self.run_main([ValueError("x")], 1, once=True)
		self.assertEqual(cm.exception.code, 1)


class NetClock(unittest.TestCase):
	def test_wall_clock_step_back_does_not_spike(self):
		# timesyncd steps the clock back 5 s between two samples: 1000 bytes
		# over a real second stay about 1000 B/s, not 1000 / 0.001.
		saved = (yggstat.prev_net, yggstat.prev_mono)
		real = time.time()
		try:
			yggstat.prev_net = {"eth0": (0, 0)}
			yggstat.prev_mono = time.monotonic() - 1.0
			with mock.patch.object(yggstat, "net_bytes", lambda: {"eth0": (1000, 500)}), \
					mock.patch.object(yggstat, "hw_interfaces", lambda: {"eth0"}), \
					mock.patch.object(yggstat.time, "time", lambda: real - 5.0):
				d = json.loads(yggstat.sample())
			self.assertAlmostEqual(d["net"]["rx_bps"], 1000.0, delta=50.0)
			self.assertAlmostEqual(d["net"]["tx_bps"], 500.0, delta=25.0)
			self.assertAlmostEqual(d["t"], real - 5.0, delta=0.01)
		finally:
			yggstat.prev_net, yggstat.prev_mono = saved


if __name__ == "__main__":
	unittest.main()
