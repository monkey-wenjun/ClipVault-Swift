import Foundation
import SQLite3

/// SQLite 持久化层（直接调用系统 libsqlite3，零第三方依赖）。
///
/// 设计要点：
/// - 每条记录的业务字段序列化为 JSON 后用 `CryptoService` 做 AES-GCM 加密，以 BLOB 存入
///   `payload` 列；数据库本身只见密文，保持与旧方案一致的落盘加密安全属性。
/// - `items` 表按「变更行」增量写入：高频的剪贴板收录路径只 upsert 一行，删除只删一行，
///   不再每次全量重写整份历史。排序完全依据 `created_at`（历史条目始终按创建时间倒序），
///   避免引入会导致每次插入都要改动所有行的位置列。
/// - `pinboards` 表数量少、改动低频（重命名/拖拽排序/增删），整表重写即可，简单且不易出错。
/// - 所有方法都在传入的串行队列上执行，保证单连接的线程安全。
///
/// 注意：SQLite 的 `SQLITE_TRANSIENT` 让它在绑定时拷贝入参，避免 Swift 值在语句执行前被释放。
///
/// `@unchecked Sendable`：本类只被 HistoryStore 的串行 saveQueue（以及初始化阶段）访问，
/// 单连接不跨线程并发使用，故手动保证线程安全。
final class HistoryDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let path: String

    /// 已持久化的历史条目快照（id → item），用于增量计算：
    /// 只有新增或内容变化的行才会被重新编码加密写入，消失的行才会被删除。
    /// 仅在 loadItems / syncItems 内维护；这两个入口在初始化阶段（主线程）之后
    /// 只会由 HistoryStore 的串行 saveQueue 访问，故无需额外加锁。
    private var persistedItems: [UUID: ClipboardItem] = [:]

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 打开（或创建）数据库并建表。失败时抛出，调用方需处理回退。
    init(path: URL) throws {
        self.path = path.path
        try open()
        try configure()
        try createSchema()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func open() throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DBError.open(message)
        }
        // 数据库文件权限收紧到仅本用户可读写
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private func configure() throws {
        // WAL 模式：并发读不阻塞写、崩溃恢复更稳；NORMAL 同步级别在 WAL 下兼顾安全与性能
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA foreign_keys=ON;")
    }

    private func createSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_items_created_at ON items(created_at DESC);")
        try exec("""
        CREATE TABLE IF NOT EXISTS pinboards (
            id TEXT PRIMARY KEY,
            position INTEGER NOT NULL,
            payload BLOB NOT NULL
        );
        """)
        // 存储版本等元信息，便于后续演进
        try exec("""
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    // MARK: - 读取

    /// 读取全部历史条目，按创建时间倒序（与内存中的顺序一致）。
    /// 单行解密/解码失败会被跳过（容错，不因个别损坏行导致整体加载失败）。
    func loadItems() -> [ClipboardItem] {
        var result: [ClipboardItem] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM items ORDER BY created_at DESC;", -1, &stmt, nil) == SQLITE_OK else {
            return result
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item: ClipboardItem = decodeRow(stmt, column: 0) {
                result.append(item)
            }
        }
        persistedItems = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return result
    }

    /// 读取全部集合，按 position 升序。
    func loadPinboards() -> [Pinboard] {
        var result: [Pinboard] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM pinboards ORDER BY position ASC;", -1, &stmt, nil) == SQLITE_OK else {
            return result
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let board: Pinboard = decodeRow(stmt, column: 0) {
                result.append(board)
            }
        }
        return result
    }

    // MARK: - 增量写入（items）

    /// 把内存中的完整 items 快照增量同步到 items 表：
    /// - 删除数据库中已不存在的行；
    /// - 只对「新增」或「内容发生变化」的条目做 encode+加密+upsert，未变化的行完全跳过。
    /// 依赖内部维护的 `persistedItems` 快照做差异比较，无需外部传入历史状态。
    func syncItems(_ items: [ClipboardItem]) {
        let currentIDs = Set(items.map(\.id))
        let removed = Set(persistedItems.keys).subtracting(currentIDs)
        // 找出新增或内容变化的条目（ClipboardItem 为 Equatable，比较开销小）
        let changed = items.filter { persistedItems[$0.id] != $0 }

        guard !removed.isEmpty || !changed.isEmpty else { return }

        transaction {
            if !removed.isEmpty {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM items WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK {
                    for id in removed {
                        sqlite3_reset(stmt)
                        bindText(stmt, index: 1, id.uuidString)
                        _ = sqlite3_step(stmt)
                    }
                    sqlite3_finalize(stmt)
                }
            }
            if !changed.isEmpty {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db,
                    "INSERT INTO items(id, created_at, payload) VALUES(?, ?, ?) " +
                    "ON CONFLICT(id) DO UPDATE SET created_at=excluded.created_at, payload=excluded.payload;",
                    -1, &stmt, nil) == SQLITE_OK {
                    for item in changed {
                        guard let blob = encodeRow(item) else { continue }
                        sqlite3_reset(stmt)
                        bindText(stmt, index: 1, item.id.uuidString)
                        sqlite3_bind_double(stmt, 2, item.createdAt.timeIntervalSince1970)
                        bindBlob(stmt, index: 3, blob)
                        _ = sqlite3_step(stmt)
                    }
                    sqlite3_finalize(stmt)
                }
            }
        }

        // 更新内部快照，供下次差异比较
        for id in removed { persistedItems[id] = nil }
        for item in changed { persistedItems[item.id] = item }
    }

    // MARK: - 整表重写（pinboards）

    /// 整表重写集合（数量少、低频修改，简单可靠）。
    func replacePinboards(_ pinboards: [Pinboard]) {
        transaction {
            _ = try? exec("DELETE FROM pinboards;")
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT INTO pinboards(id, position, payload) VALUES(?, ?, ?);", -1, &stmt, nil) == SQLITE_OK {
                for (index, board) in pinboards.enumerated() {
                    guard let blob = encodeRow(board) else { continue }
                    sqlite3_reset(stmt)
                    bindText(stmt, index: 1, board.id.uuidString)
                    sqlite3_bind_int64(stmt, 2, Int64(index))
                    bindBlob(stmt, index: 3, blob)
                    _ = sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
        }
    }

    /// 清空全部历史条目（不影响集合）。
    func clearItems() {
        try? exec("DELETE FROM items;")
        persistedItems.removeAll()
    }

    // MARK: - 编解码 + 加密

    private func encodeRow<T: Encodable>(_ value: T) -> Data? {
        guard let json = try? JSONEncoder().encode(value) else { return nil }
        return CryptoService.encrypt(json)
    }

    private func decodeRow<T: Decodable>(_ stmt: OpaquePointer?, column: Int32) -> T? {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, column))
        let raw = Data(bytes: bytes, count: count)
        // 解密失败按明文兜底（理论上不会发生，仅防御）
        let json = CryptoService.decrypt(raw) ?? raw
        return try? JSONDecoder().decode(T.self, from: json)
    }

    // MARK: - SQLite 基础封装

    private func bindText(_ stmt: OpaquePointer?, index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }

    private func bindBlob(_ stmt: OpaquePointer?, index: Int32, _ data: Data) {
        _ = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(stmt, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
        }
    }

    private func transaction(_ body: () -> Void) {
        _ = try? exec("BEGIN IMMEDIATE;")
        body()
        _ = try? exec("COMMIT;")
    }

    private func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let message = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw DBError.exec(message)
        }
    }

    enum DBError: LocalizedError {
        case open(String)
        case exec(String)

        var errorDescription: String? {
            switch self {
            case .open(let m): return "SQLite open failed: \(m)"
            case .exec(let m): return "SQLite exec failed: \(m)"
            }
        }
    }
}
