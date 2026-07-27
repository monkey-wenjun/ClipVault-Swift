import AppKit
import SwiftUI

@MainActor
final class JSONViewerWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel = JSONViewerViewModel()
    private var keyMonitor: Any?
    private weak var monitor: ClipboardMonitor?

    var isVisible: Bool { window?.isVisible == true }

    init(monitor: ClipboardMonitor? = nil) {
        self.monitor = monitor
        super.init()
        self.viewModel.monitor = monitor
    }

    func show(item: ClipboardItem) {
        guard let source = item.jsonSourceText,
              let value = JSONParser.parse(source) else { return }
        if window == nil { makeWindow() }
        viewModel.load(text: source, value: value, title: item.textPreviewTitle)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        window?.close()
    }

    private func makeWindow() {
        let controller = NSHostingController(rootView: JSONViewerRootView(viewModel: viewModel))
        let window = NSWindow(contentViewController: controller)
        window.title = NSLocalizedString("JSON 查看器", comment: "JSON viewer window title")
        window.setContentSize(NSSize(width: 1040, height: 760))
        window.minSize = NSSize(width: 780, height: 560)
        window.level = .floating
        window.hidesOnDeactivate = true
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            if event.keyCode == 49 || event.keyCode == 53 {
                self.hide()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
    }
}

extension ClipboardItem {
    var jsonSourceText: String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return JSONParser.parse(text) != nil ? text : nil
    }

    var textPreviewTitle: String {
        let raw = (jsonSourceText ?? text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return NSLocalizedString("JSON 数据", comment: "JSON data fallback title") }
        let firstLine = raw.components(separatedBy: .newlines).first ?? raw
        return String(firstLine.prefix(80))
    }

    var isJSONText: Bool { jsonSourceText != nil }
}

private enum JSONParser {
    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSONValue(any: object)
    }

    static func formattedString(from value: JSONValue) -> String {
        let object = value.foundationObject
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return value.inlineDescription
        }
        return string
    }
}

private enum JSONValue {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(NSNumber)
    case bool(Bool)
    case null

    init?(any: Any) {
        switch any {
        case let dict as [String: Any]:
            self = .object(dict.keys.sorted().compactMap { key in
                guard let child = JSONValue(any: dict[key] as Any) else { return nil }
                return (key, child)
            })
        case let array as [Any]:
            self = .array(array.compactMap(JSONValue.init(any:)))
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number)
            }
        case _ as NSNull:
            self = .null
        default:
            return nil
        }
    }

    var foundationObject: Any {
        switch self {
        case .object(let pairs):
            return Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1.foundationObject) })
        case .array(let values):
            return values.map(\.foundationObject)
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    var summary: String {
        switch self {
        case .object(let pairs):
            return String(format: NSLocalizedString("对象 · %d 个键", comment: "JSON object summary"), pairs.count)
        case .array(let values):
            return String(format: NSLocalizedString("数组 · %d 项", comment: "JSON array summary"), values.count)
        case .string(let value):
            return String(format: NSLocalizedString("字符串 · %d 字符", comment: "JSON string summary"), value.count)
        case .number: return NSLocalizedString("数字", comment: "JSON number summary")
        case .bool: return NSLocalizedString("布尔值", comment: "JSON boolean summary")
        case .null: return NSLocalizedString("null", comment: "JSON null summary")
        }
    }

    var inlineDescription: String {
        switch self {
        case .object(let pairs): return "{\(pairs.count)}"
        case .array(let values): return "[\(values.count)]"
        case .string(let value): return "\"\(value)\""
        case .number(let value): return value.stringValue
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }
}

private struct JSONTreeRow: Identifiable {
    let id: UUID
    let key: String?
    let value: JSONValue
    let depth: Int
    let matched: Bool
    let isExpanded: Bool
    let isContainer: Bool
    let path: String
}

@MainActor
private final class JSONViewerViewModel: ObservableObject {
    @Published var root: JSONNode?
    @Published var searchQuery = ""
    @Published var selectedNodeID: UUID?
    @Published var formattedText = ""
    @Published var title = NSLocalizedString("JSON 数据", comment: "JSON viewer default title")
    @Published var summary = ""
    @Published private var expandedIDs: Set<UUID> = []
    weak var monitor: ClipboardMonitor?

    func load(text: String, value: JSONValue, title: String) {
        let root = JSONNode.makeRoot(value: value)
        self.root = root
        self.title = title
        self.summary = value.summary
        self.formattedText = JSONParser.formattedString(from: value)
        self.searchQuery = ""
        self.selectedNodeID = nil
        self.expandedIDs = root.collectExpandableIDs()
    }

    func toggleExpansion(for id: UUID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
        objectWillChange.send()
    }

    func expandAll() {
        expandedIDs = root?.collectExpandableIDs() ?? []
    }

    func collapseAll() {
        expandedIDs = []
    }

    func copyFormattedJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formattedText, forType: .string)
        monitor?.syncChangeCount()
    }

    func copySelectedValue() {
        guard let node = selectedNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(JSONParser.formattedString(from: node.value), forType: .string)
        monitor?.syncChangeCount()
    }

    var selectedNode: JSONNode? {
        root?.find(id: selectedNodeID)
    }

    var visibleRows: [JSONTreeRow] {
        guard let root else { return [] }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rows: [JSONTreeRow] = []
        for child in root.children {
            _ = appendRows(from: child, query: query, rows: &rows)
        }
        return rows
    }

    private func appendRows(from node: JSONNode, query: String, rows: inout [JSONTreeRow]) -> Bool {
        let selfMatches = query.isEmpty || node.searchableText.contains(query)
        var childRows: [JSONTreeRow] = []
        var childMatched = false
        for child in node.children {
            if appendRows(from: child, query: query, rows: &childRows) {
                childMatched = true
            }
        }
        let isExpanded = expandedIDs.contains(node.id) || (!query.isEmpty && childMatched)
        let include = selfMatches || childMatched || query.isEmpty
        guard include else { return false }

        rows.append(JSONTreeRow(id: node.id,
                                key: node.key,
                                value: node.value,
                                depth: node.depth,
                                matched: !query.isEmpty && selfMatches,
                                isExpanded: isExpanded,
                                isContainer: node.value.isContainer,
                                path: node.path))
        if isExpanded {
            rows.append(contentsOf: childRows)
        }
        return true
    }
}

private final class JSONNode: Identifiable {
    let id = UUID()
    let key: String?
    let value: JSONValue
    let depth: Int
    let path: String
    let children: [JSONNode]

    init(key: String?, value: JSONValue, depth: Int, path: String) {
        self.key = key
        self.value = value
        self.depth = depth
        self.path = path
        switch value {
        case .object(let pairs):
            self.children = pairs.map { pair in
                let childPath = path.isEmpty ? pair.0 : path + "." + pair.0
                return JSONNode(key: pair.0, value: pair.1, depth: depth + 1, path: childPath)
            }
        case .array(let values):
            self.children = values.enumerated().map { index, value in
                let key = "[\(index)]"
                return JSONNode(key: key, value: value, depth: depth + 1, path: path + key)
            }
        default:
            self.children = []
        }
    }

    static func makeRoot(value: JSONValue) -> JSONNode {
        JSONNode(key: nil, value: value, depth: 0, path: "$")
    }

    func collectExpandableIDs() -> Set<UUID> {
        var result: Set<UUID> = value.isContainer ? [id] : []
        for child in children {
            result.formUnion(child.collectExpandableIDs())
        }
        return result
    }

    func find(id: UUID?) -> JSONNode? {
        guard let id else { return nil }
        if self.id == id { return self }
        for child in children {
            if let found = child.find(id: id) { return found }
        }
        return nil
    }

    var searchableText: String {
        [key, path, value.inlineDescription, value.summary]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
    }
}

private struct JSONViewerRootView: View {
    @ObservedObject var viewModel: JSONViewerViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                leftPane.frame(minWidth: 380)
                rightPane.frame(minWidth: 340)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(viewModel.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("搜索键名、路径或值", text: $viewModel.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                Button("全部展开") { viewModel.expandAll() }
                Button("全部折叠") { viewModel.collapseAll() }
                Button("复制格式化 JSON") { viewModel.copyFormattedJSON() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private var leftPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.visibleRows) { row in
                        JSONTreeRowView(row: row,
                                        isSelected: viewModel.selectedNodeID == row.id,
                                        onToggle: { viewModel.toggleExpansion(for: row.id) },
                                        onSelect: { viewModel.selectedNodeID = row.id })
                    }
                }
                .padding(10)
            }
            Divider()
            HStack {
                Button("复制选中节点") { viewModel.copySelectedValue() }
                    .disabled(viewModel.selectedNode == nil)
                Spacer()
                if let node = viewModel.selectedNode {
                    Text(node.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text("选中左侧节点后可复制其 JSON")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
    }

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let node = viewModel.selectedNode {
                Text("节点详情")
                    .font(.headline)
                Text(node.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                TextEditor(text: .constant(JSONParser.formattedString(from: node.value)))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: 220)
                Divider()
            } else {
                Text("格式化预览")
                    .font(.headline)
            }

            TextEditor(text: .constant(viewModel.formattedText))
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
    }
}

private struct JSONTreeRowView: View {
    let row: JSONTreeRow
    let isSelected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear.frame(width: CGFloat(max(row.depth - 1, 0)) * 16, height: 1)
            Button(action: onToggle) {
                Image(systemName: row.isContainer ? (row.isExpanded ? "chevron.down" : "chevron.right") : "circle.fill")
                    .font(.system(size: row.isContainer ? 11 : 5, weight: .semibold))
                    .foregroundStyle(row.isContainer ? .secondary : .tertiary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .disabled(!row.isContainer)

            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let key = row.key {
                            Text(key)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                        Text(row.value.inlineDescription)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(valueColor)
                            .lineLimit(1)
                    }
                    Text(row.value.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if row.matched { return Color.yellow.opacity(0.15) }
        return .clear
    }

    private var valueColor: Color {
        switch row.value {
        case .string: return .green
        case .number: return .orange
        case .bool: return .blue
        case .null: return .secondary
        case .object, .array: return .purple
        }
    }
}
