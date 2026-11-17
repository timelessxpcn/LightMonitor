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
    var selfUsage = SelfUsage()
    var timestamp = Date()
}

/// 单心跳采样器：廉价系统采样在后台队列执行，结果回主线程发布。
/// 详情面板关闭时 UI 不订阅（contentViewController 置 nil），无常驻渲染成本。
final class Sampler: ObservableObject {
    @Published private(set) var snapshot = Snapshot()

    var onSnapshot: ((Snapshot) -> Void)?

    private let cpuReader = CPUReader()
    private let memReader = MemoryReader()
    private let netReader = NetworkReader()
    private let diskReader = DiskReader()
    private let selfReader = SelfUsageReader()

    private let queue = DispatchQueue(label: "lightmonitor.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?

    var interval: TimeInterval = 1 {
        didSet { if interval != oldValue { start() } }
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
                }
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        var s = Snapshot()
        s.cpu = cpuReader.read()
        s.memory = memReader.read()
        s.net = netReader.read()
        s.netRx = s.net.reduce(0) { $0 + $1.rxRate }
        s.netTx = s.net.reduce(0) { $0 + $1.txRate }
        s.disk = diskReader.read()
        s.selfUsage = selfReader.read()
        s.timestamp = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = s
            self.onSnapshot?(s)
        }
    }
}