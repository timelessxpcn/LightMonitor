import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let history = HistoryStore()
    private lazy var sampler = Sampler(settings: settings, history: history)
    private let alerts = AlertManager()
    private var statusController: StatusController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusController(sampler: sampler, settings: settings, history: history)
        statusController = controller
        sampler.onSnapshot = { [weak self] snap in
            controller.update(snap)
            guard let self else { return }
            self.alerts.evaluate(snap, settings: self.settings)
        }
        sampler.interval = settings.refreshInterval
        sampler.start()

        settings.$refreshInterval
            .dropFirst()
            .sink { [weak self] value in self?.sampler.interval = value }
            .store(in: &cancellables)

        settings.$alertsEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                if enabled { self?.alerts.requestAuthorization() }
            }
            .store(in: &cancellables)

        history.enabled = settings.historyEnabled
        settings.$historyEnabled
            .dropFirst()
            .sink { [weak self] enabled in self?.history.enabled = enabled }
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