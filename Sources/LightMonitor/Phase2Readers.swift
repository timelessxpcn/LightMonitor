import Foundation
import Darwin
import IOKit
import IOKit.ps

// MARK: - GPU

final class GPUReader {
    /// IOKit IOAccelerator 单属性读取，无子进程；取多加速器最大值
    func read() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double? = nil
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            if let ref = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                         kCFAllocatorDefault, 0),
               let stats = ref.takeRetainedValue() as? NSDictionary,
               let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, util / 100)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return best
    }
}

// MARK: - Battery

struct BatterySample {
    var percent: Int = 0
    var isCharging = false
    var onAC = false
    var minutesToEmpty: Int? = nil
    var cycleCount: Int? = nil
}

final class BatteryReader {
    func read() -> BatterySample? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any]
        else { return nil }

        var s = BatterySample()
        let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCap = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        s.percent = maxCap > 0 ? cur * 100 / maxCap : 0
        s.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
        s.onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        if let t = desc[kIOPSTimeToEmptyKey] as? Int, t >= 0 { s.minutesToEmpty = t }
        s.cycleCount = desc["Cycle Count"] as? Int
        return s
    }
}

// MARK: - Top processes

struct ProcSample: Identifiable {
    let pid: Int32
    let name: String
    var cpu: Double = 0          // percent, 可 >100（多核）
    var footprint: UInt64 = 0    // 0 表示无权限读取
    var id: Int32 { pid }
}

/// 进程扫描是重活：独立 5s 心跳，且仅在面板打开时运行（可见性门控）。
/// 普通用户权限：他人/系统进程 footprint 读不到时如实记 0，UI 显示"—"。
final class ProcessReader {
    private var prev: [Int32: (cpuNs: UInt64, time: Date)] = [:]

    func reset() { prev = [:] }

    func scan() -> (topCPU: [ProcSample], topMem: [ProcSample]) {
        var pids = [pid_t](repeating: 0, count: 8192)
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.size)
        let n = proc_listallpids(&pids, byteCount)
        guard n > 0 else { return ([], []) }

        let now = Date()
        var samples: [ProcSample] = []
        var cur: [Int32: (UInt64, Date)] = [:]
        samples.reserveCapacity(Int(n))

        for pid in pids.prefix(Int(n)) where pid > 0 {
            var ri = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            } == 0
            guard ok else { continue }

            let cpuNs = ri.ri_user_time + ri.ri_system_time
            var s = ProcSample(pid: pid, name: processName(pid))
            s.footprint = ri.ri_phys_footprint
            if let last = prev[pid] {
                let dt = now.timeIntervalSince(last.time)
                if dt > 0 {
                    s.cpu = Double(cpuNs &- last.cpuNs) / dt / 1e9 * 100
                }
            }
            cur[pid] = (cpuNs, now)
            samples.append(s)
        }
        prev = cur

        let topCPU = samples.sorted { $0.cpu > $1.cpu }.prefix(5).map { $0 }
        let topMem = samples.sorted { $0.footprint > $1.footprint }.prefix(5).map { $0 }
        return (topCPU, topMem)
    }

    private func processName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let len = proc_name(pid, &buf, UInt32(buf.count))
        if len > 0 { return String(cString: buf) }
        return "pid \(pid)"
    }
}