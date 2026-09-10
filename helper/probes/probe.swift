import Foundation
import Darwin

// per-core CPU ticks
func cpuTicks() -> [[UInt32]] {
    var count: natural_t = 0
    var info: processor_info_array_t? = nil
    var infoCount: mach_msg_type_number_t = 0
    let r = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
    guard r == KERN_SUCCESS, let info = info else { return [] }
    defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
    var out: [[UInt32]] = []
    for i in 0..<Int(count) {
        let b = Int(i) * Int(CPU_STATE_MAX)
        out.append([UInt32(info[b+Int(CPU_STATE_USER)]), UInt32(info[b+Int(CPU_STATE_SYSTEM)]), UInt32(info[b+Int(CPU_STATE_IDLE)]), UInt32(info[b+Int(CPU_STATE_NICE)])])
    }
    return out
}
// vm stats
func vmStats() -> vm_statistics64 {
    var s = vm_statistics64()
    var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &s) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) } }
    return s
}
// net via NET_RT_IFLIST2
func netBytes() -> (UInt64, UInt64) {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return (0,0) }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0,0) }
    var rx: UInt64 = 0, tx: UInt64 = 0
    var off = 0
    buf.withUnsafeBytes { raw in
        while off + MemoryLayout<if_msghdr>.size <= len {
            let hdr = raw.load(fromByteOffset: off, as: if_msghdr.self)
            if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                let h2 = raw.load(fromByteOffset: off, as: if_msghdr2.self)
                if (h2.ifm_flags & IFF_LOOPBACK) == 0 { rx += h2.ifm_data.ifi_ibytes; tx += h2.ifm_data.ifi_obytes }
            }
            off += Int(hdr.ifm_msglen)
        }
    }
    return (rx, tx)
}
let t = cpuTicks(); let v = vmStats(); let n = netBytes()
var load = [Double](repeating: 0, count: 3); getloadavg(&load, 3)
var lvl: Int32 = 0; var sz = MemoryLayout<Int32>.size; sysctlbyname("kern.memorystatus_level", &lvl, &sz, nil, 0)
print("cores=\(t.count) first=\(t.first ?? []) wired_pages=\(v.wire_count) compressor=\(v.compressor_page_count) rx=\(n.0) tx=\(n.1) load=\(load) memlevel=\(lvl) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) ppid=\(getppid())")
