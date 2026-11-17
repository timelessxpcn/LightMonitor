import Foundation
import AppKit
import Combine

struct Snapshot {
    var cpu: CPUSample? = nil
    var memory: MemorySample? = nil
    var net: [NetInterfaceSample] = []
    var netRx: Double = 0
    var netTx: Double = 0
    var disk = DiskSample()
    var gpu: Double? = nil
    var battery: BatterySample? = nil
    var topCPU: [ProcSample] = []
    var topMem: [ProcSample] = []
    var selfUsage = SelfUsage()
    var timestamp = Date()
}

/// 双频心跳：
/// - tickSystem（1s，廉价）：CPU/内存/网络/磁盘；GPU/电池按模块开关与面板可见性门控，电池 5s 降采样。
/// - tickProcess（5s，重活）：仅在面板打开时运行。
/// 详情面板关闭时 UI 不订阅（contentViewController 置 nil），无常驻渲染成本。
final class Sampler: ObservableObject {
    @Published private(set) var snapshot = Snapshot()

    var onSnapshot: ((Snapshot) -> Void)?

    private let settings: SettingsStore
    private let history: HistoryStore
    private let cpuReader = CPUReader()
    private let memReader = MemoryReader()
    private let netReader = NetworkReader()
    private let diskReader = DiskReader()
    private let gpuReader = GPUReader()
    private let batteryReader = BatteryReader()
    private let processReader = ProcessReader()
    private let selfReader = SelfUsageReader()

    private let queue = DispatchQueue(label: "lightmonitor.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var processTimer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?

    private var lastBattery: BatterySample? = nil
    private var lastBatteryRead: Date = .distantPast

    /// 面板可见性（主线程读写），用于门控 GPU/电池/进程扫描
    var panelOpen = false {
        didSet {
            guard panelOpen != oldValue else { return }
            if panelOpen { startProcessTimer() } else { stopProcessTimer() }
        }
    }

    var interval: TimeInterval = 1 {
        didSet { if interval != oldValue { start() } }
    }

    init(settings: SettingsStore, history: HistoryStore) {
        self.settings = settings
        self.history = history
    }

    func start() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.queue.async {
                    // 休眠唤醒后重置差分基线，避免假尖峰
                    self?.cpuReader.reset()
                    self?.netReader.reset()
                    self?.diskReader.reset()
                    self?.processReader.reset()
                    self?.lastBatteryRead = .distantPast
                }
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        stopProcessTimer()
    }

    private func startProcessTimer() {
        guard processTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 5, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tickProcess() }
        t.resume()
        processTimer = t
    }

    private func stopProcessTimer() {
        processTimer?.cancel()
        processTimer = nil
        queue.async { [weak self] in self?.processReader.reset() }
    }

    private func tick() {
        var s = Snapshot()
        s.cpu = cpuReader.read()
        s.memory = memReader.read()
        s.net = netReader.read()
        s.netRx = s.net.reduce(0) { $0 + $1.rxRate }
        s.netTx = s.net.reduce(0) { $0 + $1.txRate }
        s.disk = diskReader.read()

        // GPU：模块开启或面板打开才读（按价值付费）
        if settings.showGPU || panelOpen {
            s.gpu = gpuReader.read()
        }
        // 电池：电量以分钟计变化，5s 降采样，中间沿用缓存
        if settings.showBattery || panelOpen {
            let now = Date()
            if now.timeIntervalSince(lastBatteryRead) >= 5 {
                lastBattery = batteryReader.read()
                lastBatteryRead = now
            }
            s.battery = lastBattery
        }

        s.selfUsage = selfReader.read()
        s.timestamp = Date()

        // 历史落盘（内部 30s 节流 + 开关门控）
        var values: [String: Double] = [:]
        if let cpu = s.cpu { values["cpu"] = cpu.total }
        if let m = s.memory, m.total > 0 { values["mem"] = Double(m.used) / Double(m.total) }
        values["net_rx"] = s.netRx
        values["net_tx"] = s.netTx
        if s.disk.total > 0 { values["disk"] = Double(s.disk.used) / Double(s.disk.total) }
        if let gpu = s.gpu { values["gpu"] = gpu }
        history.record(ts: s.timestamp.timeIntervalSince1970, values: values)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            s.topCPU = self.snapshot.topCPU
            s.topMem = self.snapshot.topMem
            self.snapshot = s
            self.onSnapshot?(s)
        }
    }

    private func tickProcess() {
        let result = processReader.scan()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot.topCPU = result.topCPU
            self.snapshot.topMem = result.topMem
        }
    }
}