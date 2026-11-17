import Foundation
import Combine
import ServiceManagement

final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var showCPU: Bool { didSet { defaults.set(showCPU, forKey: "showCPU") } }
    @Published var showRAM: Bool { didSet { defaults.set(showRAM, forKey: "showRAM") } }
    @Published var showNet: Bool { didSet { defaults.set(showNet, forKey: "showNet") } }
    @Published var showDisk: Bool { didSet { defaults.set(showDisk, forKey: "showDisk") } }
    @Published var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
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
            "refreshInterval": 1.0
        ])
        showCPU = defaults.bool(forKey: "showCPU")
        showRAM = defaults.bool(forKey: "showRAM")
        showNet = defaults.bool(forKey: "showNet")
        showDisk = defaults.bool(forKey: "showDisk")
        refreshInterval = defaults.double(forKey: "refreshInterval")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}