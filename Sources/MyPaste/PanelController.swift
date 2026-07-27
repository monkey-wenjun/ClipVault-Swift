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
    /// 搜索框或标签输入框持有焦点时，键盘监控放行编辑按键（Delete/方向键/Return 等）
    var textEditing = false

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

/// 屏幕底部的历史面板：⇧⌘V 呼出/收起，Esc 关闭，←/→ 选择，⌘←/→ 切换集合，
/// 回车或 ⌘数字 粘贴，Delete 删除选中条目。
@MainActor
final class PanelController: NSObject, NSWindowDelegate, NSPopoverDelegate {
    let viewModel: PanelViewModel

    private var panel: KeyablePanel?
    private var eventMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var suppressAutoHide = false
    private var filterPopover: NSPopover?
    private let settings: AppSettings
    private let onPaste: (ClipboardItem, NSRunningApplication?) -> Void
    private var cancellables = Set<AnyCancellable>()
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
        settings.$panelPosition
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.isVisible, let panel = self.panel,
                      let screen = panel.screen ?? NSScreen.main else { return }
                let frame = self.panelFrame(for: self.settings.panelPosition, on: screen)
                panel.setFrame(frame, display: true, animate: true)
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
        }

        if shouldStayVisibleWhenPanelResignsKey?() != true {
            viewModel.resetState()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeyMonitor()
    }

    private func panelFrame(for position: PanelPosition, on screen: NSScreen) -> NSRect {
        let frame = screen.visibleFrame
        let margin: CGFloat = 20
        let horizontalHeight: CGFloat = 330
        let verticalWidth: CGFloat = 380
        switch position {
        case .bottom:
            return NSRect(x: frame.minX + margin + 4,
                          y: frame.minY + margin,
                          width: frame.width - (margin + 4) * 2,
                          height: horizontalHeight)
        case .top:
            return NSRect(x: frame.minX + margin + 4,
                          y: frame.maxY - margin - horizontalHeight,
                          width: frame.width - (margin + 4) * 2,
                          height: horizontalHeight)
        case .left:
            return NSRect(x: frame.minX + margin,
                          y: frame.minY + margin + 4,
                          width: verticalWidth,
                          height: frame.height - (margin + 4) * 2)
        case .right:
            return NSRect(x: frame.maxX - margin - verticalWidth,
                          y: frame.minY + margin + 4,
                          width: verticalWidth,
                          height: frame.height - (margin + 4) * 2)
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
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: AppearanceRoot(settings: self.settings) {
            PanelView(viewModel: self.viewModel, position: self.settings.panelPosition)
        })
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        panel.contentView = background
        self.panel = panel
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
            case 53: // Esc：先取消多选标记，其次交还输入框，最后收起面板
                if editing { return event }
                if !viewModel.markedIDs.isEmpty {
                    viewModel.markedIDs = []
                    return nil
                }
                self.hide()
                return nil
            case 36: // Return：编辑标签名时用于提交；搜索时仍表示粘贴选中项
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
                // 全选：读取设置中的快捷键（默认 ⌘A），编辑文本时交还输入框
                if let shortcut = self.settings.shortcut(for: .selectAll),
                   event.keyCode == shortcut.keyCode,
                   event.modifierFlags.intersection([.command, .shift, .option, .control]).rawValue == shortcut.modifiers {
                    if editing { return event }
                    viewModel.markAll()
                    return nil
                }
                if hasCommand, let n = Self.digit(for: event.keyCode) {
                    viewModel.pasteNumber(n)
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
}
