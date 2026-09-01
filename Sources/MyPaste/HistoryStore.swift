import AppKit

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var pinboards: [Pinboard] = []

    /// 历史记录保留上限（默认 500，可在设置中调整）
    var maxItems: Int = 500
    private let baseDir: URL
    private let imagesDir: URL
    private var dbFile: URL { baseDir.appendingPathComponent("clipvault.sqlite") }
    // 旧版 JSON 文件路径，仅用于一次性迁移
    private var legacyHistoryFile: URL { baseDir.appendingPathComponent("history.json") }
    private var legacyPinboardsFile: URL { baseDir.appendingPathComponent("pinboards.json") }

    /// 每次本地保存后回调（同步引擎借此把变更写到同步目录）
    var onSaved: (() -> Void)?

    /// SQLite 持久化层（在 saveQueue 上访问，保证串行）
    private let db: HistoryDatabase?

    /// 保存防抖：合并短时间内的多次写入
    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.clipvault.save", qos: .utility)

    /// 增量保存脏标记：只把发生变化的表写盘，
    /// 避免每次改动都同时重写 items 与 pinboards
    private var itemsDirty = false
    private var pinboardsDirty = false

    /// 图片文件哈希缓存：避免重复读取图片数据做去重比较
    private var imageHashCache: [String: Data] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir = appSupport.appendingPathComponent("ClipVault", isDirectory: true)
        imagesDir = baseDir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)

        db = try? HistoryDatabase(path: baseDir.appendingPathComponent("clipvault.sqlite"))
        migrateLegacyJSONIfNeeded()
        load()

        // 损坏条目清理移到后台，不阻塞启动。用加载后的内存快照检查，避免后台再读盘/触碰 DB。
        let itemsSnapshot = items
        let pinboardsSnapshot = pinboards
        let imagesDir = self.imagesDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let brokenIDs = Self.findBrokenItemIDs(items: itemsSnapshot, pinboards: pinboardsSnapshot, imagesDir: imagesDir)
            if !brokenIDs.isEmpty {
                Task { @MainActor in
                    self?.removeBrokenItems(ids: brokenIDs)
                }
            }
        }
    }

    // MARK: - 历史

    @discardableResult
    func addText(_ text: String, sourceBundleID: String?) -> ClipboardItem {
        // 去重：只检查最近 100 条，重复复制几乎都发生在短时间内
        let checkLimit = min(100, items.count)
        if let dup = items.prefix(checkLimit).firstIndex(where: { $0.kind != .image && $0.text == text }) {
            items.remove(at: dup)
        }
        let kind: ClipboardItem.Kind = Self.isHexColor(text) ? .color : .text
        let item = ClipboardItem(id: UUID(), kind: kind, text: text, imageFile: nil,
                                 fileSize: nil, createdAt: Date(), sourceBundleID: sourceBundleID)
        items.insert(item, at: 0)
        trim()
        scheduleSave(items: true, pinboards: false)
        return item
    }

    func updateText(id: UUID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].kind = Self.isHexColor(text) ? .color : .text
        items[index].text = text
        scheduleSave(items: true, pinboards: false)
    }

    func updatePinboardText(pinboardID: UUID, itemID: UUID, text: String) {
        guard let boardIndex = pinboards.firstIndex(where: { $0.id == pinboardID }),
              let itemIndex = pinboards[boardIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
        pinboards[boardIndex].items[itemIndex].kind = Self.isHexColor(text) ? .color : .text
        pinboards[boardIndex].items[itemIndex].text = text
        scheduleSave(items: false, pinboards: true)
    }

    /// 为指定条目设置自定义标题；传 nil 或空字符串则恢复默认标题
    func setCustomTitle(_ title: String?, forItemID id: UUID) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedTitle = trimmed?.isEmpty == false ? trimmed : nil
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].customTitle = storedTitle
        }
        for boardIndex in pinboards.indices {
            if let itemIndex = pinboards[boardIndex].items.firstIndex(where: { $0.id == id }) {
                pinboards[boardIndex].items[itemIndex].customTitle = storedTitle
            }
        }
        scheduleSave()
    }

    @discardableResult
    func addImage(_ pngData: Data, sourceBundleID: String?) -> ClipboardItem? {
        // 图片去重优化：计算新数据的前缀哈希，只比较最近 50 条图片（解密比较成本太高）
        let newHash = pngData.prefix(4096).withUnsafeBytes { Data($0) }
        let checkLimit = min(50, items.count)
        if let dupIndex = items.prefix(checkLimit).firstIndex(where: { item -> Bool in
            guard item.kind == .image, let file = item.imageFile else { return false }
            if let cachedHash = imageHashCache[file] {
                return cachedHash == newHash
            }
            guard let decrypted = Self.loadImageData(fileName: file, imagesDir: imagesDir) else { return false }
            let prefixHash = decrypted.prefix(4096).withUnsafeBytes { Data($0) }
            imageHashCache[file] = prefixHash
            return prefixHash == newHash
        }) {
            items[dupIndex].createdAt = Date()
            items[dupIndex].sourceBundleID = sourceBundleID
            let dup = items.remove(at: dupIndex)
            items.insert(dup, at: 0)
            scheduleSave(items: true, pinboards: false)
            return dup
        }
        guard let encrypted = CryptoService.encrypt(pngData) else { return nil }
        let fileName = UUID().uuidString + ".png"
        do {
            try encrypted.write(to: imagesDir.appendingPathComponent(fileName), options: .atomic)
        } catch {
            return nil
        }
        imageHashCache[fileName] = newHash
        let item = ClipboardItem(id: UUID(), kind: .image, text: nil, imageFile: fileName,
                                 fileSize: nil, createdAt: Date(), sourceBundleID: sourceBundleID)
        items.insert(item, at: 0)
        trim()
        scheduleSave(items: true, pinboards: false)
        return item
    }

    /// 从本地图片文件创建图片条目（转换为 PNG 后加密存储）
    @discardableResult
    func addImage(fromFileURL url: URL, sourceBundleID: String?) -> ClipboardItem? {
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data),
              let pngData = image.pngRepresentation else { return nil }
        return addImage(pngData, sourceBundleID: sourceBundleID)
    }

    /// 拖拽文件到面板时创建文件引用条目
    @discardableResult
    func addFile(path: String, sourceBundleID: String?) -> ClipboardItem {
        // 文件去重：只检查最近 100 条
        let checkLimit = min(100, items.count)
        if let dup = items.prefix(checkLimit).firstIndex(where: { $0.kind == .file && $0.text == path }) {
            items.remove(at: dup)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let item = ClipboardItem(id: UUID(), kind: .file, text: path,
                                 imageFile: nil, fileSize: size > 0 ? size : nil,
                                 createdAt: Date(), sourceBundleID: sourceBundleID)
        items.insert(item, at: 0)
        trim()
        scheduleSave(items: true, pinboards: false)
        return item
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        deleteImageFile(of: item)
        if let file = item.imageFile { imageHashCache.removeValue(forKey: file) }
        scheduleSave(items: true, pinboards: false)
    }

    /// 从历史和所有集合中移除指定条目（用于清理损坏图片）
    func removeEverywhere(_ itemID: UUID) {
        if let item = items.first(where: { $0.id == itemID }) {
            remove(item)
        }
        for board in pinboards where board.items.contains(where: { $0.id == itemID }) {
            removeFromPinboard(itemID, pinboardID: board.id)
        }
    }

    func clear() {
        items.removeAll()
        imageHashCache.removeAll()
        try? FileManager.default.removeItem(at: imagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        itemsDirty = true
        save()
    }

    /// 保留策略：删除超过 days 天的历史条目（0 = 永久保留）。不影响集合。
    func prune(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let expired = items.filter { $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        expired.forEach { item in
            deleteImageFile(of: item)
            if let file = item.imageFile { imageHashCache.removeValue(forKey: file) }
        }
        items.removeAll { $0.createdAt < cutoff }
        scheduleSave(items: true, pinboards: false)
    }

    /// 更新历史保留上限并立即裁剪超出部分
    func setMaxItems(_ count: Int) {
        let clamped = min(max(count, AppSettings.maxHistoryItemsRange.lowerBound),
                          AppSettings.maxHistoryItemsRange.upperBound)
        maxItems = clamped
        if items.count > maxItems {
            let removed = items[maxItems...]
            removed.forEach { item in
                deleteImageFile(of: item)
                if let file = item.imageFile { imageHashCache.removeValue(forKey: file) }
            }
            items = Array(items.prefix(maxItems))
            scheduleSave(items: true, pinboards: false)
        }
    }

    // MARK: - 集合

    @discardableResult
    func addPinboard(name: String) -> Pinboard {
        let pinboard = Pinboard(name: name)
        pinboards.append(pinboard)
        scheduleSave(items: false, pinboards: true)
        return pinboard
    }

    func renamePinboard(_ id: UUID, to name: String) {
        guard let index = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[index].name = name
        scheduleSave(items: false, pinboards: true)
    }

    func setPinboardColor(_ id: UUID, colorHex: String?) {
        guard let index = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[index].colorHex = colorHex
        scheduleSave(items: false, pinboards: true)
    }

    func removePinboard(_ id: UUID) {
        pinboards.removeAll { $0.id == id }
        scheduleSave(items: false, pinboards: true)
    }

    /// 根据 CloseTicketTagger 配置同步「归因类型」集合。
    /// 配置文件必须存在才会创建/刷新集合；文件缺失时不执行任何操作。
    func syncAttributionPinboard(with config: CloseTicketTagConfig?) {
        guard let config else { return }
        let name = CloseTicketTagger.pinboardName
        let tagItems = config.tags.map { tag in
            ClipboardItem(id: UUID(), kind: .text, text: tag,
                          imageFile: nil, fileSize: nil,
                          createdAt: Date(), sourceBundleID: nil,
                          prefix: config.prefix, suffix: config.suffix)
        }
        if let index = pinboards.firstIndex(where: { $0.name == name }) {
            pinboards[index].items = tagItems
        } else {
            let palette = Pinboard.colorPalette
            let used = Set(pinboards.compactMap(\.colorHex))
            let color = palette.first { !used.contains($0.hex) }?.hex
                ?? palette[pinboards.count % palette.count].hex
            var pinboard = Pinboard(name: name, colorHex: color)
            pinboard.items = tagItems
            pinboards.append(pinboard)
        }
        scheduleSave(items: false, pinboards: true)
    }

    /// 拖拽排序：把 draggedID 移动到 targetID 的位置
    func movePinboard(draggedID: UUID, onto targetID: UUID) {
        guard let from = pinboards.firstIndex(where: { $0.id == draggedID }),
              let to = pinboards.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        let board = pinboards.remove(at: from)
        pinboards.insert(board, at: to)
        scheduleSave(items: false, pinboards: true)
    }

    func addToPinboard(_ item: ClipboardItem, pinboardID: UUID) {
        guard let index = pinboards.firstIndex(where: { $0.id == pinboardID }) else { return }
        // 集合内去重：文本/文件直接比较，图片比较文件名（因为复制到集合后会生成新文件）
        let isDuplicate: Bool
        switch item.kind {
        case .text, .color, .file:
            isDuplicate = pinboards[index].items.contains { $0.text == item.text && $0.kind == item.kind }
        case .image:
            isDuplicate = pinboards[index].items.contains { $0.id == item.id }
        }
        if isDuplicate { return }
        // 图片条目钉入集合时复制一份图片文件，避免历史清理把集合里的图删掉
        var pinned = item
        if item.kind == .image, let fileName = item.imageFile,
           let data = Self.loadImageData(fileName: fileName, imagesDir: imagesDir),
           let encrypted = CryptoService.encrypt(data) {
            let newFileName = UUID().uuidString + ".png"
            if let _ = try? encrypted.write(to: imagesDir.appendingPathComponent(newFileName), options: .atomic) {
                pinned = ClipboardItem(id: item.id, kind: item.kind, text: item.text,
                                       imageFile: newFileName, fileSize: item.fileSize,
                                       createdAt: item.createdAt,
                                       sourceBundleID: item.sourceBundleID)
                imageHashCache[newFileName] = data.prefix(4096).withUnsafeBytes { Data($0) }
            }
        }
        pinboards[index].items.removeAll { $0.id == pinned.id }
        pinboards[index].items.insert(pinned, at: 0)
        // 移动语义：从历史中移除。图片已在上方复制了独立文件（复制失败时沿用原文件，则不删除）
        if let historyIndex = items.firstIndex(where: { $0.id == item.id }) {
            if items[historyIndex].imageFile != pinned.imageFile {
                deleteImageFile(of: items[historyIndex])
                if let file = items[historyIndex].imageFile { imageHashCache.removeValue(forKey: file) }
            }
            items.remove(at: historyIndex)
        }
        scheduleSave()
    }

    func removeFromPinboard(_ itemID: UUID, pinboardID: UUID) {
        guard let index = pinboards.firstIndex(where: { $0.id == pinboardID }) else { return }
        if let item = pinboards[index].items.first(where: { $0.id == itemID }) {
            deleteImageFile(of: item)
            if let file = item.imageFile { imageHashCache.removeValue(forKey: file) }
        }
        pinboards[index].items.removeAll { $0.id == itemID }
        scheduleSave(items: false, pinboards: true)
    }

    func pinboard(_ id: UUID) -> Pinboard? {
        pinboards.first { $0.id == id }
    }

    // MARK: - 同步引擎使用的整体替换/合并入口

    /// 用合并后的数据整体替换本地状态（由 SyncController 调用）
    func replaceAll(items newItems: [ClipboardItem], pinboards newPinboards: [Pinboard]) {
        items = newItems
        pinboards = newPinboards
        imageHashCache.removeAll()
        itemsDirty = true
        pinboardsDirty = true
        save()
    }

    // MARK: - 图片

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let file = item.imageFile else { return nil }
        return imagesDir.appendingPathComponent(file)
    }

    func imageData(for item: ClipboardItem) -> Data? {
        guard let file = item.imageFile else { return nil }
        return Self.loadImageData(fileName: file, imagesDir: imagesDir)
    }

    nonisolated static func loadImageData(fileName: String, imagesDir: URL) -> Data? {
        let url = imagesDir.appendingPathComponent(fileName)
        guard let raw = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return CryptoService.decrypt(raw) ?? raw
    }

    /// 同步用：本地图片目录
    var imagesDirectory: URL { imagesDir }

    static func isHexColor(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("#"), t.count == 7 || t.count == 4 else { return false }
        return t.dropFirst().allSatisfy { $0.isHexDigit }
    }

    // MARK: - 私有

    private func deleteImageFile(of item: ClipboardItem) {
        guard let file = item.imageFile else { return }
        try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(file))
    }

    private func trim() {
        if items.count > maxItems {
            let removed = items[maxItems...]
            removed.forEach(deleteImageFile)
            items = Array(items.prefix(maxItems))
        }
    }

    private func save() {
        // 读取并清空脏标记：只写发生变化的表
        let saveItems = itemsDirty
        let savePinboards = pinboardsDirty
        itemsDirty = false
        pinboardsDirty = false
        guard saveItems || savePinboards else { return }

        let itemsSnapshot = items
        let pinboardsSnapshot = pinboards
        let db = self.db
        let onSaved = self.onSaved
        saveQueue.async {
            if saveItems {
                db?.syncItems(itemsSnapshot)
            }
            if savePinboards {
                db?.replacePinboards(pinboardsSnapshot)
            }
            if let onSaved {
                Task { @MainActor in onSaved() }
            }
        }
    }

    /// 首次启动时把旧版加密 JSON 迁移进 SQLite；迁移后把旧文件改名保留（可回收，不删除）。
    private func migrateLegacyJSONIfNeeded() {
        guard let db else { return }
        let fm = FileManager.default
        let hasLegacy = fm.fileExists(atPath: legacyHistoryFile.path)
            || fm.fileExists(atPath: legacyPinboardsFile.path)
        // 数据库里已有数据说明迁移过（或本就是新库），不重复迁移
        guard hasLegacy, db.loadItems().isEmpty, db.loadPinboards().isEmpty else { return }

        if let raw = try? Data(contentsOf: legacyHistoryFile) {
            let data = CryptoService.decrypt(raw) ?? raw
            if let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) {
                db.syncItems(decoded)
            }
        }
        if let raw = try? Data(contentsOf: legacyPinboardsFile) {
            let data = CryptoService.decrypt(raw) ?? raw
            if let decoded = try? JSONDecoder().decode([Pinboard].self, from: data) {
                db.replacePinboards(decoded)
            }
        }
        // 迁移完成后重命名旧文件（保留副本以便回退），失败则忽略
        try? fm.moveItem(at: legacyHistoryFile, to: legacyHistoryFile.appendingPathExtension("migrated"))
        try? fm.moveItem(at: legacyPinboardsFile, to: legacyPinboardsFile.appendingPathExtension("migrated"))
    }

    private func load() {
        guard let db else { return }
        items = db.loadItems()
        pinboards = db.loadPinboards()
    }

    /// 防抖保存：400ms 内的多次修改合并为一次写入，在后台队列执行 IO。
    /// items / pinboards 标记哪部分发生了变化，只有脏的表才会被重新编码加密写盘。
    private func scheduleSave(items: Bool = true, pinboards: Bool = true) {
        itemsDirty = itemsDirty || items
        pinboardsDirty = pinboardsDirty || pinboards
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.save()
        }
        saveWorkItem = workItem
        saveQueue.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    /// 后台线程查找损坏条目（图片/文件不存在），返回 ID 集合。
    /// 基于内存快照检查，不再读盘，避免与 SQLite 写入竞争。
    nonisolated private static func findBrokenItemIDs(items: [ClipboardItem], pinboards: [Pinboard], imagesDir: URL) -> Set<UUID> {
        let fm = FileManager.default
        var brokenIDs = Set<UUID>()

        func check(_ item: ClipboardItem) {
            switch item.kind {
            case .image:
                guard let file = item.imageFile else {
                    brokenIDs.insert(item.id)
                    return
                }
                if !fm.fileExists(atPath: imagesDir.appendingPathComponent(file).path) {
                    brokenIDs.insert(item.id)
                }
            case .file:
                guard let path = item.text else {
                    brokenIDs.insert(item.id)
                    return
                }
                if !fm.fileExists(atPath: path) {
                    brokenIDs.insert(item.id)
                }
            default:
                break
            }
        }

        items.forEach(check)
        pinboards.flatMap(\.items).forEach(check)
        return brokenIDs
    }

    /// 主线程删除损坏条目
    private func removeBrokenItems(ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        for index in pinboards.indices {
            pinboards[index].items.removeAll { ids.contains($0.id) }
        }
        ids.forEach { id in
            if let item = items.first(where: { $0.id == id }),
               let file = item.imageFile {
                imageHashCache.removeValue(forKey: file)
            }
        }
        scheduleSave()
    }
}
