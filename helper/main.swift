// yggstat — the NERViewer stat daemon.
//
// Prints one JSON object per line at a fixed interval. Every field is
// always present. Exits when its stdout closes (SIGPIPE on the next write)
// or when its parent dies. Foundation and Darwin only; build with
// helper/build.sh.
//
//   yggstat [--interval 500] [--once]

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

func netBytes() -> (rx: UInt64, tx: UInt64) {
    guard let list = if_nameindex() else { return (0, 0) }
    defer { if_freenameindex(list) }
    var rx: UInt64 = 0, tx: UInt64 = 0
    var p = list
    while p.pointee.if_index != 0 {
        let name = String(cString: p.pointee.if_name)
        if name != "lo0" {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(p.pointee.if_index), IFDATA_GENERAL]
            var d = ifmibdata()
            var len = MemoryLayout<ifmibdata>.size
            if sysctl(&mib, 6, &d, &len, nil, 0) == 0 {
                rx &+= d.ifmd_data.ifi_ibytes
                tx &+= d.ifmd_data.ifi_obytes
            }
        }
        p = p.advanced(by: 1)
    }
    return (rx, tx)
}

// MARK: - Sample

func fmt(_ v: Double, _ places: Int = 3) -> String {
    guard v.isFinite else { return "0" }
    return String(format: "%.\(places)f", v)
}

var prevTicks = cpuTicks()
var prevNet = netBytes()
var prevTime = Date().timeIntervalSince1970

func sample() -> String {
    let now = Date().timeIntervalSince1970
    let dt = max(now - prevTime, 0.001)

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

    let net = netBytes()
    let rxBps = Double(net.rx &- prevNet.rx) / dt
    let txBps = Double(net.tx &- prevNet.tx) / dt
    prevNet = net
    prevTime = now

    let thermal = ProcessInfo.processInfo.thermalState.rawValue
    let uptime = ProcessInfo.processInfo.systemUptime

    let coreList = cores.map { fmt($0) }.joined(separator: ",")
    return "{\"t\":\(fmt(now)),"
        + "\"cpu\":{\"cores\":[\(coreList)],\"total\":\(fmt(total)),\"perf\":\(perfCores),\"eff\":\(effCores)},"
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
