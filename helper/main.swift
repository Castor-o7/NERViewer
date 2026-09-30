// yggstat — the NERViewer stat daemon.
//
// Prints one JSON object per line at a fixed interval. Every field is
// always present. Exits when its stdout closes (SIGPIPE on the next write)
// or when its parent dies. Foundation and Darwin only; build with
// helper/build.sh.
//
//   yggstat [--interval 500] [--once]
//
// cpu, the values the core rings show (the full contract, and the Linux
// kinds, are in yggstat.py's header):
//
//   Apple Silicon  cores: one per logical CPU, which is one per core (no
//                  SMT), in host_processor_info order, E-cores first.
//                  perf/eff: hw.perflevel0/1.logicalcpu. No inner or
//                  inner_kind: the reader takes inner = eff, kind eff.
//                  This line is byte for byte what it was before Intel
//                  Macs were handled; keep it so. When perf + eff is not
//                  the value count (macOS 11 has no perflevel sysctls),
//                  it says so as Intel does: perf = count, eff 0, inner
//                  0, kind none, every core on the outer ring.
//   Intel Mac      No perflevels. perf: hw.physicalcpu, eff: 0.
//                  With Hyper-Threading (logical == 2 * physical), kind
//                  smt: each core's second thread on the inner ring, its
//                  first on the outer, as Linux does on a one-cluster SMT
//                  CPU; cores has 2 * perf values and inner = perf.
//                  Otherwise kind none, inner 0, one value per core.
//                  total: the mean over physical cores with a core's two
//                  threads merged as 1 - (1-a)(1-b), as on Linux, so the
//                  headline means the same whatever the rings show.
//
// ASSUMPTION, to verify on an Intel Mac: XNU numbers logical CPUs in
// local APIC ID order, and the two threads of a core differ only in the
// APIC ID's lowest bit, so CPUs 2k and 2k+1 are one core's two threads.
// Activity Monitor's CPU History shows the odd-numbered CPUs idling as
// second threads do, which agrees. If a machine numbers them otherwise
// (all first threads, then all second threads, as Linux does), the rings
// still show every thread truthfully but a core's two threads land in
// different slices. Check with a single-threaded load pinned by the
// scheduler: one outer slice and the inner slice under it should never
// be busy at once far above chance. Uncompiled when written (no swiftc
// on the Linux box, 2026-09-29).

import Foundation
import Darwin

// MARK: - Arguments

var intervalMs = 500
var once = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--interval": if let v = args.next(), let n = Int(v), n >= 50 { intervalMs = n }
    case "--once": once = true
    default: break
    }
}

// MARK: - Static facts

func sysctlInt(_ name: String) -> Int64 {
    var v: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return 0 }
    return size == 4 ? Int64(Int32(truncatingIfNeeded: v)) : v
}

let perfCores = Int(sysctlInt("hw.perflevel0.logicalcpu"))
let effCores = Int(sysctlInt("hw.perflevel1.logicalcpu"))
/// Every Apple Silicon Mac has E-cores; arm64 says so even if one did not.
let appleSilicon = effCores > 0 || sysctlInt("hw.optional.arm64") == 1
let physicalCores = Int(sysctlInt("hw.physicalcpu"))
let memTotal = sysctlInt("hw.memsize")
var pageSize: vm_size_t = 0
host_page_size(mach_host_self(), &pageSize)

// MARK: - CPU

struct CoreTicks { var user, system, idle, nice: UInt64 }

func cpuTicks() -> [CoreTicks] {
    var count: natural_t = 0
    var info: processor_info_array_t? = nil
    var infoCount: mach_msg_type_number_t = 0
    let r = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
    guard r == KERN_SUCCESS, let info = info else { return [] }
    defer {
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                      vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
    }
    var out: [CoreTicks] = []
    for i in 0..<Int(count) {
        let b = i * Int(CPU_STATE_MAX)
        out.append(CoreTicks(user: UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)])),
                             system: UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)])),
                             idle: UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)])),
                             nice: UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))))
    }
    return out
}

/// Utilization per core from two tick readings. Tick counters are 32-bit
/// and wrap; the subtraction is done modulo 2^32.
func cpuUtil(_ prev: [CoreTicks], _ cur: [CoreTicks]) -> [Double] {
    guard prev.count == cur.count else { return cur.map { _ in 0.0 } }
    func d(_ a: UInt64, _ b: UInt64) -> Double { Double((b &- a) & 0xFFFF_FFFF) }
    return zip(prev, cur).map { p, c in
        let idle = d(p.idle, c.idle)
        let total = idle + d(p.user, c.user) + d(p.system, c.system) + d(p.nice, c.nice)
        return total > 0 ? max(0, min(1, 1 - idle / total)) : 0
    }
}

/// How an Intel Mac's per-CPU values go onto the rings: the logical CPU
/// behind each value, inner ring first, and the counts that describe it.
struct IntelLayout {
    let order: [Int]
    let perf: Int
    let inner: Int
    let kind: String
}

/// `n` is the number of logical CPUs host_processor_info returned. See
/// the assumption in the header about which CPUs are siblings.
func intelLayout(_ n: Int) -> IntelLayout {
    if physicalCores > 0 && n == 2 * physicalCores {
        let first = (0..<physicalCores).map { 2 * $0 }
        let second = first.map { $0 + 1 }
        return IntelLayout(order: second + first, perf: physicalCores, inner: physicalCores, kind: "smt")
    }
    return IntelLayout(order: Array(0..<n), perf: n, inner: 0, kind: "none")
}

// MARK: - Memory

func vmStats() -> vm_statistics64 {
    var s = vm_statistics64()
    var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c)
        }
    }
    return s
}

// MARK: - Network
//
// The ifmib sysctl is the only source with true 64-bit counters on this OS;
// NET_RT_IFLIST2 and getifaddrs both truncate to 32 bits (verified 2026-09-09).
//
// Only hardware links count, as on Linux, so tunnel and VM traffic is not
// counted twice (once on utun/bridge, again on en0): link type Ethernet
// (Wi-Fi reports it too) or cellular, minus vmenet* and bridge*, which are
// virtual but may claim Ethernet. utun/ipsec are IFT_OTHER, bridges
// IFT_BRIDGE. If none match, every interface but lo0.

struct IfBytes { var rx, tx: UInt64 }

func netCounters() -> [String: IfBytes] {
    guard let list = if_nameindex() else { return [:] }
    defer { if_freenameindex(list) }
    var all: [String: IfBytes] = [:], hw: [String: IfBytes] = [:]
    var p = list
    while p.pointee.if_index != 0 {
        let name = String(cString: p.pointee.if_name)
        if name != "lo0" {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(p.pointee.if_index), IFDATA_GENERAL]
            var d = ifmibdata()
            var len = MemoryLayout<ifmibdata>.size
            if sysctl(&mib, 6, &d, &len, nil, 0) == 0 {
                let b = IfBytes(rx: d.ifmd_data.ifi_ibytes, tx: d.ifmd_data.ifi_obytes)
                all[name] = b
                let t = d.ifmd_data.ifi_type  // 0x06 IFT_ETHER, 0xff IFT_CELLULAR
                if (t == 0x06 || t == 0xff) && !name.hasPrefix("vmenet") && !name.hasPrefix("bridge") {
                    hw[name] = b
                }
            }
        }
        p = p.advanced(by: 1)
    }
    return hw.isEmpty ? all : hw
}

/// Bytes per second from two readings, per interface: one that is new has
/// only its baseline this time, one whose counter went backwards was reset
/// and is skipped once, one that vanished is gone. A sum over interfaces
/// would drop when one leaves and wrap to exabytes.
func netRate(_ prev: [String: IfBytes], _ cur: [String: IfBytes], _ dt: Double) -> (rx: Double, tx: Double) {
    var rx: UInt64 = 0, tx: UInt64 = 0
    for (name, c) in cur {
        guard let p = prev[name] else { continue }
        if c.rx >= p.rx { rx &+= c.rx - p.rx }
        if c.tx >= p.tx { tx &+= c.tx - p.tx }
    }
    return (Double(rx) / dt, Double(tx) / dt)
}

// MARK: - Sample

func fmt(_ v: Double, _ places: Int = 3) -> String {
    guard v.isFinite else { return "0" }
    return String(format: "%.\(places)f", v)
}

var prevTicks = cpuTicks()
var prevNet = netCounters()
/// Rates divide by monotonic time: the wall clock can step (NTP, timed
/// after wake, by hand) and a step back would multiply them. Wall time is
/// only for `t`.
var prevMono = ProcessInfo.processInfo.systemUptime

func sample() -> String {
    let now = Date().timeIntervalSince1970
    let mono = ProcessInfo.processInfo.systemUptime
    let dt = max(mono - prevMono, 0.001)

    let ticks = cpuTicks()
    let cores = cpuUtil(prevTicks, ticks)
    prevTicks = ticks
    let total = cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count)

    var load = [Double](repeating: 0, count: 3)
    getloadavg(&load, 3)

    let vm = vmStats()
    let ps = Int64(pageSize)
    let wired = Int64(vm.wire_count) * ps
    let active = Int64(vm.active_count) * ps
    let compressed = Int64(vm.compressor_page_count) * ps
    let free = (Int64(vm.free_count) + Int64(vm.speculative_count)) * ps
    let level = Double(sysctlInt("kern.memorystatus_level"))
    let pressure = max(0, min(1, 1 - level / 100))

    let net = netCounters()
    let (rxBps, txBps) = netRate(prevNet, net, dt)
    prevNet = net
    prevMono = mono

    let thermal = ProcessInfo.processInfo.thermalState.rawValue
    let uptime = ProcessInfo.processInfo.systemUptime

    let cpu: String
    if appleSilicon && perfCores + effCores == cores.count {
        let coreList = cores.map { fmt($0) }.joined(separator: ",")
        cpu = "\"cpu\":{\"cores\":[\(coreList)],\"total\":\(fmt(total)),\"perf\":\(perfCores),\"eff\":\(effCores)},"
    } else if appleSilicon {
        // No P/E split to trust (macOS 11): every core on the outer ring.
        let coreList = cores.map { fmt($0) }.joined(separator: ",")
        cpu = "\"cpu\":{\"cores\":[\(coreList)],\"total\":\(fmt(total)),\"perf\":\(cores.count),\"eff\":0,"
            + "\"inner\":0,\"inner_kind\":\"none\"},"
    } else {
        let l = intelLayout(cores.count)
        let coreList = l.order.map { fmt(cores[$0]) }.joined(separator: ",")
        var merged = total
        if l.kind == "smt" && l.inner > 0 {
            // One core's threads are order[i] and order[i + inner].
            let busy = (0..<l.inner).map { i -> Double in
                1 - (1 - cores[l.order[i]]) * (1 - cores[l.order[i + l.inner]])
            }
            merged = busy.reduce(0, +) / Double(l.inner)
        }
        cpu = "\"cpu\":{\"cores\":[\(coreList)],\"total\":\(fmt(merged)),\"perf\":\(l.perf),\"eff\":0,"
            + "\"inner\":\(l.inner),\"inner_kind\":\"\(l.kind)\"},"
    }
    return "{\"t\":\(fmt(now)),"
        + cpu
        + "\"load\":[\(fmt(load[0], 2)),\(fmt(load[1], 2)),\(fmt(load[2], 2))],"
        + "\"mem\":{\"total\":\(memTotal),\"used\":\(wired + active + compressed),\"wired\":\(wired),"
        + "\"compressed\":\(compressed),\"free\":\(free),\"pressure\":\(fmt(pressure))},"
        + "\"net\":{\"rx_bps\":\(fmt(max(0, rxBps), 1)),\"tx_bps\":\(fmt(max(0, txBps), 1))},"
        + "\"thermal\":\(thermal),"
        + "\"uptime\":\(fmt(uptime, 1))}"
}

// MARK: - Loop

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_DFL)

// The first reading needs a baseline; wait one short interval so the first
// line carries real rates instead of zeros.
usleep(UInt32(min(intervalMs, 250)) * 1000)

while true {
    print(sample())
    if once || getppid() == 1 { break }
    usleep(UInt32(intervalMs) * 1000)
}
