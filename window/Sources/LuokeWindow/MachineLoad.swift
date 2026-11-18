import Darwin
import Foundation
import IOKit
import SwiftUI

/// 这台 Mac 现在多忙：内存用了几成、GPU 忙几成（0…1，读不到是 nil）。窗口右上角的圆环、右边栏顶上用。
/// 窗口自己读（负责人 11-13：不用问主控），看得见的时候每 2 秒一次；以后有了 CPU、神经网络引擎就再加两样
public struct MachineLoad: Equatable, Sendable {
    public var ram: Double?
    public var gpu: Double?

    public init(ram: Double? = nil, gpu: Double? = nil) {
        self.ram = ram
        self.gpu = gpu
    }

    /// 读一次。内存照「活动监视器」的「已使用内存」：App 内存 + 联动 + 被压缩，除以物理内存
    public static func sample() -> MachineLoad {
        MachineLoad(ram: ramUsed(), gpu: gpuBusy())
    }

    static func ramUsed() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        return min(max(used / total, 0), 1)
    }

    /// GPU 忙几成：IOAccelerator 的 PerformanceStatistics 里的「Device Utilization %」（不要权限），几块取最大的
    static func gpuBusy() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double?
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let d = props?.takeRetainedValue() as? [String: Any],
                  let perf = d["PerformanceStatistics"] as? [String: Any],
                  let u = perf["Device Utilization %"] as? NSNumber else { continue }
            best = max(best ?? 0, min(max(u.doubleValue / 100, 0), 1))
        }
        return best
    }

    /// 「62%」；读不到写「—」
    static func percent(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

    /// 内存蓝、GPU 红（右上角圆环和右边栏顶上同一套）
    static func ramColor(_ dark: Bool) -> Color { dark ? .hex(0x7AA5FF) : .hex(0x5B8DEF) }
    static func gpuColor(_ dark: Bool) -> Color { dark ? .hex(0xF0646C) : .hex(0xD0464F) }
}
