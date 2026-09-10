extends Node
## Headless probe for the stats layer. Starts with whatever Stats chose
## (it should be the helper), checks real samples, then runs every synthetic
## scenario fast and checks those. Exit 0 when green, 1 otherwise.
##
## Run: /Applications/Godot.app/Contents/MacOS/Godot --path game --headless res://tools/stats_probe.tscn

var _failures := 0
var _collected: Array[StatSample] = []


func _check(cond: bool, msg: String) -> void:
	if not cond:
		_failures += 1
		printerr("FAIL: " + msg)


func _on_sample(s: StatSample) -> void:
	_collected.append(s)


func _ready() -> void:
	Stats.sampled.connect(_on_sample)
	await _probe_helper()
	await _probe_synthetic()
	print("stats_probe: %s" % ("green" if _failures == 0 else "%d failures" % _failures))
	get_tree().quit(0 if _failures == 0 else 1)


## Every sample, from any source, must satisfy these.
func _check_sample(s: StatSample, tag: String) -> void:
	_check(s.cpu_cores.size() == s.cpu_perf_cores + s.cpu_eff_cores,
		"%s: %d cores but perf %d + eff %d" % [tag, s.cpu_cores.size(), s.cpu_perf_cores, s.cpu_eff_cores])
	for v in s.cpu_cores:
		_check(v >= 0.0 and v <= 1.0, "%s: core utilization %f out of range" % [tag, v])
	_check(s.cpu_total >= 0.0 and s.cpu_total <= 1.0, "%s: cpu_total %f" % [tag, s.cpu_total])
	_check(s.mem_total > 0 and s.mem_used > 0 and s.mem_used <= s.mem_total,
		"%s: mem used %d of %d" % [tag, s.mem_used, s.mem_total])
	_check(s.mem_pressure >= 0.0 and s.mem_pressure <= 1.0, "%s: pressure %f" % [tag, s.mem_pressure])
	_check(s.net_rx_bps >= 0.0 and s.net_tx_bps >= 0.0, "%s: negative rate" % tag)
	_check(s.thermal >= 0 and s.thermal <= 3, "%s: thermal %d" % [tag, s.thermal])
	_check(s.load.x >= 0.0, "%s: load %s" % [tag, s.load])


func _collect(count: int, timeout_ms: int) -> Array[StatSample]:
	_collected.clear()
	var start := Time.get_ticks_msec()
	while _collected.size() < count and Time.get_ticks_msec() - start < timeout_ms:
		await get_tree().process_frame
	return _collected.duplicate()


func _probe_helper() -> void:
	var name := Stats.source.source_name() if Stats.source else "none"
	_check(Stats.source is HelperStatSource, "expected the helper, got %s (%s)" % [name, Stats.status])
	if not Stats.source is HelperStatSource:
		return
	var samples := await _collect(4, 4000)
	_check(samples.size() >= 4, "helper: only %d samples in 4 s" % samples.size())
	var last_t := 0.0
	for i in samples.size():
		_check_sample(samples[i], "helper[%d]" % i)
		_check(samples[i].t > last_t, "helper[%d]: t did not increase" % i)
		last_t = samples[i].t
	if samples.size() >= 2:
		var gaps := PackedFloat32Array()
		for i in range(1, samples.size()):
			gaps.append(samples[i].t - samples[i - 1].t)
		print("helper: %d samples, gaps %s s" % [samples.size(), gaps])
		var s := samples[-1]
		print("helper: cores %s total %.3f load %s" % [s.cpu_cores, s.cpu_total, s.load])
		print("helper: mem used %.2f GiB of %.2f, pressure %.2f; net rx %.0f tx %.0f B/s; thermal %d" % [
			s.mem_used / 1073741824.0, s.mem_total / 1073741824.0, s.mem_pressure,
			s.net_rx_bps, s.net_tx_bps, s.thermal])


func _probe_synthetic() -> void:
	var syn := SyntheticStatSource.new()
	syn.speed = 40.0
	Stats.use(syn)
	_check(Stats.source == syn, "Stats.use did not switch to the synthetic source")
	for scenario in SyntheticStatSource.SCENARIOS:
		syn.set_scenario(scenario)
		var samples := await _collect(240, 6000)  # two simulated minutes
		_check(samples.size() >= 200, "%s: only %d samples" % [scenario, samples.size()])
		var peak_total := 0.0
		var peak_core := 0.0
		var peak_rx := 0.0
		var peak_pressure := 0.0
		for i in samples.size():
			var s := samples[i]
			_check_sample(s, "%s[%d]" % [scenario, i])
			peak_total = maxf(peak_total, s.cpu_total)
			peak_rx = maxf(peak_rx, s.net_rx_bps)
			peak_pressure = maxf(peak_pressure, s.mem_pressure)
			for v in s.cpu_cores:
				peak_core = maxf(peak_core, v)
		match scenario:
			"idle":
				_check(peak_total < 0.15, "idle: peak total %.2f is not idle" % peak_total)
			"ramp":
				_check(peak_total > 0.8, "ramp: peak total %.2f never ramped" % peak_total)
			"spike":
				_check(peak_core > 0.9, "spike: peak core %.2f never spiked" % peak_core)
			"download":
				_check(peak_rx > 1.0e7, "download: peak rx %.0f never climbed" % peak_rx)
			"pressure":
				_check(peak_pressure > 0.6, "pressure: peak %.2f never rose" % peak_pressure)
		print("%s: %d samples, peak total %.2f core %.2f rx %.0f pressure %.2f" % [
			scenario, samples.size(), peak_total, peak_core, peak_rx, peak_pressure])

