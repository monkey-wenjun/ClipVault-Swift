import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum PanelField: Hashable {
    case search
    case rename(UUID)
}

/// 悬停效果：浅底色 + 一点点阴影，同时提示可点击
private struct HoverEffect: ViewModifier {
    @State private var hovering = false
    var radius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .overlay {
                if hovering {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                        .allowsHitTesting(false) // 高亮层不能拦截点击
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.35 : 0), radius: 3, y: 1)
            .scaleEffect(hovering ? 1.06 : 1)
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverEffect(radius: CGFloat = 8) -> some View {
        modifier(HoverEffect(radius: radius))
    }
}

struct PanelView: View {
    @ObservedObject var viewModel: PanelViewModel
    var position: PanelPosition
    @FocusState private var focusedField: PanelField?
    @State private var draggedTabID: UUID?
    @State private var isTargetedForDrop = false

    var body: some View {
        let layout = Group {
            if position.isVertical {
                verticalBody
            } else {
                horizontalBody
            }
        }
        return layout
    }

    private var horizontalBody: some View {
        VStack(spacing: 10) {
            topBar

            ZStack {
                ScrollViewReader { proxy in
                    horizontalCardScroll(proxy: proxy)
                }

                emptyOverlays
                dropOverlay
            }
            .onDrop(of: [.fileURL], delegate: PanelDropDelegate(isTargeted: $isTargetedForDrop, onDrop: { urls in
                viewModel.handleDroppedFiles(urls)
            }))
        }
        .padding(.vertical, 14)
        .onChange(of: focusedField) { _, newFocus in handleFocusChange(newFocus) }
        .onChange(of: viewModel.focusSearchToken) { _, _ in focusedField = .search }
    }

    private var verticalBody: some View {
        VStack(spacing: 10) {
            topSearchBar

            HStack(spacing: 10) {
                sideBar
                cardArea
            }
        }
        .padding(.vertical, 14)
        .onChange(of: focusedField) { _, newFocus in handleFocusChange(newFocus) }
        .onChange(of: viewModel.focusSearchToken) { _, _ in focusedField = .search }
    }

    private var cardArea: some View {
        ZStack {
            ScrollViewReader { proxy in
                verticalCardScroll(proxy: proxy)
            }

            emptyOverlays
            dropOverlay
        }
        .onDrop(of: [.fileURL], delegate: PanelDropDelegate(isTargeted: $isTargetedForDrop, onDrop: { urls in
            viewModel.handleDroppedFiles(urls)
        }))
    }

    /// 左右布局顶部：横向搜索框 + ···
    private var topSearchBar: some View {
        ZStack {
            HStack(spacing: 12) {
                searchControl
                Spacer()
            }
            .padding(.horizontal, 16)

            HStack {
                Spacer()
                Button {
                    viewModel.moreMenuHandler?()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(radius: 16)
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 30)
    }

    /// 左右布局侧边栏：窄边栏，文字竖排（图标在上，文字在下竖排）
    private var sideBar: some View {
        VStack(spacing: 8) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    sideHistoryTabButton
                    ForEach(viewModel.pinboards) { pinboard in
                        sidePinboardTab(pinboard)
                    }
                    Button {
                        viewModel.quickAddPinboard()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .hoverEffect(radius: 12)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 44)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sideHistoryTabButton: some View {
        let isSelected = viewModel.selectedHistoryTab
        let title = NSLocalizedString("剪贴板", comment: "History tab title")
        return Button {
            viewModel.selectedHistoryTab = true
            viewModel.selectedTab = nil
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12))
                verticalText(title, limit: 3, color: isSelected ? Color.accentColor : .primary)
            }
            .padding(.vertical, 6)
            .frame(width: 36)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(radius: 8)
    }

    @ViewBuilder
    private func sidePinboardTab(_ pinboard: Pinboard) -> some View {
        if viewModel.renamingTagID == pinboard.id {
            TextField("", text: $viewModel.renamingName)
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 2)
                .padding(.vertical, 6)
                .frame(minWidth: 36, maxWidth: 36, minHeight: 72)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .focused($focusedField, equals: .rename(pinboard.id))
                .onSubmit {
                    viewModel.commitRename()
                    focusedField = nil
                }
        } else {
            let isSelected = viewModel.selectedTab == pinboard.id
            let tagColor = pinboard.colorHex.flatMap { Color(hex: $0) }
            let activeColor = tagColor ?? .accentColor
            Button {
                viewModel.selectedHistoryTab = false
                viewModel.selectedTab = pinboard.id
            } label: {
                VStack(spacing: 3) {
                    Circle()
                        .fill(tagColor ?? .accentColor)
                        .frame(width: 6, height: 6)
                    verticalText(pinboard.name, limit: 3, color: isSelected ? activeColor : .primary)
                }
                .padding(.vertical, 6)
                .frame(width: 36)
                .background(
                    isSelected ? activeColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(radius: 8)
            .onTapGesture(count: 2) {
                viewModel.startRenaming(pinboard)
                DispatchQueue.main.async { focusedField = .rename(pinboard.id) }
            }
            .contextMenu {
                Button("重命名") {
                    viewModel.startRenaming(pinboard)
                    DispatchQueue.main.async { focusedField = .rename(pinboard.id) }
                }
                Menu("标签颜色") {
                    ForEach(Pinboard.colorPalette, id: \.hex) { entry in
                        Button {
                            viewModel.store.setPinboardColor(pinboard.id, colorHex: entry.hex)
                        } label: {
                            Label(entry.name, systemImage: pinboard.colorHex == entry.hex ? "checkmark.circle.fill" : "circle.fill")
                        }
                        .tint(Color(hex: entry.hex))
                    }
                    Divider()
                    Button("无颜色") {
                        viewModel.store.setPinboardColor(pinboard.id, colorHex: nil)
                    }
                }
                Divider()
                Button("删除集合") {
                    viewModel.store.removePinboard(pinboard.id)
                }
            }
        }
    }

    /// 竖排文字：取前 N 个字符，从上到下堆叠
    private func verticalText(_ text: String, limit: Int, color: Color) -> some View {
        let chars = Array(text).prefix(limit)
        return VStack(spacing: 1) {
            ForEach(Array(chars.enumerated()), id: \.offset) { _, char in
                Text(String(char))
                    .font(.system(size: 11))
                    .foregroundStyle(color)
            }
        }
    }

    private func handleFocusChange(_ newFocus: PanelField?) {
        viewModel.textEditing = newFocus != nil
        // 搜索框失焦即自动折叠并清空（筛选气泡展示期间除外）
        if newFocus != .search && viewModel.searchExpanded && !viewModel.suppressFocusLoss {
            withAnimation(.easeInOut(duration: 0.15)) { viewModel.searchExpanded = false }
            viewModel.search = ""
        }
        // 重命名输入框失焦即自动保存
        if viewModel.renamingTagID != nil {
            if case .rename = newFocus {} else { viewModel.commitRename() }
        }
    }

    @ViewBuilder
    private var emptyOverlays: some View {
        if showsEmptyPinboard {
            emptyState(title: NSLocalizedString("Pinboard 为空", comment: "Empty pinboard placeholder"))
        } else if showsEmptyHistory {
            emptyState(title: NSLocalizedString("历史记录为空", comment: "Empty history placeholder"))
        }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isTargetedForDrop {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .background(Color.accentColor.opacity(0.08))
                .overlay(
                    Text(NSLocalizedString("拖放文件到当前集合", comment: "Drop files hint"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                )
                .allowsHitTesting(false)
        }
    }

    private func horizontalCardScroll(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                cardListContent()
                if viewModel.visibleCount < viewModel.filtered.count {
                    Color.clear
                        .frame(width: 1)
                        .onAppear { viewModel.loadMore() }
                }
            }
            .padding(.horizontal, 16)
        }
        .onChange(of: viewModel.selectedIndex) { _, newIndex in
            let items = Array(viewModel.filtered.prefix(viewModel.visibleCount))
            guard items.indices.contains(newIndex) else { return }
            proxy.scrollTo(items[newIndex].id)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = nil
        }
    }

    private func verticalCardScroll(proxy: ScrollViewProxy) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 12) {
                cardListContent()
                if viewModel.visibleCount < viewModel.filtered.count {
                    Color.clear
                        .frame(height: 1)
                        .onAppear { viewModel.loadMore() }
                }
            }
            .padding(.vertical, 12)
        }
        .onChange(of: viewModel.selectedIndex) { _, newIndex in
            let items = Array(viewModel.filtered.prefix(viewModel.visibleCount))
            guard items.indices.contains(newIndex) else { return }
            proxy.scrollTo(items[newIndex].id)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = nil
        }
    }

    @ViewBuilder
    private func cardListContent() -> some View {
        ForEach(Array(viewModel.filtered.prefix(viewModel.visibleCount).enumerated()), id: \.element.id) { index, item in
            CardView(item: item,
                     number: index < 9 ? index + 1 : nil,
                     isSelected: index == viewModel.selectedIndex,
                     isMarked: viewModel.markedIDs.contains(item.id),
                     image: viewModel.cardImage(for: item),
                     tag: viewModel.searchTagMap[item.id],
                     fallbackBandColor: viewModel.fallbackBandColor(for: item),
                     onBrokenImage: { viewModel.handleBrokenImage(item) })
                .id(item.id)
                .onTapGesture(count: 2) { viewModel.paste(item) }
                .onTapGesture(count: 1) { viewModel.toggleMark(item) }
                .contextMenu { cardMenu(for: item) }
                .onDrag {
                    viewModel.dragItemProvider(for: item)
                }
        }
    }

    /// 当前选中的是集合标签且该集合没有任何条目
    private var showsEmptyPinboard: Bool {
        guard let selectedTab = viewModel.selectedTab else { return false }
        return viewModel.store.pinboard(selectedTab)?.items.isEmpty == true
    }

    /// 当前展示的是历史（未选中任何集合标签）且历史条目为空
    private var showsEmptyHistory: Bool {
        viewModel.selectedTab == nil && viewModel.store.items.isEmpty
    }

    private func emptyState(title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.secondary.opacity(0.7))
            .allowsHitTesting(false)
    }

    // MARK: - 顶部一行：搜索 + 标签居中，··· 固定最右，空白处可拖动面板

    private var topBar: some View {
        ZStack {
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        searchControl

                        HStack(spacing: 8) {
                            tabButton(title: NSLocalizedString("剪贴板", comment: "History tab title"), id: nil, isHistoryTab: true)
                            ForEach(viewModel.pinboards) { pinboard in
                                pinboardTab(pinboard)
                                    .opacity(draggedTabID == pinboard.id ? 0.4 : 1)
                                    .onDrag {
                                        draggedTabID = pinboard.id
                                        return NSItemProvider(object: pinboard.id.uuidString as NSString)
                                    }
                                    .onDrop(of: [.text], delegate: TabDropDelegate(
                                        targetID: pinboard.id,
                                        draggedID: $draggedTabID,
                                        move: viewModel.movePinboard))
                            }
                            Button {
                                viewModel.quickAddPinboard()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 13))
                                    .frame(width: 30, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .hoverEffect(radius: 15)
                        }
                    }
                    .padding(.horizontal, 2)
                    // 内容不足一行时整体居中，超出时可横向滚动
                    .frame(minWidth: geo.size.width - 2, minHeight: geo.size.height, alignment: .center)
                }
            }
            .padding(.trailing, 32) // 给 ··· 留位置

            HStack {
                Spacer()
                Button {
                    viewModel.moreMenuHandler?()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(radius: 16)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    // MARK: - 搜索：默认图标，点击展开

    @ViewBuilder
    private var searchControl: some View {
        if viewModel.searchExpanded {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索", text: $viewModel.search)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .search)
                Button {
                    viewModel.filterPopoverHandler?()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 11))
                        .foregroundStyle(viewModel.hasActiveFilter ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("筛选")
                .background(PopoverAnchorResolver { viewModel.filterAnchor = $0 })
                Button {
                    viewModel.search = ""
                    withAnimation(.easeInOut(duration: 0.15)) { viewModel.searchExpanded = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .frame(width: 250)
            .transition(.opacity)
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { viewModel.searchExpanded = true }
                focusedField = .search
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .hoverEffect(radius: 16)
        }
    }

    // MARK: - 自定义标签（双击重命名 + 颜色）

    @ViewBuilder
    private func pinboardTab(_ pinboard: Pinboard) -> some View {
        if viewModel.renamingTagID == pinboard.id {
            TextField("标签名称", text: $viewModel.renamingName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 120)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.2), in: Capsule())
                .focused($focusedField, equals: .rename(pinboard.id))
                .onSubmit {
                    viewModel.commitRename()
                    focusedField = nil
                }
        } else {
            let isSelected = viewModel.selectedTab == pinboard.id
            let tagColor = pinboard.colorHex.flatMap { Color(hex: $0) }
            let activeColor = tagColor ?? .accentColor
            HStack(spacing: 5) {
                if let tagColor {
                    Circle()
                        .fill(tagColor)
                        .frame(width: 6, height: 6)
                }
                Text(pinboard.name)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? activeColor : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? activeColor.opacity(0.12) : Color.clear,
                in: Capsule()
            )
            .contentShape(Capsule())
            .hoverEffect(radius: 15)
            .onTapGesture(count: 2) {
                viewModel.startRenaming(pinboard)
                // 等输入框渲染出来再取焦点
                DispatchQueue.main.async { focusedField = .rename(pinboard.id) }
            }
            .onTapGesture(count: 1) {
                viewModel.selectedHistoryTab = false
                viewModel.selectedTab = pinboard.id
            }
            .contextMenu {
                Button("重命名") {
                    viewModel.startRenaming(pinboard)
                    DispatchQueue.main.async { focusedField = .rename(pinboard.id) }
                }
                Menu("标签颜色") {
                    ForEach(Pinboard.colorPalette, id: \.hex) { entry in
                        Button {
                            viewModel.store.setPinboardColor(pinboard.id, colorHex: entry.hex)
                        } label: {
                            Label(entry.name, systemImage: pinboard.colorHex == entry.hex ? "checkmark.circle.fill" : "circle.fill")
                        }
                        .tint(Color(hex: entry.hex))
                    }
                    Divider()
                    Button("无颜色") {
                        viewModel.store.setPinboardColor(pinboard.id, colorHex: nil)
                    }
                }
                Divider()
                Button("删除集合") {
                    viewModel.store.removePinboard(pinboard.id)
                }
            }
        }
    }

    // MARK: - 标签按钮

    private func tabButton(title: String, id: UUID?, isHistoryTab: Bool = false) -> some View {
        let isSelected = isHistoryTab ? viewModel.selectedHistoryTab : (viewModel.selectedTab == id)
        return Button(title) {
            if isHistoryTab {
                viewModel.selectedHistoryTab = true
                viewModel.selectedTab = nil
            } else {
                viewModel.selectedHistoryTab = false
                viewModel.selectedTab = id
            }
        }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: Capsule())
            .contentShape(Capsule())
            .hoverEffect(radius: 15)
    }

    // MARK: - 卡片右键菜单

    @ViewBuilder
    private func cardMenu(for item: ClipboardItem) -> some View {
        Button("粘贴") { viewModel.paste(item) }
        if item.isJSONText {
            Button("打开 JSON 查看器") {
                viewModel.jsonViewerHandler?(item)
            }
        }
        if item.kind == .text {
            Button("预览") { viewModel.textPreviewHandler?(item) }
        }
        Menu("移动到集合") {
            ForEach(viewModel.pinboards) { pinboard in
                Button(pinboard.name) { viewModel.addToPinboard(item, pinboardID: pinboard.id) }
            }
            if !viewModel.pinboards.isEmpty { Divider() }
            Button("新建集合并移入") { viewModel.quickAddPinboard(with: item) }
        }
        Button(deleteTitle(for: item)) { viewModel.deleteMarkedOrItem(item) }
    }

    /// 右键删除按钮文案：右键项在标记集合中时显示批量数量
    private func deleteTitle(for item: ClipboardItem) -> String {
        let verb = viewModel.selectedTab != nil
            ? NSLocalizedString("从集合移除", comment: "Remove from pinboard action")
            : NSLocalizedString("删除", comment: "Delete action")
        if viewModel.markedIDs.contains(item.id), viewModel.markedIDs.count > 1 {
            return "\(verb) \(viewModel.markedIDs.count) \(NSLocalizedString("项", comment: "Items count suffix"))"
        }
        return verb
    }
}

// MARK: - 筛选气泡内容（在 NSPopover 中展示）

struct FilterPanelView: View {
    @ObservedObject var viewModel: PanelViewModel

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section(title: NSLocalizedString("类型", comment: "Filter section: Type")) {
                    LazyVGrid(columns: gridColumns, spacing: 6) {
                        ForEach(PanelViewModel.ContentType.allCases) { type in
                            chip(title: type.title,
                                 isSelected: viewModel.typeFilter == type) {
                                viewModel.typeFilter = viewModel.typeFilter == type ? nil : type
                            } icon: {
                                Image(systemName: type.icon)
                            }
                        }
                    }
                }

                if !viewModel.availableApps.isEmpty {
                    section(title: NSLocalizedString("应用", comment: "Filter section: Apps")) {
                        LazyVGrid(columns: gridColumns, spacing: 6) {
                            ForEach(viewModel.availableApps, id: \.bundleID) { app in
                                chip(title: app.name,
                                     isSelected: viewModel.appFilter == app.bundleID) {
                                    viewModel.appFilter = viewModel.appFilter == app.bundleID ? nil : app.bundleID
                                } icon: {
                                    if let icon = AppIconCache.icon(for: app.bundleID) {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .frame(width: 14, height: 14)
                                    }
                                }
                            }
                        }
                    }
                }

                section(title: NSLocalizedString("图钉板", comment: "Filter section: Pinboards")) {
                    LazyVGrid(columns: gridColumns, spacing: 6) {
                        chip(title: NSLocalizedString("剪贴板", comment: "History tab title"),
                             isSelected: viewModel.searchScope == .history) {
                            viewModel.searchScope = viewModel.searchScope == .history ? .all : .history
                        } icon: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        ForEach(viewModel.pinboards) { board in
                            chip(title: board.name,
                                 isSelected: viewModel.searchScope == .pinboard(board.id)) {
                                viewModel.searchScope = viewModel.searchScope == .pinboard(board.id)
                                    ? .all : .pinboard(board.id)
                            } icon: {
                                Circle()
                                    .fill(board.colorHex.flatMap { Color(hex: $0) } ?? .secondary)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 440)
        .frame(maxHeight: 320)
    }

    private func section<Content: View>(title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func chip<Icon: View>(title: String, isSelected: Bool,
                                  action: @escaping () -> Void,
                                  @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon()
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

/// 把筛选按钮背后的 NSView 暴露给 PanelController，作为 NSPopover 锚点
private struct PopoverAnchorResolver: NSViewRepresentable {
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView) }
    }
}

/// 标签拖拽排序的 Drop 代理：拖到目标标签上即交换位置
private struct TabDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedID: UUID?
    let move: (_ dragged: UUID, _ onto: UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            move(draggedID, targetID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }
}

struct CardView: View {
    @Environment(\.colorScheme) private var colorScheme

    let item: ClipboardItem
    let number: Int?
    let isSelected: Bool
    /// 单击/⌃A 标记的多选状态
    let isMarked: Bool
    /// 解密后的图片（仅 kind == .image 时非空）
    let image: NSImage?
    /// 全局搜索命中时，条目所属的标签
    var tag: Pinboard? = nil
    /// 无来源应用条目的头带底色（跟随标签色或主题蓝）
    var fallbackBandColor: Color = .accentColor
    /// 图片加载失败（文件损坏/丢失）时回调，用于自动清除该条目
    var onBrokenImage: (() -> Void)? = nil
    @State private var hovering = false

    /// 头带底色：来源应用图标主色；无来源时用传入的回退色
    private var bandColor: Color {
        if let nsColor = item.sourceColor { return Color(nsColor: nsColor) }
        return fallbackBandColor
    }

    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color.black : Color(nsColor: .windowBackgroundColor)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .primary
    }

    private var secondaryTextColor: Color {
        if colorScheme == .dark {
            return hovering ? Color.white.opacity(0.8) : Color.white.opacity(0.55)
        }
        return hovering ? .primary : .secondary
    }

    private var hoverBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.25) : Color.black.opacity(0.12)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 头带：类型 + 时间 + 来源应用图标
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.kind.title)
                        .font(.caption).bold()
                        .foregroundStyle(.white)
                    Text(item.relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                if let icon = item.sourceIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 26, height: 26)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(bandColor)

            // 内容区 + 底部统计
            VStack(alignment: .leading, spacing: 8) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack {
                    Text(item.footer)
                        .font(.caption)
                        .foregroundStyle(secondaryTextColor)
                    if let tag {
                        HStack(spacing: 3) {
                            if let color = tag.colorHex.flatMap({ Color(hex: $0) }) {
                                Circle().fill(color).frame(width: 5, height: 5)
                            }
                            Text(tag.name)
                                .font(.caption2)
                                .foregroundStyle(secondaryTextColor)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if let number {
                        Text("⌘\(number)")
                            .font(.caption)
                            .foregroundStyle(secondaryTextColor)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 260, height: 236)
        .background(cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor
                        : (isMarked ? Color.accentColor.opacity(0.6)
                           : (hovering ? hoverBorderColor : Color.clear)),
                        lineWidth: isSelected || isMarked ? 2 : 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(hovering ? 0.4 : 0), radius: 6, y: 3)
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .color:
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: item.text ?? "") ?? .clear)
                Text(item.text ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.7) : .secondary)
            }
        case .text:
            Text(item.text ?? "")
                .font(.system(size: 13))
                .foregroundStyle(primaryTextColor)
                .lineLimit(9)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image:
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                // 图片不可用：不展示占位，回调触发自动删除该条目
                Color.clear
                    .onAppear { onBrokenImage?() }
            }
        case .file:
            VStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(secondaryTextColor)
                Text(item.fileDisplayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(URL(fileURLWithPath: item.text ?? "").path)
                    .font(.system(size: 10))
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 拖拽接收

private struct PanelDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func dropEntered(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) { isTargeted = true }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) { isTargeted = false }
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }

        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [onDrop] in
            onDrop(urls)
        }
        return true
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 3, let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b: Double
        if s.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
        }
        self = Color(red: r, green: g, blue: b)
    }
}
