import AppKit
import SwiftUI

/// 菜单栏状态项 + 弹出详情面板。
/// 面板关闭时销毁 contentViewController，保证无常驻 UI 渲染成本。
final class StatusController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let sampler: Sampler
    private let settings: SettingsStore
    private var lastTitle: String = ""
    private var lastTitleUpdate: Date = .distantPast

    init(sampler: Sampler, settings: SettingsStore) {
        self.sampler = sampler
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.title = "LM"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    func update(_ s: Snapshot) {
        // 菜单栏位图重绘是主要 CPU 成本：节流至 ~2s 一次；面板数据仍按采样频率实时
        let now = Date()
        guard now.timeIntervalSince(lastTitleUpdate) >= 1.9 else { return }
        lastTitleUpdate = now
        var parts: [String] = []
        if settings.showCPU {
            parts.append("CPU " + (s.cpu.map { Fmt.pct($0.total) } ?? "--"))
        }
        if settings.showRAM {
            if let m = s.memory, m.total > 0 {
                parts.append("RAM " + Fmt.pct(Double(m.used) / Double(m.total)))
            } else { parts.append("RAM --") }
        }
        if settings.showNet {
            parts.append("↓\(Fmt.rate(s.netRx)) ↑\(Fmt.rate(s.netTx))")
        }
        if settings.showDisk {
            let d = s.disk
            parts.append("DSK " + (d.total > 0 ? Fmt.pct(Double(d.used) / Double(d.total)) : "--"))
        }
        if settings.showGPU {
            parts.append("GPU " + (s.gpu.map { Fmt.pct($0) } ?? "--"))
        }
        if settings.showBattery {
            parts.append("BAT " + (s.battery.map { "\($0.percent)%" } ?? "--"))
        }
        let text = parts.isEmpty ? "LM" : parts.joined(separator: "  ")
        guard text != lastTitle else { return }   // 值未变化不重绘
        lastTitle = text
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ])
        statusItem.button?.attributedTitle = attr
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button else { return }
        let root = DetailView(sampler: sampler, settings: settings)
        let host = NSHostingController(rootView: root)
        host.view.frame = NSRect(x: 0, y: 0, width: 340, height: 560)
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 340, height: 560)
        sampler.panelOpen = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        sampler.panelOpen = false
    }
}