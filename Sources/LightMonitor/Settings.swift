import Foundation
import Combine
import ServiceManagement

final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var showCPU: Bool { didSet { defaults.set(showCPU, forKey: "showCPU") } }
    @Published var showRAM: Bool { didSet { defaults.set(showRAM, forKey: "showRAM") } }
    @Published var showNet: Bool { didSet { defaults.set(showNet, forKey: "showNet") } }
    @Published var showDisk: Bool { didSet { defaults.set(showDisk, forKey: "showDisk") } }
    @Published var showGPU: Bool { didSet { defaults.set(showGPU, forKey: "showGPU") } }
    @Published var showBattery: Bool { didSet { defaults.set(showBattery, forKey: "showBattery") } }
    @Published var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "alertsEnabled") } }
    @Published var cpuThreshold: Double { didSet { defaults.set(cpuThreshold, forKey: "cpuThreshold") } }
    @Published var memThreshold: Double { didSet { defaults.set(memThreshold, forKey: "memThreshold") } }
    @Published var diskThreshold: Double { didSet { defaults.set(diskThreshold, forKey: "diskThreshold") } }
    @Published var processSort: Int { didSet { defaults.set(processSort, forKey: "processSort") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                // 注册失败（如未签名/位置不当）时回退开关状态
                DispatchQueue.main.async { self.launchAtLogin = oldValue }
            }
        }
    }

    init() {
        defaults.register(defaults: [
            "showCPU": true, "showRAM": true, "showNet": true, "showDisk": true,
            "showGPU": false, "showBattery": false,
            "refreshInterval": 1.0,
            "alertsEnabled": false,
            "cpuThreshold": 90.0, "memThreshold": 90.0, "diskThreshold": 90.0,
            "processSort": 0
        ])
        showCPU = defaults.bool(forKey: "showCPU")
        showRAM = defaults.bool(forKey: "showRAM")
        showNet = defaults.bool(forKey: "showNet")
        showDisk = defaults.bool(forKey: "showDisk")
        showGPU = defaults.bool(forKey: "showGPU")
        showBattery = defaults.bool(forKey: "showBattery")
        refreshInterval = defaults.double(forKey: "refreshInterval")
        alertsEnabled = defaults.bool(forKey: "alertsEnabled")
        cpuThreshold = defaults.double(forKey: "cpuThreshold")
        memThreshold = defaults.double(forKey: "memThreshold")
        diskThreshold = defaults.double(forKey: "diskThreshold")
        processSort = defaults.integer(forKey: "processSort")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}