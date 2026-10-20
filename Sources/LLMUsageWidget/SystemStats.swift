import Darwin
import Foundation
import IOKit

enum MemoryPressure {
    case normal, warning, critical, unknown

    init(level: Int32) {
        switch level {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }

    var name: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }
}

final class SystemStats {
    private(set) var cpu: Int?
    private(set) var gpu: Int?
    private(set) var memoryUsed: UInt64?
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    private(set) var pressure = MemoryPressure.unknown
    private(set) var download: Double?
    private(set) var upload: Double?

    private var previousCPUTicks: [UInt32]?
    private var previousNetwork: (rx: UInt64, tx: UInt64, time: TimeInterval)?

    func sample() {
        sampleCPU()
        gpu = readGPUUtilization()
        memoryUsed = readMemoryUsed()
        pressure = readMemoryPressure()
        sampleNetwork()
    }

    // MARK: - CPU

    private func sampleCPU() {
        guard let ticks = readCPUTicks() else { return }
        defer { previousCPUTicks = ticks }

        guard let old = previousCPUTicks else { return }

        let delta = zip(ticks, old).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)

        guard total > 0 else { return }

        let busy = total - delta[Int(CPU_STATE_IDLE)]
        cpu = Int((100.0 * Double(busy) / Double(total)).rounded())
    }

    private func readCPUTicks() -> [UInt32]? {
        var info = host_cpu_load_info_data_t()
        let capacity = MemoryLayout<host_cpu_load_info_data_t>.size
            / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)

        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        let t = info.cpu_ticks
        return [t.0, t.1, t.2, t.3]
    }

    // MARK: - GPU

    private func readGPUUtilization() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var utilization: Int?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any],
               let value = stats["Device Utilization %"] as? Int {
                utilization = max(utilization ?? 0, value)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return utilization
    }

    // MARK: - Memory

    /// The same sum as "Memory Used" in Activity Monitor: app memory + wired + compressed.
    private func readMemoryUsed() -> UInt64? {
        var info = vm_statistics64_data_t()
        let capacity = MemoryLayout<vm_statistics64_data_t>.size
            / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)

        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        let internalPages = UInt64(info.internal_page_count)
        let app = internalPages - min(UInt64(info.purgeable_count), internalPages)
        let pages = app + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    private func readMemoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        else { return .unknown }
        return MemoryPressure(level: level)
    }

    // MARK: - Network

    private func sampleNetwork() {
        guard let bytes = readNetworkBytes() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previousNetwork = (bytes.rx, bytes.tx, now) }

        guard let old = previousNetwork, now > old.time else { return }

        // The counters drop when an interface goes away. Show 0 for that sample.
        let seconds = now - old.time
        download = Double(bytes.rx >= old.rx ? bytes.rx - old.rx : 0) / seconds
        upload = Double(bytes.tx >= old.tx ? bytes.tx - old.tx : 0) / seconds
    }

    /// Total bytes in and out on the physical interfaces (en*). VPN tunnels (utun*)
    /// carry the same traffic again, so counting them would count it twice.
    private func readNetworkBytes() -> (rx: UInt64, tx: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }

                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if interfaceName(index: message.ifm_index).hasPrefix("en") {
                        rx += message.ifm_data.ifi_ibytes
                        tx += message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (rx, tx)
    }

    private func interfaceName(index: UInt16) -> String {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return "" }
        return String(cString: name)
    }
}
