import SwiftUI
import AppKit
import IOKit
import Darwin

// MARK: - Configuration

struct StatBarConfig: Codable {
    var window: WindowConfig = .init()
    var refresh_interval_secs: Double = 2.0
    var appearance: AppearanceConfig = .init()
    var stats: StatsConfig = .init()
    var ollama: OllamaConfig = .init()

    struct WindowConfig: Codable {
        var x: Double = 0
        var y: Double = 30
        var width: CGFloat = 250
        var max_height: CGFloat = 250
        var min_height: CGFloat = 80
    }

    struct AppearanceConfig: Codable {
        var background_color: String = "#141414"
        var background_opacity: Double = 0.92
        var show_shadow: Bool = true
        var floating_level: Bool = true
        var movable_by_background: Bool = true
        var hide_titlebar_buttons: Bool = true
    }

    struct StatsConfig: Codable {
        var section_order: [String] = ["ollama", "cpu", "gpu", "memory", "network", "disk"]
        var show_cpu: Bool = true
        var cpu_color: String = "#007AFF"
        var show_gpu: Bool = true
        var gpu_color: String = "#AF52DE"
        var show_memory: Bool = true
        var memory_color: String = "#30D158"
        var show_network: Bool = true
        var network_down_color: String = "#32ADE6"
        var network_up_color: String = "#FF9F0A"
        var show_disk: Bool = true
        var disk_color: String = "#FFD60A"
        var network_interface_prefixes: [String] = ["en", "awdl"]
        var show_ollama: Bool = true
    }

    struct OllamaConfig: Codable {
        var enabled: Bool = true
        var endpoint: String = "http://localhost:11434/api/ps"
        var timeout_secs: Double = 2.0
    }
}

let defaultConfig = StatBarConfig()
let configPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/statbar/config.json")

func loadConfig() -> StatBarConfig {
    let fm = FileManager.default
    guard fm.fileExists(atPath: configPath.path) else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(defaultConfig) {
            try? fm.createDirectory(at: configPath.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? data.write(to: configPath, options: .atomic)
        }
        return defaultConfig
    }
    guard let data = try? Data(contentsOf: configPath),
          let cfg = try? JSONDecoder().decode(StatBarConfig.self, from: data) else {
        return defaultConfig
    }
    return cfg
}

func hexToColor(_ hex: String) -> NSColor {
    var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if str.hasPrefix("#") { str.removeFirst() }
    guard str.count == 6,
          let val = UInt64(str, radix: 16) else {
        return .white
    }
    return NSColor(
        red: CGFloat((val >> 16) & 0xFF) / 255,
        green: CGFloat((val >> 8) & 0xFF) / 255,
        blue: CGFloat(val & 0xFF) / 255,
        alpha: 1.0
    )
}

// MARK: - System Stats Collector

class StatsCollector {
    private var prevRx: UInt64 = 0
    private var prevTx: UInt64 = 0
    private var prevSample: TimeInterval = 0
    private var config: StatBarConfig

    init(config: StatBarConfig) {
        self.config = config
    }

    func updateConfig(_ newConfig: StatBarConfig) {
        config = newConfig
    }

    struct SystemStats {
        var cpu: Double = 0
        var gpu: Double = 0
        var memUsed: UInt64 = 0
        var memTotal: UInt64 = 0
        var netDown: Double = 0
        var netUp: Double = 0
        var diskUsed: UInt64 = 0
        var diskTotal: UInt64 = 0
    }

    struct OllamaModel {
        var name: String = ""
        var size: String = ""
        var gpuPct: String = ""
        var contextLen: Int = 0
        var paramSize: String = ""
        var quantization: String = ""
    }

    func collectStats() -> SystemStats {
        var s = SystemStats()
        s.cpu = readCPU()
        s.gpu = readGPU()
        (s.memUsed, s.memTotal) = readMemory()
        let (rx, tx) = readNetworkRaw()
        let now = ProcessInfo.processInfo.systemUptime
        if prevSample > 0 {
            let elapsed = now - prevSample
            if elapsed > 0 {
                s.netDown = Double(rx - prevRx) / elapsed
                s.netUp = Double(tx - prevTx) / elapsed
            }
        }
        prevRx = rx
        prevTx = tx
        prevSample = now
        (s.diskUsed, s.diskTotal) = readDisk()
        return s
    }

    func collectOllama() -> [OllamaModel] {
        guard config.ollama.enabled else { return [] }
        guard let url = URL(string: config.ollama.endpoint) else { return [] }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [OllamaModel] = []

        let task = URLSession.shared.dataTask(with: url) { data, _, error in
            defer { semaphore.signal() }
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return }
            for m in models {
                var model = OllamaModel()
                model.name = (m["name"] as? String) ?? ""
                if let size = m["size_vram"] as? Int64 {
                    model.size = formatBytes(UInt64(size))
                }
                if let details = m["details"] as? [String: Any] {
                    model.paramSize = (details["parameter_size"] as? String) ?? ""
                    model.quantization = (details["quantization_level"] as? String) ?? ""
                }
                if let ctx = m["context_length"] as? Int {
                    model.contextLen = ctx
                }
                if let proc = m["processor"] as? String {
                    model.gpuPct = proc
                }
                result.append(model)
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + config.ollama.timeout_secs)
        return result
    }

    // MARK: - CPU (Mach)

    private func readCPU() -> Double {
        let cpuLoad = host_cpu_load_info_t.allocate(capacity: 1)
        defer { cpuLoad.deallocate() }
        let count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var prevTicks: [UInt64] = [0, 0, 0, 0]

        // First sample
        var size1 = count
        guard host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                              cpuLoad.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { $0 },
                              &size1) == KERN_SUCCESS else { return 0 }

        prevTicks[0] = UInt64(cpuLoad.pointee.cpu_ticks.0)
        prevTicks[1] = UInt64(cpuLoad.pointee.cpu_ticks.1)
        prevTicks[2] = UInt64(cpuLoad.pointee.cpu_ticks.2)
        prevTicks[3] = UInt64(cpuLoad.pointee.cpu_ticks.3)

        usleep(200_000)

        var size2 = count
        guard host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                              cpuLoad.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { $0 },
                              &size2) == KERN_SUCCESS else { return 0 }

        let curTicks: [UInt64] = [
            UInt64(cpuLoad.pointee.cpu_ticks.0),
            UInt64(cpuLoad.pointee.cpu_ticks.1),
            UInt64(cpuLoad.pointee.cpu_ticks.2),
            UInt64(cpuLoad.pointee.cpu_ticks.3),
        ]

        let totalDelta = (curTicks[0] - prevTicks[0]) +
                         (curTicks[1] - prevTicks[1]) +
                         (curTicks[2] - prevTicks[2]) +
                         (curTicks[3] - prevTicks[3])

        let idleDelta = curTicks[2] - prevTicks[2]
        guard totalDelta > 0 else { return 0 }
        return Double(totalDelta - idleDelta) / Double(totalDelta) * 100.0
    }

    // MARK: - GPU (IOKit AGXAccelerator)

    private func readGPU() -> Double {
        let matching = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return 0
        }
        var utilization: Double = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString,
                kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] {
                if let val = props["GPU Core Utilization"] as? Double {
                    utilization = max(utilization, val)
                } else if let val = props["GPU Core Utilization"] as? Int {
                    utilization = max(utilization, Double(val))
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)
        return utilization
    }

    // MARK: - Memory (Mach)

    private func readMemory() -> (UInt64, UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        let vmStats = vm_statistics64_t.allocate(capacity: 1)
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()

        let kr = host_statistics64(host, HOST_VM_INFO64,
                                    vmStats.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { $0 },
                                    &count)
        guard kr == KERN_SUCCESS else {
            vmStats.deallocate()
            return (0, total)
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(vmStats.pointee.active_count) * pageSize
        let wired = UInt64(vmStats.pointee.wire_count) * pageSize
        let compressed = UInt64(vmStats.pointee.compressor_page_count) * pageSize
        vmStats.deallocate()
        let used = active + wired + compressed
        return (used, total)
    }

    // MARK: - Network (getifaddrs)

    private func readNetworkRaw() -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (0, 0) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        let prefixes = config.stats.network_interface_prefixes

        var ptr = firstAddr
        while true {
            let addr = ptr.pointee
            let name = String(cString: addr.ifa_name)
            for prefix in prefixes where name.hasPrefix(prefix) {
                if let data = addr.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    rx += UInt64(data.ifi_ibytes)
                    tx += UInt64(data.ifi_obytes)
                }
                break
            }
            guard let next = addr.ifa_next else { break }
            ptr = next
        }
        freeifaddrs(ifaddr)
        return (rx, tx)
    }

    // MARK: - Disk

    private func readDisk() -> (UInt64, UInt64) {
        let keys: [URLResourceKey] = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let url = URL(string: "file:///"),
              let values = try? url.resourceValues(forKeys: Set(keys)),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacity
        else { return (0, 0) }
        // Clamp to zero — APFS can report available > total (snapshots, purgable space)
        let used = UInt64(max(0, total - free))
        return (used, UInt64(total))
    }
}

// MARK: - Formatting Helpers

func formatBytes(_ bytes: UInt64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .binary
    return f.string(fromByteCount: Int64(bytes))
}

func formatBW(_ bps: Double) -> String {
    if bps < 1024 { return String(format: "%.0fB", bps) }
    if bps < 1024*1024 { return String(format: "%.0fK", bps / 1024) }
    if bps < 1024*1024*1024 { return String(format: "%.1fM", bps / (1024*1024)) }
    return String(format: "%.1fG", bps / (1024*1024*1024))
}

func formatMemory(_ bytes: UInt64) -> String {
    return String(format: "%.1f", Double(bytes) / 1_073_741_824)
}

// MARK: - Progress Bar Component

struct StatBarView: View {
    let pct: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(0, geo.size.width * CGFloat(min(pct, 100) / 100)), height: 6)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Stat Row

struct StatRow: View {
    let label: String
    let pct: Double
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 30, alignment: .leading)
            StatBarView(pct: pct, color: color)
            Text(String(format: "%.1f%%", pct))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @State private var stats = StatsCollector.SystemStats()
    @State private var models: [StatsCollector.OllamaModel] = []
    @State private var config: StatBarConfig
    @State private var lastRefresh: Date = .distantPast
    @State private var generation: Int = 0

    let collector: StatsCollector
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(config: StatBarConfig) {
        self._config = State(initialValue: config)
        self.collector = StatsCollector(config: config)
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(config.stats.section_order.enumerated()), id: \.element) { i, section in
                sectionView(for: section)
                // Separator after Ollama only when more sections follow
                if section == "ollama" && i < config.stats.section_order.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 1)
                }
            }
        }
        .padding(12)
        .onReceive(timer) { _ in tick() }
        .onAppear { tick() }
    }

    @ViewBuilder
    private func sectionView(for section: String) -> some View {
        switch section {
        case "ollama":  ollamaSection
        case "cpu":     cpuSection
        case "gpu":     gpuSection
        case "memory":  memorySection
        case "network": networkSection
        case "disk":    diskSection
        default:        EmptyView()
        }
    }

    // MARK: - Section Views (ordered by config.stats.section_order)

    @ViewBuilder
    private var ollamaSection: some View {
        if config.stats.show_ollama {
            if models.isEmpty {
                HStack {
                    Text("🧠").font(.system(size: 10))
                    Text("Ollama: idle")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                }
            } else {
                ForEach(models.indices, id: \.self) { i in
                    let m = models[i]
                    HStack(spacing: 4) {
                        Text("🧠").font(.system(size: 10))
                        Text(m.name)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white).lineLimit(1).truncationMode(.tail)
                        Spacer()
                    }
                    HStack(spacing: 4) {
                        Text("\(m.paramSize) \(m.quantization)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.55))
                        if !m.size.isEmpty {
                            Text("·").font(.system(size: 9)).foregroundColor(.white.opacity(0.3))
                            Text(m.size)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.55))
                        }
                        if !m.gpuPct.isEmpty {
                            Text("·").font(.system(size: 9)).foregroundColor(.white.opacity(0.3))
                            Text(m.gpuPct)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.55))
                        }
                        if m.contextLen > 0 {
                            Text("·").font(.system(size: 9)).foregroundColor(.white.opacity(0.3))
                            Text("ctx:\(m.contextLen)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.55))
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cpuSection: some View {
        if config.stats.show_cpu {
            StatRow(label: "CPU", pct: stats.cpu,
                    color: Color(nsColor: hexToColor(config.stats.cpu_color)))
        }
    }

    @ViewBuilder
    private var gpuSection: some View {
        if config.stats.show_gpu {
            StatRow(label: "GPU", pct: stats.gpu,
                    color: Color(nsColor: hexToColor(config.stats.gpu_color)))
        }
    }

    @ViewBuilder
    private var memorySection: some View {
        if config.stats.show_memory {
            let memPct = stats.memTotal > 0
                ? Double(stats.memUsed) / Double(stats.memTotal) * 100 : 0
            VStack(spacing: 2) {
                HStack {
                    Text("MEM")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 30, alignment: .leading)
                    StatBarView(pct: memPct,
                                color: Color(nsColor: hexToColor(config.stats.memory_color)))
                    Text("\(formatMemory(stats.memUsed))/\(formatMemory(stats.memTotal))GB")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 96, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        if config.stats.show_network {
            HStack {
                Text("NET")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 30, alignment: .leading)
                Image(systemName: "arrow.down")
                    .font(.system(size: 8))
                    .foregroundColor(Color(nsColor: hexToColor(config.stats.network_down_color)))
                Text(formatBW(stats.netDown))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 48, alignment: .leading)
                Image(systemName: "arrow.up")
                    .font(.system(size: 8))
                    .foregroundColor(Color(nsColor: hexToColor(config.stats.network_up_color)))
                Text(formatBW(stats.netUp))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 48, alignment: .leading)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var diskSection: some View {
        if config.stats.show_disk {
            let diskPct = stats.diskTotal > 0
                ? Double(stats.diskUsed) / Double(stats.diskTotal) * 100 : 0
            VStack(spacing: 2) {
                HStack {
                    Text("DSK")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 30, alignment: .leading)
                    StatBarView(pct: diskPct,
                                color: Color(nsColor: hexToColor(config.stats.disk_color)))
                    Text("\(formatMemory(stats.diskUsed))/\(formatMemory(stats.diskTotal))GB")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 96, alignment: .trailing)
                }
            }
        }
    }

    private func tick() {
        let interval = config.refresh_interval_secs
        // Re-read config file on each tick (file watcher covers appearance/window,
        // tick() picks up stat visibility, colors, and layout changes)
        if let data = try? Data(contentsOf: configPath),
           let newConfig = try? JSONDecoder().decode(StatBarConfig.self, from: data) {
            let intervalChanged = abs(newConfig.refresh_interval_secs - config.refresh_interval_secs) > 0.01
            config = newConfig
            collector.updateConfig(newConfig)
            if intervalChanged {
                lastRefresh = .distantPast
            }
        }

        let now = Date()
        guard now.timeIntervalSince(lastRefresh) >= interval else { return }
        lastRefresh = now

        // Dispatch heavy stat collection off the main thread (usleep + Ollama)
        generation += 1
        let currentGen = generation
        let fetchOllama = config.ollama.enabled
        DispatchQueue.global(qos: .utility).async { [collector] in
            let newStats = collector.collectStats()
            let newModels = fetchOllama ? collector.collectOllama() : []
            DispatchQueue.main.async {
                // Only apply if no newer generation has been dispatched
                guard currentGen == self.generation else { return }
                self.stats = newStats
                self.models = newModels
            }
        }
    }
}

// MARK: - App Entry

@main
struct StatBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let cfg = loadConfig()
        let contentView = ContentView(config: cfg)

        // Check for config change within the app lifecycle
        startWatching()

        let hosting = NSHostingView(rootView: contentView)
        hosting.layoutSubtreeIfNeeded()
        let naturalHeight = min(max(hosting.fittingSize.height, cfg.window.min_height), cfg.window.max_height)
        hosting.setFrameSize(NSSize(width: cfg.window.width, height: naturalHeight))

        let win = NSWindow(
            contentRect: NSRect(x: cfg.window.x, y: cfg.window.y,
                                width: cfg.window.width, height: naturalHeight),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.contentView = hosting
        win.contentMinSize = NSSize(width: cfg.window.width, height: cfg.window.min_height)
        win.contentMaxSize = NSSize(width: cfg.window.width, height: cfg.window.max_height)
        win.makeKeyAndOrderFront(nil)

        applyAppearance(cfg, to: win)
        self.window = win
    }

    private func applyAppearance(_ cfg: StatBarConfig, to win: NSWindow) {
        win.level = cfg.appearance.floating_level ? .floating : .normal
        win.isOpaque = true
        let bg = hexToColor(cfg.appearance.background_color)
        win.backgroundColor = bg.withAlphaComponent(CGFloat(cfg.appearance.background_opacity))
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = cfg.appearance.movable_by_background
        win.hasShadow = cfg.appearance.show_shadow
        if cfg.appearance.hide_titlebar_buttons {
            win.standardWindowButton(.closeButton)?.isHidden = true
            win.standardWindowButton(.miniaturizeButton)?.isHidden = true
            win.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }

    private var configFileSource: DispatchSourceFileSystemObject?

    private func startWatching() {
        // Close previous source if any
        configFileSource?.cancel()
        configFileSource = nil

        let fd = open(configPath.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            guard let self = self, let win = self.window else { return }
            let cfg = loadConfig()
            self.applyAppearance(cfg, to: win)
            // Reposition and resize the window from config
            let oldFrame = win.frame
            let newFrame = NSRect(
                x: cfg.window.x,
                y: cfg.window.y,
                width: cfg.window.width,
                height: oldFrame.height
            )
            if newFrame.origin != oldFrame.origin || newFrame.size.width != oldFrame.size.width {
                win.setFrame(newFrame, display: true, animate: false)
                win.contentMinSize = NSSize(width: cfg.window.width, height: cfg.window.min_height)
                win.contentMaxSize = NSSize(width: cfg.window.width, height: cfg.window.max_height)
            }
            // Re-attach fd in case inode changed (atomic rename, editor swap, etc.)
            self.startWatching()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configFileSource = source
    }
}
