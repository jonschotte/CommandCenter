import Foundation
import Darwin
import IOKit

struct VolumeInfo: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let total: UInt64
    let available: UInt64
    var used: UInt64 { total > available ? total - available : 0 }
    var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct Sample: Identifiable {
    let id: Int
    let value: Double
}

final class SystemMonitor: ObservableObject {
    // CPU
    @Published var cpuTotal: Double = 0            // 0…1
    @Published var cpuCores: [Double] = []
    @Published var loadAverage: (Double, Double, Double) = (0, 0, 0)
    // Memory
    @Published var memTotal: UInt64 = 0
    @Published var memUsed: UInt64 = 0
    @Published var memApp: UInt64 = 0
    @Published var memWired: UInt64 = 0
    @Published var memCompressed: UInt64 = 0
    @Published var memCached: UInt64 = 0
    @Published var swapUsed: UInt64 = 0
    @Published var swapTotal: UInt64 = 0
    // GPU
    @Published var gpuUtil: Double = 0             // 0…1
    @Published var gpuMemInUse: UInt64 = 0
    // Disk / net
    @Published var volumes: [VolumeInfo] = []
    @Published var netIn: Double = 0               // bytes/sec
    @Published var netOut: Double = 0
    @Published var thermal: ProcessInfo.ThermalState = .nominal
    @Published var uptime: TimeInterval = 0
    // History (last 2 minutes)
    @Published var cpuHistory: [Sample] = []
    @Published var memHistory: [Sample] = []
    @Published var gpuHistory: [Sample] = []

    var memFraction: Double { memTotal == 0 ? 0 : Double(memUsed) / Double(memTotal) }

    private var timer: Timer?
    private var prevTicks: [[UInt32]] = []
    private var prevNet: (UInt64, UInt64, Date)?
    private var tick = 0
    private let historyLength = 120

    func start() {
        memTotal = ProcessInfo.processInfo.physicalMemory
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
    }

    private func update() {
        tick += 1
        updateCPU()
        updateMemory()
        updateGPU()
        updateNetwork()
        if tick % 10 == 1 { updateVolumes() }
        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        loadAverage = (la[0], la[1], la[2])
        thermal = ProcessInfo.processInfo.thermalState
        uptime = ProcessInfo.processInfo.systemUptime

        push(&cpuHistory, cpuTotal * 100)
        push(&memHistory, memFraction * 100)
        push(&gpuHistory, gpuUtil * 100)
    }

    private func push(_ arr: inout [Sample], _ v: Double) {
        arr.append(Sample(id: tick, value: v))
        if arr.count > historyLength { arr.removeFirst(arr.count - historyLength) }
    }

    private func updateCPU() {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }

        var ticks: [[UInt32]] = []
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            ticks.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
        }
        if prevTicks.count == ticks.count {
            var cores: [Double] = []
            var busyAll = 0.0, totalAll = 0.0
            for (cur, prev) in zip(ticks, prevTicks) {
                let d = (0..<Int(CPU_STATE_MAX)).map { Double(cur[$0] &- prev[$0]) }
                let idle = d[Int(CPU_STATE_IDLE)]
                let total = d.reduce(0, +)
                let busy = total - idle
                cores.append(total > 0 ? busy / total : 0)
                busyAll += busy; totalAll += total
            }
            cpuCores = cores
            cpuTotal = totalAll > 0 ? busyAll / totalAll : 0
        }
        prevTicks = ticks
    }

    private func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        memApp = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        memWired = UInt64(stats.wire_count) * page
        memCompressed = UInt64(stats.compressor_page_count) * page
        memCached = (UInt64(stats.external_page_count) + purgeable) * page
        memUsed = memApp + memWired + memCompressed

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            swapUsed = swap.xsu_used
            swapTotal = swap.xsu_total
        }
    }

    private func updateGPU() {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any] {
                if let u = perf["Device Utilization %"] as? NSNumber { gpuUtil = u.doubleValue / 100 }
                if let m = perf["In use system memory"] as? NSNumber { gpuMemInUse = m.uint64Value }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }

    private func updateNetwork() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }
        var inB: UInt64 = 0, outB: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let name = String(cString: p.pointee.ifa_name)
            if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               name.hasPrefix("en") {
                if let data = p.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    inB += UInt64(data.pointee.ifi_ibytes)
                    outB += UInt64(data.pointee.ifi_obytes)
                }
            }
            ptr = p.pointee.ifa_next
        }
        let now = Date()
        if let (pi, po, t) = prevNet {
            let dt = now.timeIntervalSince(t)
            if dt > 0 {
                netIn = Double(inB &- pi) / dt
                netOut = Double(outB &- po) / dt
            }
        }
        prevNet = (inB, outB, now)
    }

    private func updateVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [VolumeInfo] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            let avail = UInt64(v.volumeAvailableCapacityForImportantUsage ?? 0)
            out.append(VolumeInfo(name: v.volumeName ?? url.lastPathComponent, path: url.path, total: UInt64(total), available: avail))
        }
        volumes = out
    }
}
