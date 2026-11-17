import Foundation
import Darwin
import IOKit

// MARK: - CPU

struct CPUSample {
    var total: Double = 0        // 0...1
    var user: Double = 0
    var system: Double = 0
    var perCore: [Double] = []   // each 0...1
}

/// Reads cumulative per-core ticks via Mach;差分状态保存在本类内。
final class CPUReader {
    private var prev: [(user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)] = []

    func reset() { prev = [] }

    func read() -> CPUSample? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var cur: [(UInt32, UInt32, UInt32, UInt32)] = []
        cur.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            cur.append((UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                        UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                        UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                        UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }

        defer { prev = cur }
        guard prev.count == cur.count, !cur.isEmpty else { return nil }

        var sample = CPUSample()
        var busyAll: UInt64 = 0, totalAll: UInt64 = 0
        var userAll: UInt64 = 0, sysAll: UInt64 = 0
        for i in 0..<cur.count {
            // 32 位计数器回绕：无符号回绕减法
            let du = cur[i].0 &- prev[i].0
            let ds = cur[i].1 &- prev[i].1
            let di = cur[i].2 &- prev[i].2
            let dn = cur[i].3 &- prev[i].3
            let busy = UInt64(du) + UInt64(ds) + UInt64(dn)
            let total = busy + UInt64(di)
            sample.perCore.append(total > 0 ? Double(busy) / Double(total) : 0)
            busyAll += busy; totalAll += total
            userAll += UInt64(du) + UInt64(dn); sysAll += UInt64(ds)
        }
        if totalAll > 0 {
            sample.total = Double(busyAll) / Double(totalAll)
            sample.user = Double(userAll) / Double(totalAll)
            sample.system = Double(sysAll) / Double(totalAll)
        }
        return sample
    }
}

// MARK: - Memory

struct MemorySample {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: Int32 = 1   // 1 normal, 2 warning, 4 critical
}

final class MemoryReader {
    private let pageSize: UInt64
    private let total: UInt64

    init() {
        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)   // Apple Silicon 16KB，运行时获取
        pageSize = UInt64(ps)
        var mem: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &len, nil, 0)
        total = mem
    }

    func read() -> MemorySample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        var s = MemorySample()
        s.total = total
        let purgeable = UInt64(stats.purgeable_count)
        let internalPages = UInt64(stats.internal_page_count)
        s.app = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
        s.wired = UInt64(stats.wire_count) * pageSize
        s.compressed = UInt64(stats.compressor_page_count) * pageSize
        s.cached = (UInt64(stats.external_page_count) + purgeable) * pageSize
        s.free = UInt64(stats.free_count) * pageSize
        s.used = s.app + s.wired + s.compressed

        var swap = xsw_usage()
        var slen = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &slen, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
        }
        var level: Int32 = 1
        var llen = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &llen, nil, 0) == 0 {
            s.pressure = level
        }
        return s
    }
}

// MARK: - Network

struct NetInterfaceSample {
    var name: String
    var rxRate: Double = 0   // bytes/s
    var txRate: Double = 0
}

final class NetworkReader {
    private var prev: [String: (rx: UInt32, tx: UInt32, time: Date)] = [:]

    func reset() { prev = [:] }

    func read() -> [NetInterfaceSample] {
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }

        let now = Date()
        var result: [NetInterfaceSample] = []
        var seen = Set<String>()
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let fa = p.pointee
            ptr = fa.ifa_next
            guard let addr = fa.ifa_addr,
                  Int32(addr.pointee.sa_family) == AF_LINK,
                  let dataPtr = fa.ifa_data else { continue }
            let name = String(cString: fa.ifa_name)
            // 只统计 en* 物理接口，排除回环/VPN/网桥，避免重复计数
            guard name.hasPrefix("en"), !seen.contains(name) else { continue }
            seen.insert(name)
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            let rx = data.ifi_ibytes, tx = data.ifi_obytes

            var sample = NetInterfaceSample(name: name)
            if let last = prev[name] {
                let dt = now.timeIntervalSince(last.time)
                if dt > 0 {
                    sample.rxRate = Double(rx &- last.rx) / dt
                    sample.txRate = Double(tx &- last.tx) / dt
                }
            }
            prev[name] = (rx, tx, now)
            result.append(sample)
        }
        return result.sorted { $0.name < $1.name }
    }
}

// MARK: - Disk

struct DiskSample {
    var used: UInt64 = 0
    var total: UInt64 = 0
    var readRate: Double = 0    // bytes/s
    var writeRate: Double = 0
}

final class DiskReader {
    private var prev: (read: UInt64, write: UInt64, time: Date)? = nil

    func reset() { prev = nil }

    func read() -> DiskSample {
        var s = DiskSample()
        var st = statfs()
        if statfs("/", &st) == 0 {
            let bs = UInt64(st.f_bsize)
            s.total = st.f_blocks * bs
            s.used = (st.f_blocks - st.f_bfree) * bs
        }

        // IOKit 块设备累计读写字节，无子进程
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault,
                                        IOServiceMatching("IOBlockStorageDriver"),
                                        &iter) == KERN_SUCCESS {
            var readSum: UInt64 = 0, writeSum: UInt64 = 0
            var entry = IOIteratorNext(iter)
            while entry != 0 {
                // 只取 Statistics 单个属性，避免全量属性表拷贝（按价值付费）
                if let ref = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString,
                                                             kCFAllocatorDefault, 0),
                   let stats = ref.takeRetainedValue() as? NSDictionary {
                    readSum += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                    writeSum += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)

            let now = Date()
            if let last = prev {
                let dt = now.timeIntervalSince(last.time)
                if dt > 0 {
                    s.readRate = Double(readSum &- last.read) / dt
                    s.writeRate = Double(writeSum &- last.write) / dt
                }
            }
            prev = (readSum, writeSum, now)
        }
        return s
    }
}

// MARK: - Self usage（自举展示：监控者自身占用）

struct SelfUsage {
    var footprint: UInt64 = 0
    var cpuPercent: Double = 0
}

final class SelfUsageReader {
    private var prevCPUTime: Double? = nil
    private var prevTime: Date? = nil

    func read() -> SelfUsage {
        var s = SelfUsage()
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS { s.footprint = info.phys_footprint }

        var ru = rusage()
        if getrusage(RUSAGE_SELF, &ru) == 0 {
            let t = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
                  + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
            let now = Date()
            if let pt = prevCPUTime, let pd = prevTime {
                let dt = now.timeIntervalSince(pd)
                if dt > 0 { s.cpuPercent = (t - pt) / dt * 100 }
            }
            prevCPUTime = t
            prevTime = now
        }
        return s
    }
}