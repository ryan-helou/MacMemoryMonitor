import Foundation
import Darwin

/// One reading of system-wide memory + CPU, computed the same way Activity Monitor does.
struct MemorySnapshot {
    var total: UInt64 = 0
    var app: UInt64 = 0            // anonymous memory owned by apps
    var wired: UInt64 = 0          // kernel / can't be paged out
    var compressed: UInt64 = 0     // physical RAM the compressor occupies
    var compressedOriginal: UInt64 = 0 // how much data is squeezed into it
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressureLevel: Int = 1     // 1 normal, 2 warning, 4 critical (kernel's own verdict)
    var freePercent: Int = 100     // kernel's "memory free percentage"
    var swapInRate: Double = 0     // bytes/sec read back from swap  → this is what you feel as lag
    var swapOutRate: Double = 0    // bytes/sec written to swap
    var cpuUsage: Double = 0       // 0...100, whole machine
    var diskFree: UInt64 = 0

    var used: UInt64 { app + wired + compressed }
    var pressurePercent: Int { max(0, min(100, 100 - freePercent)) }

    /// Reading pages back from swap is the moment the Mac stalls.
    var isThrashing: Bool { swapInRate > 20 * 1_048_576 }

    enum Health { case healthy, strained, critical }
    var health: Health {
        if pressureLevel >= 4 || (pressureLevel >= 2 && isThrashing) { return .critical }
        if pressureLevel >= 2 || isThrashing || swapInRate > 5 * 1_048_576 { return .strained }
        return .healthy
    }
}

final class SystemSampler {
    private let host = mach_host_self()
    private let pageSize: UInt64
    private var lastSwapIns: UInt64 = 0
    private var lastSwapOuts: UInt64 = 0
    private var lastTime: TimeInterval = 0
    private var lastTicks: [UInt64] = []
    private var lastDiskCheck: TimeInterval = 0
    private var cachedDiskFree: UInt64 = 0

    init() {
        var ps: vm_size_t = 0
        host_page_size(host, &ps)
        pageSize = UInt64(ps)
    }

    func sample() -> MemorySnapshot {
        var s = MemorySnapshot()
        s.total = ProcessInfo.processInfo.physicalMemory

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let now = Date().timeIntervalSince1970
        if kr == KERN_SUCCESS {
            let p = pageSize
            let anon = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            s.app = (anon > purgeable ? anon - purgeable : 0) * p
            s.wired = UInt64(vm.wire_count) * p
            s.compressed = UInt64(vm.compressor_page_count) * p
            s.compressedOriginal = UInt64(vm.total_uncompressed_pages_in_compressor) * p
            s.cached = (UInt64(vm.external_page_count) + purgeable) * p
            s.free = UInt64(vm.free_count) * p

            let ins = UInt64(vm.swapins), outs = UInt64(vm.swapouts)
            if lastTime > 0, now > lastTime {
                let dt = now - lastTime
                s.swapInRate = Double(ins >= lastSwapIns ? ins - lastSwapIns : 0) * Double(p) / dt
                s.swapOutRate = Double(outs >= lastSwapOuts ? outs - lastSwapOuts : 0) * Double(p) / dt
            }
            lastSwapIns = ins; lastSwapOuts = outs
        }
        lastTime = now

        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 {
            s.swapUsed = xsw.xsu_used
            s.swapTotal = xsw.xsu_total
        }
        s.pressureLevel = Int(sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1)
        s.freePercent = Int(sysctlInt("kern.memorystatus_level") ?? 100)
        s.cpuUsage = cpuUsage()

        if now - lastDiskCheck > 60 {
            lastDiskCheck = now
            if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let cap = v.volumeAvailableCapacityForImportantUsage {
                cachedDiskFree = UInt64(max(0, cap))
            }
        }
        s.diskFree = cachedDiskFree
        return s
    }

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        let ticks = [UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3)] // user, system, idle, nice
        defer { lastTicks = ticks }
        guard lastTicks.count == 4 else { return 0 }
        let d = zip(ticks, lastTicks).map { $0 >= $1 ? Double($0 - $1) : 0 }
        let total = d.reduce(0, +)
        guard total > 0 else { return 0 }
        return (total - d[2]) / total * 100
    }
}

func sysctlInt(_ name: String) -> Int32? {
    var v: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
}

func fmtBytes(_ b: UInt64) -> String {
    let gb = Double(b) / 1_073_741_824
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(b) / 1_048_576)
}

func fmtRate(_ bytesPerSec: Double) -> String {
    let mb = bytesPerSec / 1_048_576
    return mb >= 10 ? String(format: "%.0f MB/s", mb) : String(format: "%.1f MB/s", mb)
}

func fmtDuration(_ t: TimeInterval) -> String {
    let m = Int(t / 60)
    if m < 1 { return "<1m" }
    if m < 60 { return "\(m)m" }
    let h = m / 60
    if h < 24 { return "\(h)h \(m % 60)m" }
    return "\(h / 24)d \(h % 24)h"
}
