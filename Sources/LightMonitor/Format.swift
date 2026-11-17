import Foundation

enum Fmt {
    /// 紧凑速率：1.2M / 34K / 8B（每秒字节）
    static func rate(_ bps: Double) -> String {
        let b = max(0, bps)
        if b >= 1_073_741_824 { return String(format: "%.1fG", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1fM", b / 1_048_576) }
        if b >= 1024 { return String(format: "%.0fK", b / 1024) }
        return String(format: "%.0fB", b)
    }

    /// 容量：8.2 GB
    static func bytes(_ v: UInt64) -> String {
        let units: [(Double, String)] = [
            (1_099_511_627_776, "TB"), (1_073_741_824, "GB"), (1_048_576, "MB"), (1024, "KB")
        ]
        let d = Double(v)
        for (div, unit) in units where d >= div {
            return String(format: "%.1f %@", d / div, unit)
        }
        return "\(v) B"
    }

    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}