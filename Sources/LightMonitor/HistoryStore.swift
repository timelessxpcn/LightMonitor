import Foundation
import SQLite3

/// 本地历史：系统 SQLite3 直用（零第三方依赖）。
/// - 节流落盘：每 30s 批量写一次（>10× 采样周期）
/// - 保留策略：7 天滚动清理
/// - 内存环形缓冲：最近 30 分钟供面板火花线实时显示
/// - 所有 DB 操作在专用串行队列；读取带 30s 缓存，避免面板每秒查库
final class HistoryStore: ObservableObject {
    static let keys = ["cpu", "mem", "net_rx", "net_tx", "disk", "gpu"]

    @Published private(set) var revision = 0
    var enabled = true

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "lightmonitor.history", qos: .utility)
    private var buffers: [String: [(ts: Double, v: Double)]] = [:]
    private var lastWrite: Double = 0
    private var lastCleanup: Double = 0
    private var cache: [String: (range: Int, at: Double, data: [(Double, Double)])] = [:]

    private let writeInterval: Double = 30
    private let retention: Double = 7 * 86400
    private let liveWindow: Double = 1800
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        queue.sync {
            openDB()
            loadLive()
            cleanup(now: Date().timeIntervalSince1970)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Write path

    /// 由采样线程调用；内部节流，未到期直接返回
    func record(ts: Double, values: [String: Double]) {
        queue.async { [weak self] in
            guard let self, self.enabled, let db = self.db else { return }
            guard ts - self.lastWrite >= self.writeInterval else { return }
            self.lastWrite = ts

            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO samples(ts, key, value) VALUES(?,?,?)", -1, &stmt, nil) == SQLITE_OK {
                for (key, value) in values {
                    sqlite3_reset(stmt)
                    sqlite3_bind_int64(stmt, 1, Int64(ts))
                    sqlite3_bind_text(stmt, 2, key, -1, self.transient)
                    sqlite3_bind_double(stmt, 3, value)
                    sqlite3_step(stmt)
                    self.appendBuffer(key: key, ts: ts, v: value)
                }
            }
            sqlite3_finalize(stmt)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)

            if ts - self.lastCleanup >= 6 * 3600 {
                self.cleanup(now: ts)
            }
            DispatchQueue.main.async { self.revision += 1 }
        }
    }

    private func appendBuffer(key: String, ts: Double, v: Double) {
        var arr = buffers[key] ?? []
        arr.append((ts, v))
        let cutoff = ts - liveWindow
        if let first = arr.firstIndex(where: { $0.ts >= cutoff }), first > 0 {
            arr.removeFirst(first)
        }
        buffers[key] = arr
    }

    // MARK: - Read path

    /// 面板读取：<=30 分钟走内存缓冲；更长时间范围查库并按桶聚合（~240 点），结果缓存 30s
    func series(key: String, range: Int) -> [(Double, Double)] {
        queue.sync {
            let now = Date().timeIntervalSince1970
            if range <= Int(liveWindow) {
                return buffers[key] ?? []
            }
            if let c = cache[key], c.range == range, now - c.at < 30 {
                return c.data
            }
            guard let db else { return [] }
            let bucket = max(1, range / 240)
            let sql = "SELECT (ts / ?) * ? AS b, AVG(value) FROM samples WHERE key = ? AND ts >= ? GROUP BY b ORDER BY b"
            var stmt: OpaquePointer?
            var data: [(Double, Double)] = []
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, Int64(bucket))
                sqlite3_bind_int64(stmt, 2, Int64(bucket))
                sqlite3_bind_text(stmt, 3, key, -1, transient)
                sqlite3_bind_int64(stmt, 4, Int64(now - Double(range)))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    data.append((Double(sqlite3_column_int64(stmt, 0)), sqlite3_column_double(stmt, 1)))
                }
            }
            sqlite3_finalize(stmt)
            cache[key] = (range, now, data)
            return data
        }
    }

    // MARK: - DB maintenance

    private func openDB() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = base.appendingPathComponent("LightMonitor", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("history.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            db = nil
            return
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS samples(
                ts INTEGER NOT NULL,
                key TEXT NOT NULL,
                value REAL NOT NULL,
                PRIMARY KEY(ts, key)
            );
            CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts);
            """, nil, nil, nil)
    }

    private func loadLive() {
        guard let db else { return }
        let cutoff = Int64(Date().timeIntervalSince1970 - liveWindow)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT ts, key, value FROM samples WHERE ts >= ? ORDER BY ts", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, cutoff)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = Double(sqlite3_column_int64(stmt, 0))
                let key = String(cString: sqlite3_column_text(stmt, 1))
                let v = sqlite3_column_double(stmt, 2)
                buffers[key, default: []].append((ts, v))
            }
        }
        sqlite3_finalize(stmt)
    }

    private func cleanup(now: Double) {
        guard let db else { return }
        lastCleanup = now
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM samples WHERE ts < ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, Int64(now - retention))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
}