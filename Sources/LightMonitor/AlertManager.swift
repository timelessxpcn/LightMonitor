import Foundation
import UserNotifications

/// 阈值告警：上升沿触发（低于阈值→超过阈值才通知），回落后重新武装，避免刷屏。
final class AlertManager {
    private var armed: [String: Bool] = ["cpu": true, "mem": true, "disk": true]
    private var authorized = false

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func evaluate(_ s: Snapshot, settings: SettingsStore) {
        guard settings.alertsEnabled else { return }
        if !authorized { requestAuthorization() }

        if let cpu = s.cpu {
            check("cpu", value: cpu.total * 100, threshold: settings.cpuThreshold,
                  body: String(format: "CPU 使用率 %.0f%%，已超过阈值 %.0f%%", cpu.total * 100, settings.cpuThreshold))
        }
        if let m = s.memory, m.total > 0 {
            let pct = Double(m.used) / Double(m.total) * 100
            check("mem", value: pct, threshold: settings.memThreshold,
                  body: String(format: "内存占用 %.0f%%，已超过阈值 %.0f%%", pct, settings.memThreshold))
        }
        let d = s.disk
        if d.total > 0 {
            let pct = Double(d.used) / Double(d.total) * 100
            check("disk", value: pct, threshold: settings.diskThreshold,
                  body: String(format: "磁盘空间已用 %.0f%%，已超过阈值 %.0f%%", pct, settings.diskThreshold))
        }
    }

    private func check(_ key: String, value: Double, threshold: Double, body: String) {
        if value >= threshold {
            guard armed[key] != false else { return }
            armed[key] = false
            let content = UNMutableNotificationContent()
            content.title = "LightMonitor 阈值告警"
            content.body = body
            content.sound = .default
            content.threadIdentifier = "lightmonitor.alert.\(key)"
            let req = UNNotificationRequest(identifier: "lightmonitor.alert.\(key)",
                                            content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        } else {
            armed[key] = true
        }
    }
}