import AppKit

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var pinboards: [Pinboard] = []

    private let maxItems = 500
    private let baseDir: URL
    private let imagesDir: URL
    private var historyFile: URL { baseDir.appendingPathComponent("history.json") }
    private var pinboardsFile: URL { baseDir.appendingPathComponent("pinboards.json") }

    /// 每次本地保存后回调（同步引擎借此把变更写到同步目录）
    var onSaved: (() -> Void)?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir = appSupport.appendingPathComponent("ClipVault", isDirectory: true)
        imagesDir = baseDir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        // 数据目录仅当前用户可访问
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)
        load()
    }

    // MARK: - 历史

    @discardableResult
    func addText(_ text: String, sourceBundleID: String?) -> ClipboardItem {
        if let dup = items.firstIndex(where: { $0.kind != .image && $0.text == text }) {
            items.remove(at: dup)
        }
        let kind: ClipboardItem.Kind = Self.isHexColor(text) ? .color : .text
        let item = ClipboardItem(id: UUID(), kind: kind, text: text, imageFile: nil,
                                 fileSize: nil, createdAt: Date(), sourceBundleID: sourceBundleID)
        items.insert(item, at: 0)
        trim()
        save()
        return item
    }

    func updateText(id: UUID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].kind = Self.isHexColor(text) ? .color : .text
        items[index].text = text
        save()
    }

    func updatePinboardText(pinboardID: UUID, itemID: UUID, text: String) {
        guard let boardIndex = pinboards.firstIndex(where: { $0.id == pinboardID }),
              let itemIndex = pinboards[boardIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
        pinboards[boardIndex].items[itemIndex].kind = Self.isHexColor(text) ? .color : .text
        pinboards[boardIndex].items[itemIndex].text = text
        save()
    }

    @discardableResult
    func addImage(_ pngData: Data, sourceBundleID: String?) -> ClipboardItem? {
        // 去重：历史里已有相同图片数据时，只更新时间和来源，不新增条目
        if let dupIndex = items.firstIndex(where: { $0.kind == .image && imageData(for: $0) == pngData }) {
            items[dupIndex].createdAt = Date()
            items[dupIndex].sourceBundleID = sourceBundleID
            let dup = items.remove(at: dupIndex)
            items.insert(dup, at: 0)
            save()
            return dup
        }
        guard let encrypted = CryptoService.encrypt(pngData) else { return nil }
        let fileName = UUID().uuidString + ".png"
        do {
            try encrypted.write(to: imagesDir.appendingPathComponent(fileName), options: .atomic)
        } catch {
            return nil
        }
        let item = ClipboardItem(id: UUID(), kind: .image, text: nil, imageFile: fileName,
                                 fileSize: nil, createdAt: Date(), sourceBundleID: sourceBundleID)
        items.insert(item, at: 0)
        trim()
        save()
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
        if let dup = items.firstIndex(where: { $0.kind == .file && $0.text == path }) {
            items.remove(at: dup)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let item = ClipboardItem(id: UUID(), kind: .file, text: path,
                                 imageFile: nil, fileSize: size > 0 ? size : nil,
                                 createdAt: Date(), sourceBundleID: sourceBundleID)
        items.insert(item, at: 0)
        trim()
        save()
        return item
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        deleteImageFile(of: item)
        save()
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
        try? FileManager.default.removeItem(at: imagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        save()
    }

    /// 保留策略：删除超过 days 天的历史条目（0 = 永久保留）。不影响集合。
    func prune(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let expired = items.filter { $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        expired.forEach(deleteImageFile)
        items.removeAll { $0.createdAt < cutoff }
        save()
    }

    // MARK: - 集合

    @discardableResult
    func addPinboard(name: String) -> Pinboard {
        let pinboard = Pinboard(name: name)
        pinboards.append(pinboard)
        save()
        return pinboard
    }

    func renamePinboard(_ id: UUID, to name: String) {
        guard let index = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[index].name = name
        save()
    }

    func setPinboardColor(_ id: UUID, colorHex: String?) {
        guard let index = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[index].colorHex = colorHex
        save()
    }

    func removePinboard(_ id: UUID) {
        pinboards.removeAll { $0.id == id }
        save()
    }

    /// 根据 CloseTicketTagger 配置同步「归因类型」集合。
    /// 集合不存在时新建；配置文件缺失时保留空集合，避免显示过期内容。
    func syncAttributionPinboard(with config: CloseTicketTagConfig?) {
        let name = CloseTicketTagger.pinboardName
        let tagItems: [ClipboardItem]
        if let config {
            tagItems = config.tags.map { tag in
                ClipboardItem(id: UUID(), kind: .text, text: tag,
                              imageFile: nil, fileSize: nil,
                              createdAt: Date(), sourceBundleID: nil,
                              prefix: config.prefix, suffix: config.suffix)
            }
        } else {
            tagItems = []
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
        save()
    }

    /// 拖拽排序：把 draggedID 移动到 targetID 的位置
    func movePinboard(draggedID: UUID, onto targetID: UUID) {
        guard let from = pinboards.firstIndex(where: { $0.id == draggedID }),
              let to = pinboards.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        let board = pinboards.remove(at: from)
        pinboards.insert(board, at: to)
        save()
    }

    func addToPinboard(_ item: ClipboardItem, pinboardID: UUID) {
        guard let index = pinboards.firstIndex(where: { $0.id == pinboardID }) else { return }
        // 去重：相同内容在集合内只保留一份
        if pinboards[index].items.contains(where: { isContentEqual($0, item) }) {
            return
        }
        // 图片条目钉入集合时复制一份图片文件，避免历史清理把集合里的图删掉
        var pinned = item
        if item.kind == .image, let data = imageData(for: item),
           let encrypted = CryptoService.encrypt(data) {
            let fileName = UUID().uuidString + ".png"
            if let _ = try? encrypted.write(to: imagesDir.appendingPathComponent(fileName), options: .atomic) {
                pinned = ClipboardItem(id: item.id, kind: item.kind, text: item.text,
                                       imageFile: fileName, fileSize: item.fileSize,
                                       createdAt: item.createdAt,
                                       sourceBundleID: item.sourceBundleID)
            }
        }
        pinboards[index].items.removeAll { $0.id == pinned.id }
        pinboards[index].items.insert(pinned, at: 0)
        // 移动语义：从历史中移除。图片已在上方复制了独立文件（复制失败时沿用原文件，则不删除）
        if let historyIndex = items.firstIndex(where: { $0.id == item.id }) {
            if items[historyIndex].imageFile != pinned.imageFile {
                deleteImageFile(of: items[historyIndex])
            }
            items.remove(at: historyIndex)
        }
        save()
    }

    /// 判断两条剪贴板条目内容是否相同（用于集合内去重）
    private func isContentEqual(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        switch lhs.kind {
        case .text, .color:
            return lhs.text == rhs.text
        case .file:
            return lhs.text == rhs.text
        case .image:
            guard let lhsData = imageData(for: lhs),
                  let rhsData = imageData(for: rhs) else { return false }
            return lhsData == rhsData
        }
    }

    func removeFromPinboard(_ itemID: UUID, pinboardID: UUID) {
        guard let index = pinboards.firstIndex(where: { $0.id == pinboardID }) else { return }
        if let item = pinboards[index].items.first(where: { $0.id == itemID }) {
            deleteImageFile(of: item)
        }
        pinboards[index].items.removeAll { $0.id == itemID }
        save()
    }

    func pinboard(_ id: UUID) -> Pinboard? {
        pinboards.first { $0.id == id }
    }

    // MARK: - 同步引擎使用的整体替换/合并入口

    /// 用合并后的数据整体替换本地状态（由 SyncController 调用）
    func replaceAll(items newItems: [ClipboardItem], pinboards newPinboards: [Pinboard]) {
        items = newItems
        pinboards = newPinboards
        save()
    }

    // MARK: - 图片

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let file = item.imageFile else { return nil }
        return imagesDir.appendingPathComponent(file)
    }

    func imageData(for item: ClipboardItem) -> Data? {
        guard let url = imageURL(for: item),
              let raw = try? Data(contentsOf: url) else { return nil }
        // 加密存储；解密失败时按明文处理（迁移前的旧文件）
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
        if let data = try? JSONEncoder().encode(items) {
            writeEncrypted(data, to: historyFile)
        }
        if let data = try? JSONEncoder().encode(pinboards) {
            writeEncrypted(data, to: pinboardsFile)
        }
        onSaved?()
    }

    private func writeEncrypted(_ data: Data, to url: URL) {
        guard let encrypted = CryptoService.encrypt(data) else { return }
        try? encrypted.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 读取并解密；解密失败按明文返回（用于从加密前的旧数据迁移）
    private func loadFile(_ url: URL) -> (data: Data, wasEncrypted: Bool)? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        if let decrypted = CryptoService.decrypt(raw) {
            return (decrypted, true)
        }
        return (raw, false)
    }

    private func load() {
        var needsResave = false
        if let file = loadFile(historyFile),
           let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: file.data) {
            items = decoded
            if !file.wasEncrypted { needsResave = true }
        }
        if let file = loadFile(pinboardsFile),
           let decoded = try? JSONDecoder().decode([Pinboard].self, from: file.data) {
            pinboards = decoded
            if !file.wasEncrypted { needsResave = true }
        }
        // 迁移：检测到明文旧数据，立刻以加密形式重写
        if needsResave { save() }
        pruneBrokenImages()
    }

    /// 清理图片文件已丢失的条目（不再展示"图片不可用"）
    private func pruneBrokenImages() {
        let fm = FileManager.default
        func isBroken(_ item: ClipboardItem) -> Bool {
            guard item.kind == .image else { return false }
            guard let file = item.imageFile else { return true }
            return !fm.fileExists(atPath: imagesDir.appendingPathComponent(file).path)
        }
        let before = items.count + pinboards.flatMap(\.items).count
        items.removeAll(where: isBroken)
        for index in pinboards.indices {
            pinboards[index].items.removeAll(where: isBroken)
        }
        if before != items.count + pinboards.flatMap(\.items).count {
            save()
        }
    }
}
