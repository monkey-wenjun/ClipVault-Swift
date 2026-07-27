import AppKit

/// 通过同步目录（默认 iCloud Drive 下的 ClipVault 文件夹）镜像历史与集合。
/// 合并策略：按条目 id 求并集，新旧的顺序按创建时间排序；删除操作不传播。
@MainActor
final class SyncController: ObservableObject {
    enum Status: Equatable {
        case idle
        case syncing
        case succeeded(Date)
        case failed(String)
    }

    enum SyncError: LocalizedError {
        case invalidData(String)

        var errorDescription: String? {
            switch self {
            case .invalidData(let file):
                return String(format: NSLocalizedString("无法解析同步文件：%@", comment: "Sync error: invalid data"), file)
            }
        }
    }

    private let store: HistoryStore
    private let settings: AppSettings
    private var timer: Timer?
    private var pendingWrite: DispatchWorkItem?

    @Published private(set) var status: Status = .idle

    init(store: HistoryStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        store.onSaved = { [weak self] in self?.scheduleWriteRemote() }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncCycle() }
        }
        syncCycle()
    }

    // MARK: - 同步周期：远端 → 本地合并 → 回写远端

    func syncCycle() {
        guard let dir = syncDir() else {
            status = .idle
            return
        }

        let accessing = dir.startAccessingSecurityScopedResource()
        defer { if accessing { dir.stopAccessingSecurityScopedResource() } }

        status = .syncing
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)

            let remoteItems = try read([ClipboardItem].self, from: dir.appendingPathComponent("history.json")) ?? []
            let remotePinboards = try read([Pinboard].self, from: dir.appendingPathComponent("pinboards.json")) ?? []

            let mergedItems = mergeItems(local: store.items, remote: remoteItems)
            let mergedPinboards = mergePinboards(local: store.pinboards, remote: remotePinboards)

            try syncImages(in: dir, items: mergedItems, pinboards: mergedPinboards)

            if mergedItems != store.items || mergedPinboards != store.pinboards {
                store.replaceAll(items: mergedItems, pinboards: mergedPinboards)
            }
            try writeRemote(items: mergedItems, pinboards: mergedPinboards, to: dir)
            status = .succeeded(Date())
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - 本地保存后延迟回写远端

    private func scheduleWriteRemote() {
        guard settings.syncEnabled else { return }
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let dir = self.syncDir() else { return }
                let accessing = dir.startAccessingSecurityScopedResource()
                defer { if accessing { dir.stopAccessingSecurityScopedResource() } }
                do {
                    try self.writeRemote(items: self.store.items, pinboards: self.store.pinboards, to: dir)
                    self.status = .succeeded(Date())
                } catch {
                    self.status = .failed(error.localizedDescription)
                }
            }
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - 合并

    private func mergeItems(local: [ClipboardItem], remote: [ClipboardItem]) -> [ClipboardItem] {
        var seen = Set<UUID>()
        var merged: [ClipboardItem] = []
        for item in (local + remote).sorted(by: { $0.createdAt > $1.createdAt }) {
            if seen.insert(item.id).inserted {
                merged.append(item)
            }
        }
        return Array(merged.prefix(500))
    }

    private func mergePinboards(local: [Pinboard], remote: [Pinboard]) -> [Pinboard] {
        var merged = local
        for remoteBoard in remote {
            if let index = merged.firstIndex(where: { $0.id == remoteBoard.id }) {
                var items = merged[index].items
                let existing = Set(items.map(\.id))
                items.append(contentsOf: remoteBoard.items.filter { !existing.contains($0.id) })
                merged[index].items = items
            } else {
                merged.append(remoteBoard)
            }
        }
        return merged
    }

    // MARK: - 图片双向拷贝

    private func syncImages(in dir: URL, items: [ClipboardItem], pinboards: [Pinboard]) throws {
        let fm = FileManager.default
        let localImages = store.imagesDirectory
        let remoteImages = dir.appendingPathComponent("images")

        var referenced = Set<String>()
        for item in items + pinboards.flatMap(\.items) {
            if let file = item.imageFile { referenced.insert(file) }
        }

        for file in referenced {
            let local = localImages.appendingPathComponent(file)
            let remote = remoteImages.appendingPathComponent(file)
            if fm.fileExists(atPath: local.path), !fm.fileExists(atPath: remote.path) {
                try fm.copyItem(at: local, to: remote)
            } else if !fm.fileExists(atPath: local.path), fm.fileExists(atPath: remote.path) {
                try fm.copyItem(at: remote, to: local)
            }
        }
    }

    // MARK: - 读写

    private func syncDir() -> URL? {
        guard settings.syncEnabled, !settings.syncFolderPath.isEmpty else { return nil }

        // 优先使用安全作用域书签（沙盒下访问用户所选目录必需）
        if let bookmark = settings.syncFolderBookmark {
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: bookmark,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale)
                return url
            } catch {
                // 书签损坏时回退到路径（容器内默认目录仍可访问）
            }
        }
        return URL(fileURLWithPath: settings.syncFolderPath)
    }

    private func writeRemote(items: [ClipboardItem], pinboards: [Pinboard], to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items),
           let encrypted = CryptoService.encrypt(data) {
            try encrypted.write(to: dir.appendingPathComponent("history.json"), options: .atomic)
        }
        if let data = try? JSONEncoder().encode(pinboards),
           let encrypted = CryptoService.encrypt(data) {
            try encrypted.write(to: dir.appendingPathComponent("pinboards.json"), options: .atomic)
        }
        try syncImages(in: dir, items: items, pinboards: pinboards)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let raw = try Data(contentsOf: url)
        // 解密失败按明文处理（迁移前的旧同步文件）
        let data = CryptoService.decrypt(raw) ?? raw
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SyncError.invalidData(url.lastPathComponent)
        }
    }
}
