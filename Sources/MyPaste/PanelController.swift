import AppKit
import SwiftUI
import Combine

@MainActor
final class PanelViewModel: ObservableObject {
    /// 搜索范围：默认全部（历史 + 所有标签）
    enum SearchScope: Hashable {
        case all
        case history
        case pinboard(UUID)

        var persisted: String {
            switch self {
            case .all: return "all"
            case .history: return "history"
            case .pinboard(let id): return id.uuidString
            }
        }

        init?(persisted: String) {
            switch persisted {
            case "all": self = .all
            case "history": self = .history
            default:
                guard let id = UUID(uuidString: persisted) else { return nil }
                self = .pinboard(id)
            }
        }
    }

    @Published var search = "" {
        didSet {
            if !suppressSearchSelectionReset {
                selectedIndex = -1
                markedIDs = []
            }
        }
    }
    /// 搜索框失焦自动清空搜索词时，不重置当前已选中的卡片（避免点击卡片时被同步清空）
    var suppressSearchSelectionReset = false
    /// 搜索框是否展开（快捷键可控制）
    @Published var searchExpanded = false
    @Published var selectedIndex = -1
    /// 单击/⌃A 标记的多选集合（Delete 删除这些；为空时删除键盘选中项）
    @Published var markedIDs: Set<UUID> = []
    /// nil 表示当前未选中任何集合 tab
    @Published var selectedTab: UUID? = nil {
        didSet {
            selectedIndex = -1
            markedIDs = []
        }
    }
    /// 是否选中了“剪贴板”tab。默认 true，初始状态高亮“剪贴板”。
    @Published var selectedHistoryTab = true {
        didSet {
            selectedIndex = -1
            markedIDs = []
            if selectedHistoryTab {
                selectedTab = nil
            }
        }
    }
    /// 面板当前尺寸（由 PanelController 在显示/拖拽时更新，驱动卡片缩放）
    @Published var panelSize: CGSize = .zero
    /// 记住上次选择的搜索范围（UserDefaults 持久化）
    @Published var searchScope: SearchScope = .all {
        didSet {
            selectedIndex = -1
            UserDefaults.standard.set(searchScope.persisted, forKey: "searchScope")
        }
    }
    /// 内容类型筛选
    @Published var typeFilter: ContentType? = nil {
        didSet { selectedIndex = -1 }
    }
    /// 来源应用筛选（bundleID）
    @Published var appFilter: String? = nil {
        didSet { selectedIndex = -1 }
    }
    /// 筛选气泡锚点视图与开关回调（由 PanelView / PanelController 设置）
    weak var filterAnchor: NSView?
    var filterPopoverHandler: (() -> Void)?
    /// 筛选气泡展示期间暂时抑制“失焦即折叠搜索框”
    var suppressFocusLoss = false
    /// 递增令牌：请求 PanelView 把焦点还给搜索框
    @Published var focusSearchToken = 0
    /// 递增令牌：请求 PanelView 把焦点从搜索框移走（按 Tab 切换到结果卡片）
    @Published var blurSearchToken = 0

    /// 内容类型
    enum ContentType: String, CaseIterable, Identifiable {
        case text
        case link
        case color
        case image
        case file

        var id: String { rawValue }

        var title: String {
            switch self {
            case .text: return NSLocalizedString("文本", comment: "Content type: Text")
            case .link: return NSLocalizedString("链接", comment: "Content type: Link")
            case .color: return NSLocalizedString("颜色", comment: "Content type: Color")
            case .image: return NSLocalizedString("图片", comment: "Content type: Image")
            case .file: return NSLocalizedString("文件", comment: "Content type: File")
            }
        }

        var icon: String {
            switch self {
            case .text: return "text.alignleft"
            case .link: return "link"
            case .color: return "paintpalette"
            case .image: return "photo"
            case .file: return "doc"
            }
        }
    }

    /// 是否有任何筛选生效（用于筛选按钮高亮）
    var hasActiveFilter: Bool {
        searchScope != .all || typeFilter != nil || appFilter != nil
    }

    /// 历史与所有集合中出现过的来源应用（首次出现顺序）
    var availableApps: [(bundleID: String, name: String)] {
        var seen = Set<String>()
        var apps: [(String, String)] = []
        for item in store.items + store.pinboards.flatMap(\.items) {
            guard let bundleID = item.sourceBundleID, seen.insert(bundleID).inserted else { continue }
            apps.append((bundleID, Self.appName(for: bundleID)))
        }
        return apps
    }

    private static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return url.deletingPathExtension().lastPathComponent
    }

    /// 内联重命名标签状态
    @Published var renamingTagID: UUID?
    @Published var renamingName = ""
    /// 内联重命名卡片标题状态
    @Published var editingCardTitleID: UUID? = nil
    @Published var editingCardTitle: String = ""
    /// 搜索框或标签输入框持有焦点时，键盘监控放行编辑按键（Delete/方向键/Return 等）
    var textEditing = false
    /// 搜索框是否持有焦点（用于 Esc 优先取消搜索）
    var searchFocused = false

    /// 正在内联编辑标签名
    var editingTagName: Bool { renamingTagID != nil }

    let store: HistoryStore
    var pasteHandler: ((ClipboardItem) -> Void)?
    var jsonViewerHandler: ((ClipboardItem) -> Void)?
    var jsonViewerToggleHandler: (() -> Bool)?
    var textPreviewHandler: ((ClipboardItem) -> Void)?
    var textPreviewToggleHandler: (() -> Bool)?
    var imagePreviewHandler: ((ClipboardItem) -> Void)?
    var imagePreviewToggleHandler: (() -> Bool)?
    /// 上传指定条目到默认图床（由 AppDelegate 设置）
    var uploadToImageHostingHandler: ((ClipboardItem) -> Void)?
    /// 面板右上 ··· 按钮的回调（由 PanelController 设置）
    var moreMenuHandler: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()

    /// 预计算的过滤结果：只在搜索词/选中标签/数据变化时重算，而不是每次渲染都算
    @Published private(set) var filtered: [ClipboardItem] = []
    /// 全局搜索时，条目 id → 所属集合（用于在卡片上标注标签）
    @Published private(set) var searchTagMap: [UUID: Pinboard] = [:]
    /// 分批加载窗口：先渲染前 N 条，滚动到底再追加
    @Published private(set) var visibleCount = 30

    init(store: HistoryStore) {
        self.store = store
        // 恢复上次选择的搜索范围（指向的标签已删除时按空结果处理，不崩溃）
        if let saved = UserDefaults.standard.string(forKey: "searchScope"),
           let scope = SearchScope(persisted: saved) {
            searchScope = scope
        }
        store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        // 搜索词去抖 150ms：连续打字不触发中间计算；清空时立即生效
        let debouncedSearch = $search
            .map { query -> AnyPublisher<String, Never> in
                if query.isEmpty {
                    return Just(query).eraseToAnyPublisher()
                }
                return Just(query)
                    .delay(for: .milliseconds(150), scheduler: DispatchQueue.main)
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
        let filters = Publishers.CombineLatest3($searchScope, $typeFilter, $appFilter)
        Publishers.CombineLatest4(debouncedSearch, $selectedTab, $selectedHistoryTab, store.$items)
            .combineLatest(filters)
            .combineLatest(store.$pinboards)
            .map { combined, pinboards in
                let (input, filter) = combined
                let (search, tab, historyTabSelected, items) = input
                let (scope, type, app) = filter
                return Self.computeFiltered(search: search, tab: tab, historyTabSelected: historyTabSelected, scope: scope,
                                            type: type, app: app,
                                            items: items, pinboards: pinboards)
            }
            .sink { [weak self] filtered, tagMap in
                self?.filtered = filtered
                self?.searchTagMap = tagMap
                self?.visibleCount = 30
            }
            .store(in: &cancellables)
    }

    var pinboards: [Pinboard] { store.pinboards }

    /// 滚动到底部时追加一批
    func loadMore() {
        visibleCount = min(visibleCount + 30, filtered.count)
    }

    private static func computeFiltered(search: String, tab: UUID?, historyTabSelected: Bool, scope: SearchScope,
                                        type: ContentType?, app: String?,
                                        items: [ClipboardItem],
                                        pinboards: [Pinboard]) -> ([ClipboardItem], [UUID: Pinboard]) {
        let query = search.trimmingCharacters(in: .whitespaces)
        let hasFilter = scope != .all || type != nil || app != nil

        // 无搜索词且无筛选：未选中 / 选中“剪贴板”时都显示全部历史，但只有显式点击时才高亮 tab
        if query.isEmpty && !hasFilter {
            let base: [ClipboardItem]
            if let tab {
                base = pinboards.first { $0.id == tab }?.items ?? []
            } else {
                base = items
            }
            return (base, [:])
        }

        // 候选池：由范围决定；.all 时历史 + 所有集合按 id 去重
        var seen = Set<UUID>()
        var pool: [(item: ClipboardItem, board: Pinboard?)] = []
        func append(_ item: ClipboardItem, _ board: Pinboard?) {
            if seen.insert(item.id).inserted { pool.append((item, board)) }
        }
        switch scope {
        case .all:
            items.forEach { append($0, nil) }
            for board in pinboards {
                board.items.forEach { append($0, board) }
            }
        case .history:
            items.forEach { append($0, nil) }
        case .pinboard(let id):
            (pinboards.first { $0.id == id }?.items ?? []).forEach { append($0, nil) }
        }

        let loweredQuery = query.lowercased()
        var tagMap: [UUID: Pinboard] = [:]
        let result = pool.filter { entry in
            let item = entry.item
            if let type, !matchesType(item, type) { return false }
            if let app, item.sourceBundleID != app { return false }
            if !loweredQuery.isEmpty,
               !SearchTextCache.lowercaseText(for: item).contains(loweredQuery) { return false }
            if let board = entry.board { tagMap[item.id] = board }
            return true
        }.map(\.item)
        return (result, tagMap)
    }

    private static func matchesType(_ item: ClipboardItem, _ type: ContentType) -> Bool {
        switch type {
        case .text: return item.kind == .text && !isLink(item)
        case .link: return item.kind == .text && isLink(item)
        case .color: return item.kind == .color
        case .image: return item.kind == .image
        case .file: return item.kind == .file
        }
    }

    private static func isLink(_ item: ClipboardItem) -> Bool {
        let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("http://") || text.hasPrefix("https://")
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        store.imageURL(for: item)
    }

    /// 卡片图片：解密 + 内存缓存
    func cardImage(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        if let cached = CardImageCache.image(forID: item.id) { return cached }
        guard let data = store.imageData(for: item),
              let image = NSImage(data: data) else { return nil }
        CardImageCache.set(image, forID: item.id)
        return image
    }

    /// 用于拖拽到 Finder/其他目录的文件 URL
    func fileURLForDrag(for item: ClipboardItem) -> URL? {
        switch item.kind {
        case .file:
            guard let path = item.text else { return nil }
            return URL(fileURLWithPath: path)
        case .image:
            guard let data = store.imageData(for: item),
                  let fileName = item.imageFile else { return nil }
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipVaultDrag", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempFile = tempDir.appendingPathComponent(fileName)
            try? data.write(to: tempFile, options: .atomic)
            return tempFile
        default:
            return nil
        }
    }

    /// 返回适合拖放到不同目标（编辑器/Finder）的 NSItemProvider
    func dragItemProvider(for item: ClipboardItem) -> NSItemProvider {
        switch item.kind {
        case .text, .color:
            // 文本/颜色拖到编辑器里直接插入文本内容
            let text = item.pasteContent
            return NSItemProvider(object: text as NSString)
        case .file:
            guard let path = item.text else { return NSItemProvider() }
            return NSItemProvider(object: URL(fileURLWithPath: path) as NSURL)
        case .image:
            guard let url = fileURLForDrag(for: item) else { return NSItemProvider() }
            return NSItemProvider(object: url as NSURL)
        }
    }

    /// 无来源应用条目的头带底色：跟随所在标签颜色，否则主题蓝
    func fallbackBandColor(for item: ClipboardItem) -> Color {
        let board = selectedTab.flatMap { store.pinboard($0) } ?? searchTagMap[item.id]
        if let hex = board?.colorHex, let color = Color(hex: hex) {
            return color
        }
        return .accentColor
    }

    // MARK: - 粘贴

    func paste(_ item: ClipboardItem) {
        pasteHandler?(item)
    }

    func pasteSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        paste(filtered[selectedIndex])
    }

    func previewSelectedImage() {
        if imagePreviewToggleHandler?() == true { return }
        guard filtered.indices.contains(selectedIndex) else { return }
        let item = filtered[selectedIndex]
        guard item.kind == .image else { return }
        imagePreviewHandler?(item)
    }

    func previewSelectedJSON() -> Bool {
        if jsonViewerToggleHandler?() == true { return true }
        guard filtered.indices.contains(selectedIndex) else { return false }
        let item = filtered[selectedIndex]
        guard item.isJSONText else { return false }
        jsonViewerHandler?(item)
        return true
    }

    func previewSelectedText() -> Bool {
        if textPreviewToggleHandler?() == true { return true }
        guard filtered.indices.contains(selectedIndex) else { return false }
        let item = filtered[selectedIndex]
        guard item.kind == .text else { return false }
        textPreviewHandler?(item)
        return true
    }

    /// 快速粘贴：⌘1...⌘9
    func pasteNumber(_ n: Int) {
        let index = n - 1
        guard filtered.indices.contains(index) else { return }
        paste(filtered[index])
    }

    func moveSelection(_ delta: Int) {
        let maxIndex = min(filtered.count, visibleCount) - 1
        guard maxIndex >= 0 else {
            selectedIndex = -1
            return
        }
        if selectedIndex < 0 {
            selectedIndex = delta > 0 ? 0 : maxIndex
            return
        }
        let count = maxIndex + 1
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    // MARK: - 集合切换

    func selectTabOffset(_ delta: Int) {
        // 键盘切换时不经过“未选中”状态，只在“剪贴板 + 各集合”之间切换。
        enum TabTarget: Equatable {
            case history
            case pinboard(UUID)
        }
        var tabs: [TabTarget] = [.history]
        tabs.append(contentsOf: pinboards.map { .pinboard($0.id) })

        let current: TabTarget
        if let selectedTab {
            current = .pinboard(selectedTab)
        } else {
            // 当前若为“未选中”，键盘切换从“剪贴板”开始。
            current = .history
        }

        let currentIndex = tabs.firstIndex(of: current) ?? 0
        let count = tabs.count
        let next = ((currentIndex + delta) % count + count) % count
        switch tabs[next] {
        case .history:
            selectedHistoryTab = true
            selectedTab = nil
        case .pinboard(let id):
            selectedHistoryTab = false
            selectedTab = id
        }
    }

    // MARK: - 删除

    func deleteSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        let item = filtered[selectedIndex]
        if let tab = selectedTab {
            store.removeFromPinboard(item.id, pinboardID: tab)
        } else {
            store.remove(item)
        }
    }

    // MARK: - 多选（单击标记 / ⌃A 全选）

    /// 单击卡片：标记为唯一选中项；再点已标记的卡片则取消标记
    func toggleMark(_ item: ClipboardItem) {
        if let index = filtered.firstIndex(where: { $0.id == item.id }) {
            selectedIndex = index
        }
        if markedIDs.contains(item.id) {
            markedIDs.remove(item.id)
        } else {
            markedIDs = [item.id]
        }
    }

    /// ⌃A：标记当前列表全部条目
    func markAll() {
        markedIDs = Set(filtered.map(\.id))
    }

    /// Delete：有标记时删除全部标记项，否则删除键盘选中项
    func deleteMarked() {
        guard !markedIDs.isEmpty else {
            deleteSelected()
            return
        }
        let ids = markedIDs
        markedIDs = []
        for item in filtered where ids.contains(item.id) {
            if let tab = selectedTab {
                store.removeFromPinboard(item.id, pinboardID: tab)
            } else {
                store.remove(item)
            }
        }
    }

    /// 右键删除：等同 Delete —— 右键项在标记集合中时删除全部标记项，否则只删它自己
    func deleteMarkedOrItem(_ item: ClipboardItem) {
        if markedIDs.contains(item.id) {
            deleteMarked()
        } else if let tab = selectedTab {
            store.removeFromPinboard(item.id, pinboardID: tab)
        } else {
            store.remove(item)
        }
    }

    /// 图片文件损坏/丢失的卡片：显示时立即从所有列表移除
    func handleBrokenImage(_ item: ClipboardItem) {
        DispatchQueue.main.async { [weak self] in
            self?.store.removeEverywhere(item.id)
        }
    }

    // MARK: - 集合操作

    /// 立即创建“未命名”集合，自动分配一个未被占用的标签颜色；item 非空时顺便移动进去
    @discardableResult
    func quickAddPinboard(with item: ClipboardItem? = nil) -> Pinboard {
        let palette = Pinboard.colorPalette
        let used = Set(store.pinboards.compactMap(\.colorHex))
        let color = palette.first { !used.contains($0.hex) }?.hex
            ?? palette[store.pinboards.count % palette.count].hex
        var pinboard = store.addPinboard(name: "未命名")
        store.setPinboardColor(pinboard.id, colorHex: color)
        pinboard.colorHex = color
        if let item {
            store.addToPinboard(item, pinboardID: pinboard.id)
        }
        selectedHistoryTab = false
        selectedTab = pinboard.id
        return pinboard
    }

    // MARK: - 重命名标签

    func startRenaming(_ pinboard: Pinboard) {
        renamingTagID = pinboard.id
        renamingName = pinboard.name
    }

    func commitRename() {
        let name = renamingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = renamingTagID, !name.isEmpty {
            store.renamePinboard(id, to: name)
        }
        cancelRenaming()
    }

    func cancelRenaming() {
        renamingTagID = nil
        renamingName = ""
    }

    // MARK: - 卡片标题重命名

    func beginCardTitleEdit(_ item: ClipboardItem) {
        editingCardTitleID = item.id
        editingCardTitle = item.customTitle ?? item.kind.title
    }

    func commitCardTitleEdit() {
        guard let id = editingCardTitleID else { return }
        store.setCustomTitle(editingCardTitle, forItemID: id)
        editingCardTitleID = nil
        editingCardTitle = ""
    }

    func cancelCardTitleEdit() {
        editingCardTitleID = nil
        editingCardTitle = ""
    }

    func addToPinboard(_ item: ClipboardItem, pinboardID: UUID) {
        store.addToPinboard(item, pinboardID: pinboardID)
    }

    /// 拖拽排序标签
    func movePinboard(draggedID: UUID, onto targetID: UUID) {
        store.movePinboard(draggedID: draggedID, onto: targetID)
    }

    func removeFromCurrentPinboard(_ item: ClipboardItem) {
        guard let tab = selectedTab else { return }
        store.removeFromPinboard(item.id, pinboardID: tab)
    }

    /// 拖拽文件到面板：图片转为图片条目，其他文件生成文件引用条目；
    /// 若当前选中了某个集合，则同时移入该集合。
    func handleDroppedFiles(_ urls: [URL]) {
        for url in urls {
            let item: ClipboardItem?
            if isImageFile(url) {
                item = store.addImage(fromFileURL: url, sourceBundleID: nil)
            } else {
                item = store.addFile(path: url.path, sourceBundleID: nil)
            }
            if let item, let tab = selectedTab {
                store.addToPinboard(item, pinboardID: tab)
            }
        }
    }

    private func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "tiff", "tif"].contains(ext)
    }

    func resetState() {
        search = ""
        searchExpanded = false
        selectedIndex = -1
        markedIDs = []
        cancelRenaming()
        selectedHistoryTab = true
        selectedTab = nil
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 托管 SwiftUI 面板的 NSHostingView，负责把传统鼠标竖向滚轮转成横向滚动。
/// 这比 `NSEvent.addLocalMonitorForEvents` 更可靠：直接在响应链里处理事件，
/// 避免生成的新 NSEvent 丢失窗口/位置信息导致 SwiftUI ScrollView 收不到。
private final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var isHorizontalLayout: Bool = false

    override func scrollWheel(with event: NSEvent) {
        guard isHorizontalLayout,
              !event.hasPreciseScrollingDeltas,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let swapped = event.withSwappedScrollDeltas() else {
            super.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: swapped)
    }
}

/// 主面板毛玻璃背景：用 CAShapeLayer 圆角遮罩精确裁剪，
/// 修复 .hudWindow 材质在圆角外残留白色/浅色像素的问题。
private final class RoundedPanelBackgroundView: NSVisualEffectView {
    var cornerRadius: CGFloat = 16
    private let maskLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.mask = maskLayer
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.mask = maskLayer
    }

    override func layout() {
        super.layout()
        maskLayer.frame = bounds
        maskLayer.path = CGPath(roundedRect: bounds,
                                cornerWidth: cornerRadius,
                                cornerHeight: cornerRadius,
                                transform: nil)
    }
}

/// 面板边缘/角落拖拽调整大小的透明覆盖层。
/// 只在边缘/角落区域拦截鼠标事件，其余区域放行给下层 SwiftUI 内容。
private struct PanelResizeEdge: OptionSet {
    let rawValue: UInt8
    static let minX = PanelResizeEdge(rawValue: 1 << 0) // 左边缘
    static let maxX = PanelResizeEdge(rawValue: 1 << 1) // 右边缘
    static let minY = PanelResizeEdge(rawValue: 1 << 2) // 下边缘
    static let maxY = PanelResizeEdge(rawValue: 1 << 3) // 上边缘
}

private final class PanelResizeOverlay: NSView {
    var positionProvider: () -> PanelPosition
    var onResize: (NSRect) -> Void
    var onResizeEnd: (NSRect) -> Void

    private let edgeThickness: CGFloat = 6
    private let cornerSize: CGFloat = 12
    private var startEdges: PanelResizeEdge = []
    private var startFrame: NSRect = .zero
    private var startLocation: NSPoint = .zero
    private var isResizing = false

    init(positionProvider: @escaping () -> PanelPosition,
         onResize: @escaping (NSRect) -> Void,
         onResizeEnd: @escaping (NSRect) -> Void) {
        self.positionProvider = positionProvider
        self.onResize = onResize
        self.onResizeEnd = onResizeEnd
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        edges(at: point).isEmpty ? nil : self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        let t = edgeThickness
        let c = cornerSize
        addCursorRect(NSRect(x: c, y: b.maxY - t, width: b.width - c * 2, height: t), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: c, y: 0, width: b.width - c * 2, height: t), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: c, width: t, height: b.height - c * 2), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b.maxX - t, y: c, width: t, height: b.height - c * 2), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: b.maxY - c, width: c, height: c), cursor: cornerCursor(.topLeft))
        addCursorRect(NSRect(x: b.maxX - c, y: 0, width: c, height: c), cursor: cornerCursor(.bottomRight))
        addCursorRect(NSRect(x: b.maxX - c, y: b.maxY - c, width: c, height: c), cursor: cornerCursor(.topRight))
        addCursorRect(NSRect(x: 0, y: 0, width: c, height: c), cursor: cornerCursor(.bottomLeft))
    }

    private enum PanelCorner {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// macOS 15+ 用系统对角缩放光标；旧系统回退为轴向光标
    private func cornerCursor(_ corner: PanelCorner) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch corner {
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch corner {
        case .topLeft, .bottomRight: return .resizeUpDown
        case .topRight, .bottomLeft: return .resizeLeftRight
        }
    }

    private func edges(at point: NSPoint) -> PanelResizeEdge {
        let b = bounds
        let t = edgeThickness
        let c = cornerSize
        if point.x < c && point.y > b.maxY - c { return [.minX, .maxY] }        // 左上角
        if point.x > b.maxX - c && point.y > b.maxY - c { return [.maxX, .maxY] } // 右上角
        if point.x < c && point.y < c { return [.minX, .minY] }                  // 左下角
        if point.x > b.maxX - c && point.y < c { return [.maxX, .minY] }         // 右下角
        var result: PanelResizeEdge = []
        if point.x < t { result.insert(.minX) }
        if point.x > b.maxX - t { result.insert(.maxX) }
        if point.y < t { result.insert(.minY) }
        if point.y > b.maxY - t { result.insert(.maxY) }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let detected = edges(at: point)
        guard !detected.isEmpty, let window else { return }
        startEdges = detected
        startFrame = window.frame
        startLocation = event.locationInWindow
        isResizing = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing, let window else { return }
        let dx = event.locationInWindow.x - startLocation.x
        let dy = event.locationInWindow.y - startLocation.y
        var frame = startFrame
        let position = positionProvider()
        let minSize = minimumSize(for: position)
        let maxSize = maximumSize(for: window.screen)

        if startEdges.contains(.maxY) {
            let height = min(max(startFrame.height + dy, minSize.height), maxSize.height)
            frame.size.height = height
        } else if startEdges.contains(.minY) {
            let height = min(max(startFrame.height - dy, minSize.height), maxSize.height)
            frame.origin.y = startFrame.maxY - height
            frame.size.height = height
        }
        if startEdges.contains(.maxX) {
            let width = min(max(startFrame.width + dx, minSize.width), maxSize.width)
            frame.size.width = width
        } else if startEdges.contains(.minX) {
            let width = min(max(startFrame.width - dx, minSize.width), maxSize.width)
            frame.origin.x = startFrame.maxX - width
            frame.size.width = width
        }
        onResize(frame)
    }

    override func mouseUp(with event: NSEvent) {
        guard isResizing else { return }
        isResizing = false
        onResizeEnd(window?.frame ?? startFrame)
    }

    private func minimumSize(for position: PanelPosition) -> CGSize {
        position.isVertical ? CGSize(width: 280, height: 320) : CGSize(width: 420, height: 220)
    }

    private func maximumSize(for screen: NSScreen?) -> CGSize {
        guard let screen else { return CGSize(width: 4096, height: 4096) }
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        return CGSize(width: max(1, visible.width - margin * 2),
                      height: max(1, visible.height - margin * 2))
    }
}

/// 屏幕底部的历史面板：⇧⌘V 呼出/收起，Esc 关闭，←/→ 选择，⌘←/→ 切换集合，
/// 回车或 ⌘数字 粘贴，Delete 删除选中条目。
@MainActor
final class PanelController: NSObject, NSWindowDelegate, NSPopoverDelegate {
    let viewModel: PanelViewModel

    private var panel: KeyablePanel?
    private var eventMonitor: Any?
    private var scrollWheelMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var suppressAutoHide = false
    private var filterPopover: NSPopover?
    private let settings: AppSettings
    private let onPaste: (ClipboardItem, NSRunningApplication?) -> Void
    private var cancellables = Set<AnyCancellable>()
    /// 当前面板是否为底部/顶部横向布局（左/右为竖向布局）。
    private var isHorizontalLayout: Bool = false
    var showJSONHandler: ((ClipboardItem) -> Void)?

    /// 面板右上 ··· 菜单的内容来源（由 AppDelegate 提供，与菜单栏菜单共用）
    var menuProvider: (() -> NSMenu)?
    var shouldStayVisibleWhenPanelResignsKey: (() -> Bool)?
    /// 当预览/编辑/设置等辅助窗口打开时，面板不应拦截 Delete、Space、Return 等按键。
    var shouldSuppressKeyHandling: (() -> Bool)?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(store: HistoryStore, settings: AppSettings,
         onPaste: @escaping (ClipboardItem, NSRunningApplication?) -> Void) {
        self.viewModel = PanelViewModel(store: store)
        self.settings = settings
        self.onPaste = onPaste
        super.init()
        viewModel.pasteHandler = { [weak self] item in
            let target = self?.previousApp
            self?.hide()
            onPaste(item, target)
        }
        viewModel.moreMenuHandler = { [weak self] in
            self?.showMoreMenu()
        }
        viewModel.filterPopoverHandler = { [weak self] in
            self?.toggleFilterPopover()
        }
        observeSettings()
    }

    private func observeSettings() {
        isHorizontalLayout = !settings.panelPosition.isVertical
        settings.$panelPosition
            .dropFirst()
            .sink { [weak self] position in
                guard let self else { return }
                self.isHorizontalLayout = !position.isVertical
                guard self.isVisible, let panel = self.panel,
                      let screen = panel.screen ?? NSScreen.main else { return }
                let frame = self.panelFrame(for: position, on: screen)
                panel.setFrame(frame, display: true, animate: true)
                self.viewModel.panelSize = panel.frame.size
            }
            .store(in: &cancellables)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        if panel == nil { makePanel() }
        guard let panel else { return }

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen {
            let frame = panelFrame(for: settings.panelPosition, on: screen)
            panel.setFrame(frame, display: true)
            viewModel.panelSize = panel.frame.size
        }

        if shouldStayVisibleWhenPanelResignsKey?() != true {
            viewModel.resetState()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeyMonitor()
        installScrollWheelMonitor()
    }

    private func panelFrame(for position: PanelPosition, on screen: NSScreen) -> NSRect {
        let frame = screen.visibleFrame
        let margin: CGFloat = 20
        let horizontalHeight: CGFloat = 330
        let verticalWidth: CGFloat = 380
        let horizontalSize = settings.horizontalPanelSize
        let verticalSize = settings.verticalPanelSize
        switch position {
        case .bottom:
            let width = min(horizontalSize?.width ?? (frame.width - (margin + 4) * 2),
                            frame.width - (margin + 4) * 2)
            let height = min(horizontalSize?.height ?? horizontalHeight,
                             frame.height - margin * 2)
            return NSRect(x: frame.minX + margin + 4,
                          y: frame.minY + margin,
                          width: width,
                          height: height)
        case .top:
            let width = min(horizontalSize?.width ?? (frame.width - (margin + 4) * 2),
                            frame.width - (margin + 4) * 2)
            let height = min(horizontalSize?.height ?? horizontalHeight,
                             frame.height - margin * 2)
            return NSRect(x: frame.minX + margin + 4,
                          y: frame.maxY - margin - height,
                          width: width,
                          height: height)
        case .left:
            let width = min(verticalSize?.width ?? verticalWidth,
                            frame.width - margin * 2)
            let height = min(verticalSize?.height ?? (frame.height - (margin + 4) * 2),
                             frame.height - (margin + 4) * 2)
            return NSRect(x: frame.minX + margin,
                          y: frame.minY + margin + 4,
                          width: width,
                          height: height)
        case .right:
            let width = min(verticalSize?.width ?? verticalWidth,
                            frame.width - margin * 2)
            let height = min(verticalSize?.height ?? (frame.height - (margin + 4) * 2),
                             frame.height - (margin + 4) * 2)
            return NSRect(x: frame.maxX - margin - width,
                          y: frame.minY + margin + 4,
                          width: width,
                          height: height)
        }
    }

    func refocus() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// 全局快捷键“下一个/上一个集合”：呼出面板并切换 tab
    func showAndSelectTab(delta: Int) {
        if !isVisible { show() }
        viewModel.selectTabOffset(delta)
    }

    /// 全局快捷键“搜索”：第一次按展开并对焦搜索框，再按一次清空并折叠
    func focusSearch() {
        if !isVisible { show() }
        if viewModel.searchExpanded {
            viewModel.search = ""
            viewModel.searchExpanded = false
        } else {
            viewModel.searchExpanded = true
            panel?.makeKey()
            viewModel.focusSearchToken += 1
        }
    }

    func hide() {
        removeKeyMonitor()
        removeScrollWheelMonitor()
        panel?.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard !suppressAutoHide, shouldStayVisibleWhenPanelResignsKey?() != true else { return }
        hide()
    }

    // MARK: - 筛选气泡（NSPopover，失焦自动收起）

    private func toggleFilterPopover() {
        if let popover = filterPopover, popover.isShown {
            popover.close()
            return
        }
        guard let anchor = viewModel.filterAnchor, anchor.window != nil else { return }
        if filterPopover == nil {
            let popover = NSPopover()
            popover.behavior = .transient // 点击气泡外自动关闭
            popover.animates = true
            popover.contentViewController = NSHostingController(
                rootView: FilterPanelView(viewModel: viewModel))
            popover.delegate = self
            filterPopover = popover
        }
        // 气泡是独立窗口：展示期间抑制面板失焦收起和搜索框折叠
        suppressAutoHide = true
        viewModel.suppressFocusLoss = true
        filterPopover?.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        suppressAutoHide = false
        viewModel.suppressFocusLoss = false
        if NSApp.isActive, isVisible {
            panel?.makeKey()
            viewModel.focusSearchToken += 1
        } else if !NSApp.isActive {
            // 用户点到了别的应用：连面板一起收起
            hide()
        }
    }

    // MARK: - ··· 菜单

    private func showMoreMenu() {
        guard let menu = menuProvider?(), let panel, let contentView = panel.contentView else { return }
        suppressAutoHide = true
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: contentView.bounds.maxX - 12, y: contentView.bounds.maxY - 18), in: contentView)
        suppressAutoHide = false
        // 菜单关闭后：App 还在前台则把焦点还给面板，否则说明用户点走了，收起面板
        if NSApp.isActive, isVisible {
            panel.makeKey()
        } else if !NSApp.isActive {
            hide()
        }
    }

    // MARK: - Private

    private func makePanel() {
        let panel = KeyablePanel(contentRect: .zero,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.delegate = self

        let background = RoundedPanelBackgroundView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active

        let hosting = PanelHostingView(rootView: AppearanceRoot(settings: self.settings) {
            PanelView(viewModel: self.viewModel, position: self.settings.panelPosition)
        })
        hosting.isHorizontalLayout = !settings.panelPosition.isVertical
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let resizeOverlay = PanelResizeOverlay(
            positionProvider: { [weak self] in self?.settings.panelPosition ?? .bottom },
            onResize: { [weak self] frame in self?.applyPanelResize(frame) },
            onResizeEnd: { [weak self] _ in self?.persistPanelSize() }
        )
        resizeOverlay.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(resizeOverlay)
        NSLayoutConstraint.activate([
            resizeOverlay.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            resizeOverlay.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            resizeOverlay.topAnchor.constraint(equalTo: background.topAnchor),
            resizeOverlay.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        panel.contentView = background
        self.panel = panel
    }

    /// 拖拽过程中实时更新面板 frame（锚定对侧边缘，由 PanelResizeOverlay 计算）
    private func applyPanelResize(_ frame: NSRect) {
        guard let panel else { return }
        panel.setFrame(frame, display: true)
        viewModel.panelSize = panel.frame.size
    }

    /// 拖拽结束后把当前尺寸写入设置，下次呼出面板沿用
    private func persistPanelSize() {
        guard let panel else { return }
        let size = panel.frame.size
        if settings.panelPosition.isVertical {
            settings.verticalPanelSize = size
        } else {
            settings.horizontalPanelSize = size
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            // 当预览/编辑/设置等辅助窗口打开时，不交还面板快捷键，
            // 让辅助窗口自己处理 Delete、Return、Space 等按键。
            if self.shouldSuppressKeyHandling?() == true { return event }
            guard self.panel?.isKeyWindow == true else { return event }
            let viewModel = self.viewModel
            let editing = viewModel.textEditing
            let hasCommand = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 53: // Esc：搜索框内优先取消搜索，其次取消卡片标题编辑，再其次取消多选标记，最后收起面板
                if viewModel.searchFocused {
                    viewModel.search = ""
                    if viewModel.searchExpanded {
                        withAnimation(.easeInOut(duration: 0.15)) { viewModel.searchExpanded = false }
                        return nil
                    }
                    self.hide()
                    return nil
                }
                if viewModel.editingCardTitleID != nil {
                    viewModel.cancelCardTitleEdit()
                    return nil
                }
                if viewModel.editingTagName { return event }
                if !viewModel.markedIDs.isEmpty {
                    viewModel.markedIDs = []
                    return nil
                }
                self.hide()
                return nil
            case 36: // Return：卡片标题编辑 / 标签名编辑时用于提交；否则粘贴选中项
                if viewModel.editingCardTitleID != nil {
                    viewModel.commitCardTitleEdit()
                    return nil
                }
                if viewModel.editingTagName { return event }
                viewModel.pasteSelected()
                return nil
            case 48: // Tab：编辑搜索框时跳到第一个结果卡片；否则切换卡片
                if editing {
                    // 仅普通 Tab（非 Shift）且搜索有结果时才切换
                    guard !event.modifierFlags.contains(.shift),
                          !viewModel.search.isEmpty,
                          !viewModel.filtered.isEmpty else { return event }
                    viewModel.suppressFocusLoss = true
                    viewModel.selectedIndex = 0
                    viewModel.blurSearchToken += 1
                    DispatchQueue.main.async {
                        viewModel.suppressFocusLoss = false
                    }
                    return nil
                }
                if event.modifierFlags.contains(.option) {
                    let delta = event.modifierFlags.contains(.shift) ? -1 : 1
                    viewModel.selectTabOffset(delta)
                } else {
                    let delta = event.modifierFlags.contains(.shift) ? -1 : 1
                    viewModel.moveSelection(delta)
                }
                return nil
            case 49: // Space：JSON / 文本 / 图片快速预览
                if editing { return event }
                if viewModel.previewSelectedJSON() { return nil }
                if viewModel.previewSelectedText() { return nil }
                viewModel.previewSelectedImage()
                return nil
            case 51: // Delete：编辑文本时是删除字符，否则删除标记项/选中条目
                if editing { return event }
                viewModel.deleteMarked()
                return nil
            case 123: // ← / ⌘←：编辑文本时是移动光标
                if editing { return event }
                if hasCommand { viewModel.selectTabOffset(-1) } else { viewModel.moveSelection(-1) }
                return nil
            case 124: // → / ⌘→
                if editing { return event }
                if hasCommand { viewModel.selectTabOffset(1) } else { viewModel.moveSelection(1) }
                return nil
            default:
                let flags = event.modifierFlags.intersection([.command, .shift, .option, .control]).rawValue

                // 搜索：面板内生效
                if let shortcut = self.settings.shortcut(for: .search),
                   event.keyCode == shortcut.keyCode,
                   flags == shortcut.modifiers {
                    self.focusSearch()
                    return nil
                }

                // 下一个/上一个集合：面板内生效
                if let shortcut = self.settings.shortcut(for: .nextPinboard),
                   event.keyCode == shortcut.keyCode,
                   flags == shortcut.modifiers {
                    viewModel.selectTabOffset(1)
                    return nil
                }
                if let shortcut = self.settings.shortcut(for: .prevPinboard),
                   event.keyCode == shortcut.keyCode,
                   flags == shortcut.modifiers {
                    viewModel.selectTabOffset(-1)
                    return nil
                }

                // 全选：读取设置中的快捷键（默认 ⌘A），编辑文本时交还输入框
                if let shortcut = self.settings.shortcut(for: .selectAll),
                   event.keyCode == shortcut.keyCode,
                   flags == shortcut.modifiers {
                    if editing { return event }
                    viewModel.markAll()
                    return nil
                }
                if hasCommand, let n = Self.digit(for: event.keyCode) {
                    viewModel.pasteNumber(n)
                    return nil
                }

                // 面板唤起后，按任意可打印字符直接进入搜索框输入
                if !editing,
                   let characters = event.characters,
                   characters.count == 1,
                   let char = characters.first,
                   Self.isPrintableSearchInput(char, event: event) {
                    if !viewModel.searchExpanded {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.searchExpanded = true
                        }
                        viewModel.search = String(char)
                    } else {
                        viewModel.search.append(char)
                    }
                    viewModel.focusSearchToken += 1
                    return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    // MARK: - 鼠标滚轮横向滚动适配

    /// 在底部/顶部横向布局时，将传统鼠标竖向滚轮事件转换为横向滚动事件，
    /// 避免鼠标用户必须按住 Shift 才能横向翻滚内容。触控板/Magic Mouse 等
    /// 精确滚动设备保持原行为，仍可两指/横向轻扫滚动。
    ///
    /// 这里同时做了两层处理：
    /// 1. `PanelHostingView.scrollWheel` 在响应链里直接转换并转发给 SwiftUI；
    /// 2. 本地 Monitor 作为兜底，捕获那些没有落到 hosting view 上的事件
    ///    （例如落在 SwiftUI ScrollView 内部时），通过 `NSApp.sendEvent` 派发。
    private func installScrollWheelMonitor() {
        removeScrollWheelMonitor()
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  self.isHorizontalLayout,
                  self.isVisible,
                  let panel = self.panel,
                  !event.hasPreciseScrollingDeltas,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  panel.frame.contains(NSEvent.mouseLocation),
                  let swapped = event.withSwappedScrollDeltas() else {
                return event
            }
            NSApp.sendEvent(swapped)
            return nil
        }
    }

    private func removeScrollWheelMonitor() {
        if let scrollWheelMonitor {
            NSEvent.removeMonitor(scrollWheelMonitor)
            self.scrollWheelMonitor = nil
        }
    }

    /// ANSI 键盘数字键 1-9 的 keyCode
    private static func digit(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }

    /// 判断按键是否为可直接进入搜索框的可打印字符（允许 Shift 大小写，排除 Command/Option/Control）
    private static func isPrintableSearchInput(_ char: Character, event: NSEvent) -> Bool {
        let activeModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard activeModifiers.isSubset(of: .shift) else { return false }
        return char.isLetter || char.isNumber || char.isPunctuation || char.isSymbol || char.isMathSymbol || char.isCurrencySymbol
    }
}

fileprivate extension NSEvent {
    /// 返回一个滚动轴被交换的新事件：竖向 delta 移到横向，横向 delta 移到竖向。
    /// 用于把传统鼠标竖向滚轮转成横向滚动。
    func withSwappedScrollDeltas() -> NSEvent? {
        guard let cgEvent = self.cgEvent?.copy() else { return nil }

        let deltaY = cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let deltaX = cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: deltaX)
        cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: deltaY)

        let pointDeltaY = cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let pointDeltaX = cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: pointDeltaX)
        cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: pointDeltaY)

        let fixedDeltaY = cgEvent.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedDeltaX = cgEvent.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2)
        cgEvent.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedDeltaX)
        cgEvent.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixedDeltaY)

        return NSEvent(cgEvent: cgEvent)
    }
}
