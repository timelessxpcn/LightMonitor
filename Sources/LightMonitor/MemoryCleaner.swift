import Foundation
import AppKit

/// 一键释放磁盘缓存：调用系统 /usr/sbin/purge（需管理员授权，系统弹窗确认）。
/// 诚实口径：只清磁盘缓存（cached files），不动 App 内存；macOS 会自动重建缓存，
/// 释放后短期磁盘读取可能略增。不做"猛占内存逼换页"式清理（伤整机性能与 SSD）。
final class CleanerState: ObservableObject {
    enum Status {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    @Published private(set) var status: Status = .idle

    private let queue = DispatchQueue(label: "lightmonitor.cleaner", qos: .userInitiated)
    private let memReader = MemoryReader()

    func purge() {
        guard case .idle = status else { return }
        status = .running

        let before = memReader.read()
        queue.async { [weak self] in
            guard let self else { return }
            // with administrator privileges → 系统标准授权弹窗；用户取消返回 -128
            let script = NSAppleScript(source: "do shell script \"/usr/sbin/purge\" with administrator privileges")
            var errorInfo: NSDictionary?
            let result = script?.executeAndReturnError(&errorInfo)

            let message: String
            let ok: Bool
            if result != nil {
                // purge 生效需要一点时间，稍等再读
                Thread.sleep(forTimeInterval: 1.0)
                let after = self.memReader.read()
                if let b = before, let a = after {
                    let freed = b.cached > a.cached ? b.cached - a.cached : 0
                    message = freed > 0
                        ? "已释放约 \(Fmt.bytes(freed)) 磁盘缓存"
                        : "缓存已清理（当前无可释放缓存）"
                } else {
                    message = "缓存清理完成"
                }
                ok = true
            } else {
                let code = (errorInfo?[NSAppleScript.errorNumber] as? Int) ?? 0
                if code == -128 {
                    message = "已取消（未执行任何操作）"
                } else {
                    let detail = (errorInfo?[NSAppleScript.errorMessage] as? String) ?? "未知错误"
                    message = "清理失败：\(detail)"
                }
                ok = false
            }
            DispatchQueue.main.async {
                self.status = ok ? .success(message) : .failure(message)
                // 8 秒后回到 idle，允许再次点击
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    if case .running = self.status { return }
                    self.status = .idle
                }
            }
        }
    }
}