import SwiftUI

struct DetailView: View {
    @ObservedObject var sampler: Sampler
    @ObservedObject var settings: SettingsStore

    var body: some View {
        let s = sampler.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(s)
                if let cpu = s.cpu { cpuSection(cpu) }
                if let m = s.memory { memorySection(m) }
                networkSection(s)
                diskSection(s.disk)
                settingsSection
            }
            .padding(14)
        }
        .frame(width: 340, height: 480)
    }

    private func header(_ s: Snapshot) -> some View {
        HStack {
            Text("LightMonitor").font(.headline)
            Spacer()
            Text(String(format: "自身 %.1f MB · %.1f%%",
                        Double(s.selfUsage.footprint) / 1_048_576,
                        s.selfUsage.cpuPercent))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: CPU

    private func cpuSection(_ cpu: CPUSample) -> some View {
        SectionBox(title: "CPU", trailing: Fmt.pct(cpu.total)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("用户 \(Fmt.pct(cpu.user))").font(.caption).foregroundStyle(.secondary)
                    Text("系统 \(Fmt.pct(cpu.system))").font(.caption).foregroundStyle(.secondary)
                }
                let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                LazyVGrid(columns: cols, spacing: 4) {
                    ForEach(Array(cpu.perCore.enumerated()), id: \.offset) { idx, load in
                        HStack(spacing: 4) {
                            Text("\(idx + 1)").font(.caption2.monospacedDigit())
                                .frame(width: 16, alignment: .trailing)
                            ProgressView(value: load)
                            Text(Fmt.pct(load)).font(.caption2.monospacedDigit())
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: Memory

    private func memorySection(_ m: MemorySample) -> some View {
        SectionBox(title: "内存", trailing: "\(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total))") {
            VStack(alignment: .leading, spacing: 6) {
                if m.total > 0 {
                    ProgressView(value: Double(m.used), total: Double(m.total))
                }
                row("App 内存", Fmt.bytes(m.app))
                row("联动内存 (Wired)", Fmt.bytes(m.wired))
                row("已压缩", Fmt.bytes(m.compressed))
                row("缓存文件", Fmt.bytes(m.cached))
                row("Swap 已用", Fmt.bytes(m.swapUsed))
                HStack {
                    Text("内存压力").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    pressureBadge(m.pressure)
                }
            }
        }
    }

    private func pressureBadge(_ level: Int32) -> some View {
        let (text, color): (String, Color) = {
            switch level {
            case 2: return ("警告", .orange)
            case 4: return ("紧急", .red)
            default: return ("正常", .green)
            }
        }()
        return Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Network

    private func networkSection(_ s: Snapshot) -> some View {
        SectionBox(title: "网络", trailing: "↓\(Fmt.rate(s.netRx))/s  ↑\(Fmt.rate(s.netTx))/s") {
            VStack(alignment: .leading, spacing: 4) {
                if s.net.isEmpty {
                    Text("无活动物理接口").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(s.net, id: \.name) { iface in
                        HStack {
                            Text(iface.name).font(.caption.monospaced())
                            Spacer()
                            Text("↓ \(Fmt.rate(iface.rxRate))/s").font(.caption.monospacedDigit())
                            Text("↑ \(Fmt.rate(iface.txRate))/s").font(.caption.monospacedDigit())
                                .frame(width: 80, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: Disk

    private func diskSection(_ d: DiskSample) -> some View {
        SectionBox(title: "磁盘", trailing: d.total > 0 ? "\(Fmt.bytes(d.used)) / \(Fmt.bytes(d.total))" : "--") {
            VStack(alignment: .leading, spacing: 6) {
                if d.total > 0 {
                    ProgressView(value: Double(d.used), total: Double(d.total))
                }
                HStack(spacing: 16) {
                    Text("读 \(Fmt.rate(d.readRate))/s").font(.caption.monospacedDigit())
                    Text("写 \(Fmt.rate(d.writeRate))/s").font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        SectionBox(title: "设置", trailing: nil) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("菜单栏显示 CPU", isOn: $settings.showCPU)
                Toggle("菜单栏显示内存", isOn: $settings.showRAM)
                Toggle("菜单栏显示网络", isOn: $settings.showNet)
                Toggle("菜单栏显示磁盘", isOn: $settings.showDisk)
                Picker("刷新频率", selection: $settings.refreshInterval) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("5 秒").tag(5.0)
                }
                .pickerStyle(.segmented)
                Toggle("开机自启", isOn: $settings.launchAtLogin)
                HStack {
                    Spacer()
                    Button("退出 LightMonitor") { NSApp.terminate(nil) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer()
                if let trailing {
                    Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}