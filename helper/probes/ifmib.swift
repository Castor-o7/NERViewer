import Foundation
let idx = Int32(if_nametoindex("en0"))
var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, idx, IFDATA_GENERAL]
var len = 0
guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { print("size fail", errno); exit(1) }
var buf = [UInt8](repeating: 0, count: len)
guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { print("read fail", errno); exit(1) }
print("ifmibdata len=\(len) sizeof=\(MemoryLayout<ifmibdata>.size)")
buf.withUnsafeBytes { raw in
    let d = raw.load(as: ifmibdata.self)
    print("name=\(String(cString: [d.ifmd_name.0,d.ifmd_name.1,d.ifmd_name.2].map{UInt8(bitPattern:$0)} + [0])) ibytes=\(d.ifmd_data.ifi_ibytes) obytes=\(d.ifmd_data.ifi_obytes)")
    // also scan for the netstat value's 64-bit form anywhere in the struct
    for o in stride(from: 0, to: len - 8, by: 4) { let v = raw.loadUnaligned(fromByteOffset: o, as: UInt64.self); if v > 2_000_000_000_000 && v < 2_100_000_000_000 { print("64-bit candidate at +\(o): \(v)") } }
}
