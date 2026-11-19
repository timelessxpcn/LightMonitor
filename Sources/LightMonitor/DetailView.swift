import SwiftUI

struct DetailView: View {
    @ObservedObject var sampler: Sampler
    @ObservedObject var settings: SettingsStore
    @ObservedObject var history: HistoryStore

    var body: some View {
        let s = sampler.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(s)
                if let cpu = s.cpu { cpuSection(cpu) }
                if let m = s.memory { memorySection(m) }
                networkSection(s)
                diskSection(s.disk)
                if let gpu = s.gpu { gpuSection(gpu) }
                if let bat = s.battery { batterySection(bat) }
                if let sensors = s.sensors { sensorsSection(sensors) }
                processSection(s)
                if settings.historyEnabled { historySection }
                settingsSection
                alertSection
            }
            .padding(14)
        }
        .frame(width: 340, height: 560)
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

    // MARK: GPU / Battery

    private func gpuSection(_ util: Double) -> some View {
        SectionBox(title: "GPU", trailing: Fmt.pct(util)) {
            ProgressView(value: util)
        }
    }

    private func batterySection(_ b: BatterySample) -> some View {
        SectionBox(title: "电池", trailing: "\(b.percent)%") {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(b.percent), total: 100)
                HStack(spacing: 12) {
                    Text(b.onAC ? "电源适配器" : "电池供电")
                    if b.isCharging { Text("充电中") }
                    if let t = b.minutesToEmpty, !b.onAC { Text("剩余约 \(t / 60) 小时 \(t % 60) 分") }
                    if let c = b.cycleCount { Text("循环 \(c) 次") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Sensors

    private func sensorsSection(_ sensors: [SensorReading]) -> some View {
        SectionBox(title: "温度传感器", trailing: sensors.first.map { String(format: "最高 %.1f°C", $0.value) } ?? nil) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sensors.prefix(8)) { s in
                    HStack {
                        Text(s.key).font(.caption.monospaced())
                        Spacer()
                        Text(String(format: "%.1f °C", s.value)).font(.caption.monospacedDigit())
                    }
                }
                Text("SMC 热区编号，非单核温度 · 每 5 秒采样")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Top processes

    private func processSection(_ s: Snapshot) -> some View {
        SectionBox(title: "Top 进程", trailing: "每 5 秒扫描") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $settings.processSort) {
                    Text("按 CPU").tag(0)
                    Text("按内存").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                let list = settings.processSort == 0 ? s.topCPU : s.topMem
                if list.isEmpty {
                    Text("扫描中…").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(list) { p in
                        HStack {
                            Text(p.name).font(.caption).lineLimit(1)
                            Spacer()
                            if settings.processSort == 0 {
                                Text(String(format: "%.1f%%", p.cpu))
                                    .font(.caption.monospacedDigit())
                                Text(p.footprint > 0 ? Fmt.bytes(p.footprint) : "—")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                            } else {
                                Text(p.footprint > 0 ? Fmt.bytes(p.footprint) : "—")
                                    .font(.caption.monospacedDigit())
                                Text(String(format: "%.1f%%", p.cpu))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: History

    private var historySection: some View {
        // revision 驱动重绘（每 30s 落盘后 +1），避免每秒查库
        let _ = history.revision
        let range = settings.historyRange
        return SectionBox(title: "历史曲线", trailing: "本地保存 7 天") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $settings.historyRange) {
                    Text("30 分钟").tag(1800)
                    Text("24 小时").tag(86400)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                historyRow("CPU", key: "cpu", range: range, fixedMax: 1, color: .blue)
                historyRow("内存", key: "mem", range: range, fixedMax: 1, color: .green)
                historyRow("网络 ↓", key: "net_rx", range: range, fixedMax: nil, color: .cyan)
            }
        }
    }

    private func historyRow(_ label: String, key: String, range: Int, fixedMax: Double?, color: Color) -> some View {
        let data = history.series(key: key, range: range)
        let values = data.map { $0.1 }
        let maxV = fixedMax ?? max(values.max() ?? 0, 1024)
        let norm = values.map { min(1, $0 / maxV) }
        let current: String = {
            guard let last = values.last else { return "—" }
            if fixedMax != nil { return Fmt.pct(last) }
            return Fmt.rate(last) + "/s"
        }()
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(current).font(.caption.monospacedDigit())
            }
            Sparkline(points: norm, color: color)
                .frame(height: 36)
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
                Toggle("菜单栏显示 GPU", isOn: $settings.showGPU)
                Toggle("菜单栏显示电池", isOn: $settings.showBattery)
                Toggle("菜单栏显示温度（SMC）", isOn: $settings.showSensors)
                Picker("刷新频率", selection: $settings.refreshInterval) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("5 秒").tag(5.0)
                }
                .pickerStyle(.segmented)
                Toggle("开机自启", isOn: $settings.launchAtLogin)
                Toggle("记录历史曲线（本地）", isOn: $settings.historyEnabled)
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

    // MARK: Alerts

    private var alertSection: some View {
        SectionBox(title: "阈值告警", trailing: nil) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("启用系统通知告警", isOn: $settings.alertsEnabled)
                if settings.alertsEnabled {
                    thresholdRow("CPU", value: $settings.cpuThreshold)
                    thresholdRow("内存", value: $settings.memThreshold)
                    thresholdRow("磁盘", value: $settings.diskThreshold)
                    Text("超过阈值时通知一次，回落后再次超标才会再通知。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption)
        }
    }

    private func thresholdRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 36, alignment: .leading)
            Stepper(value: value, in: 50...99, step: 5) {
                Text("\(Int(value.wrappedValue))%").monospacedDigit()
            }
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

/// 轻量火花线：纯 Path 绘制，无 Charts 框架依赖
private struct Sparkline: View {
    let points: [Double]   // 归一化 0...1
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if points.count > 1 {
                Path { p in
                    for (i, v) in points.enumerated() {
                        let pt = CGPoint(x: w * CGFloat(i) / CGFloat(points.count - 1),
                                         y: h * (1 - CGFloat(v)))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            } else {
                Text("数据积累中…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: w, height: h, alignment: .center)
            }
        }
    }
}