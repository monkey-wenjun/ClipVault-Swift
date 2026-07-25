import Foundation

/// 固定集合：用户手动把历史条目钉进去，不受保留策略和数量上限影响。
struct Pinboard: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// 标签颜色（十六进制，如 "#0A84FF"）；nil 表示默认色
    var colorHex: String?
    var items: [ClipboardItem]

    init(id: UUID = UUID(), name: String, colorHex: String? = nil, items: [ClipboardItem] = []) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.items = items
    }

    /// 可选的标签颜色
    static let colorPalette: [(name: String, hex: String)] = [
        (NSLocalizedString("红色", comment: "Red color"), "#FF3B30"),
        (NSLocalizedString("橙色", comment: "Orange color"), "#FF9500"),
        (NSLocalizedString("黄色", comment: "Yellow color"), "#FFCC00"),
        (NSLocalizedString("绿色", comment: "Green color"), "#34C759"),
        (NSLocalizedString("蓝色", comment: "Blue color"), "#0A84FF"),
        (NSLocalizedString("紫色", comment: "Purple color"), "#BF5AF2"),
        (NSLocalizedString("粉色", comment: "Pink color"), "#FF375F"),
        (NSLocalizedString("灰色", comment: "Gray color"), "#8E8E93"),
    ]
}
