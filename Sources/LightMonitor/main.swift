import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let sampler = Sampler()
    private var statusController: StatusController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusController(sampler: sampler, settings: settings)
        sampler.interval = settings.refreshInterval
        sampler.start()

        settings.$refreshInterval
            .dropFirst()
            .sink { [weak self] value in self?.sampler.interval = value }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        sampler.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不占 Dock、不进 App 切换器
app.run()