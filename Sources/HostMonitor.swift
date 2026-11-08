import AppKit
import SwiftUI
import Darwin

struct HostSample {
    var at: Date = Date()
    var cpu: Double?
    var load: [Double] = []
    var physical = ProcessInfo.processInfo.physicalMemory
    var resident: UInt64?
    var compressed: UInt64?
    var cached: UInt64?
    var swap: UInt64?
    var pressure: String = "Unavailable"
}

/// One sampler shared by visible host-monitor cards. No network, subprocess or
/// model calls. Sampling is serialized off the main thread and stops with demand.
@MainActor final class HostMonitor: ObservableObject {
    static let shared = HostMonitor()
    @Published private(set) var sample = HostSample()
    private var tokens: Set<UUID> = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "Converse.host-monitor", qos: .utility)
    private var generation = UUID()
    private var refreshPending = false
    var isSampling: Bool { timer != nil }
    func subscribe(_ token: UUID) {
        let first = tokens.isEmpty
        tokens.insert(token)
        guard first else { return }
        generation = UUID()
        let epoch = generation
        let reader = HostMetricReader()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            let value = reader.read()
            Task { @MainActor in
                guard let self, self.generation == epoch, !self.tokens.isEmpty else { return }
                self.sample = value
            }
        }
        self.timer = timer; timer.resume()
    }
    func unsubscribe(_ token: UUID) {
        tokens.remove(token)
        guard tokens.isEmpty else { return }
        generation = UUID(); timer?.cancel(); timer = nil
    }
    func refresh() {
        guard !tokens.isEmpty, !refreshPending else { return }
        refreshPending = true
        let epoch = generation
        // Keep the previous CPU interval value until the next scheduled delta.
        queue.async { [weak self] in
            let value = HostMetricReader().read()
            Task { @MainActor in
                guard let self else { return }
                self.refreshPending = false
                guard self.generation == epoch, !self.tokens.isEmpty else { return }
                var updated = value; updated.cpu = self.sample.cpu; self.sample = updated
            }
        }
    }
}

private final class HostMetricReader {
    private var previous: [UInt32]?
    func read() -> HostSample {
        var result = HostSample()
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        if cpuResult == KERN_SUCCESS {
            let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
            if let previous {
                let delta = zip(ticks, previous).map { UInt64($0 &- $1) }
                let total = delta.reduce(0, +)
                if total > 0 { result.cpu = 100 * Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total) }
            }
            previous = ticks
        }
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { result.load = load }
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        if vmResult == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS {
            let page = UInt64(pageSize)
            result.resident = (UInt64(vm.internal_page_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
            result.compressed = UInt64(vm.compressor_page_count) * page
            result.cached = UInt64(vm.external_page_count) * page
        }
        var swap = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { result.swap = swap.xsu_used }
        // Kernel pressure state; never infer it from a percentage of used RAM.
        // Some systems do not expose this key; show Unavailable in that case.
        var pressure: Int32 = 0; size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0 {
            result.pressure = pressure == 1 ? "Normal" : pressure == 2 ? "Warning" : pressure == 4 ? "Critical" : "Unavailable"
        }
        return result
    }
}

struct HostMonitorCard: View {
    @ObservedObject private var monitor = HostMonitor.shared
    private func bytes(_ value: UInt64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) } ?? "Unavailable"
    }
    var body: some View {
        let sample = monitor.sample
        VStack(alignment: .leading, spacing: 14) {
            Label("System Monitor", systemImage: "gauge.with.dots.needle.33percent").font(.headline)
            Text("This Mac").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                row("CPU utilization", sample.cpu.map { String(format: "%.1f%%", $0) } ?? "Measuring…")
                row("Load · 1 / 5 / 15m", sample.load.isEmpty ? "Unavailable" : sample.load.map { String(format: "%.2f", $0) }.joined(separator: " / "))
                row("Memory pressure", sample.pressure)
                row("Resident + compressed", bytes(sample.resident))
                row("Physical memory", bytes(sample.physical))
                row("Compressed storage", bytes(sample.compressed))
                row("File-backed pages", bytes(sample.cached))
                row("Swap used", bytes(sample.swap))
            }.font(.callout).textSelection(.enabled)
            Text("This host only · sampled every 5s. CPU is the busy fraction across all cores over the interval. Memory counts overlap: compressed storage is included above; file-backed pages are not classified as free.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Sampled " + sample.at.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func row(_ name: String, _ value: String) -> some View {
        GridRow { Text(name).foregroundStyle(.secondary); Text(value).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
    }
}
