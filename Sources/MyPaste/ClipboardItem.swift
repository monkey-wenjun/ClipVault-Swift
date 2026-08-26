import AppKit

struct ClipboardItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text
        case color
        case image
        case file

        var title: String {
            switch self {
            case .text: return NSLocalizedString("文本", comment: "Text item kind")
            case .color: return NSLocalizedString("颜色", comment: "Color item kind")
            case .image: return NSLocalizedString("图片", comment: "Image item kind")
            case .file: return NSLocalizedString("文件", comment: "File item kind")
            }
        }
    }

    var id: UUID
    var kind: Kind
    /// 文本内容；kind == .color 时为十六进制色值（如 "#110674"），kind == .file 时为文件路径
    var text: String?
    /// 图片文件名（存储在 Application Support/ClipVault/images 下）
    var imageFile: String?
    /// 文件大小（字节），仅 kind == .file 时有效
    var fileSize: Int?
    var createdAt: Date
    var sourceBundleID: String?
    /// 用户自定义的卡片标题，用于快速识别内容；为空时显示 kind.title
    var customTitle: String?
    /// 仅用于「归因类型」等模板条目：粘贴时前后拼接的字符串
    var prefix: String?
    var suffix: String?

    /// 卡片头带展示的标题：优先使用用户自定义名称
    var displayTitle: String {
        customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? kind.title
    }

    /// 粘贴时写入剪贴板的文本
    var pasteContent: String {
        if let prefix, let suffix, let text { return prefix + text + suffix }
        return text ?? ""
    }

    var footer: String {
        switch kind {
        case .image: return NSLocalizedString("图片", comment: "Image item kind")
        case .file:
            if let size = fileSize {
                return String(format: NSLocalizedString("%@ · 文件", comment: "File size footer"), ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            return NSLocalizedString("文件", comment: "File item kind")
        case .color, .text:
            return String(format: NSLocalizedString("%d 个字符", comment: "Character count footer"), (text ?? "").count)
        }
    }

    /// 文件/文件夹展示名（仅 kind == .file）
    var fileDisplayName: String {
        guard kind == .file, let path = text else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var sourceIcon: NSImage? {
        guard let bundleID = sourceBundleID else { return nil }
        return AppIconCache.icon(for: bundleID)
    }

    /// 来源应用图标的主色（卡片头带底色）
    var sourceColor: NSColor? {
        guard let bundleID = sourceBundleID else { return nil }
        return IconColorCache.color(for: bundleID)
    }

    /// 相对时间（"5 分钟前"），带缓存：RelativeDateTimeFormatter 很慢，不能每次渲染都算
    var relativeTime: String {
        RelativeTimeCache.string(for: id, date: createdAt)
    }
}

enum RelativeTimeCache {
    private static var cache: [UUID: (computedAt: Date, text: String)] = [:]
    private static let lock = NSLock()
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func string(for id: UUID, date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[id], Date().timeIntervalSince(cached.computedAt) < 60 {
            return cached.text
        }
        let text = formatter.localizedString(for: date, relativeTo: Date())
        cache[id] = (Date(), text)
        return text
    }
}

/// 来源应用图标缓存：避免每次渲染都调用 NSWorkspace
enum AppIconCache {
    private static var cache: [String: NSImage?] = [:]
    private static let lock = NSLock()

    static func icon(for bundleID: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }
}

/// 应用图标主色缓存：只取高饱和彩色像素的平均色（过滤白底/灰底），
/// 输出前限制亮度区间保证头带白字可读
enum IconColorCache {
    private static var cache: [String: NSColor?] = [:]
    private static let lock = NSLock()

    static func color(for bundleID: String) -> NSColor? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[bundleID] { return cached }
        let color = compute(bundleID)
        cache[bundleID] = color
        return color
    }

    private static func compute(_ bundleID: String) -> NSColor? {
        guard let icon = AppIconCache.icon(for: bundleID) else { return nil }
        let px = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let data = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: px, height: px).fill()
        icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()

        var r = 0.0, g = 0.0, b = 0.0, n = 0.0        // 高饱和彩色像素
        var ar = 0.0, ag = 0.0, ab = 0.0, an = 0.0    // 全部不透明像素（兜底）
        for y in 0 ..< px {
            for x in 0 ..< px {
                let i = y * rep.bytesPerRow + x * 4
                guard data[i + 3] > 40 else { continue }
                let pr = Double(data[i]) / 255
                let pg = Double(data[i + 1]) / 255
                let pb = Double(data[i + 2]) / 255
                ar += pr; ag += pg; ab += pb; an += 1
                let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
                let saturation = mx == 0 ? 0 : (mx - mn) / mx
                // 只统计鲜亮的彩色像素（品牌色），跳过白底/灰底/黑底
                if saturation > 0.35, mx > 0.3 {
                    r += pr; g += pg; b += pb; n += 1
                }
            }
        }
        guard an > 0 else { return nil }
        let base: NSColor
        if n > 0 {
            base = NSColor(red: r / n, green: g / n, blue: b / n, alpha: 1)
        } else {
            // 图标本身是灰度（如终端）：整体平均，作为灰色头带
            base = NSColor(red: ar / an, green: ag / an, blue: ab / an, alpha: 1)
        }
        guard let rgb = base.usingColorSpace(.deviceRGB) else { return base }
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
        if n > 0 {
            // 彩色图标：保持鲜亮，亮度落在白字可读的区间
            return NSColor(hue: h, saturation: max(s, 0.55),
                           brightness: min(max(br, 0.5), 0.75), alpha: 1)
        }
        return NSColor(hue: h, saturation: s, brightness: min(max(br, 0.3), 0.5), alpha: 1)
    }
}

/// 图片缓存（按条目 id）：解密后的 NSImage 常驻内存，异步预解码避免主线程卡顿
enum CardImageCache {
    private static let cache = NSCache<NSString, NSImage>()
    private static let decodeQueue = DispatchQueue(label: "com.clipvault.imagedecode", qos: .userInitiated)
    private static var pendingRequests = Set<UUID>()

    static func image(forID id: UUID) -> NSImage? {
        cache.object(forKey: id.uuidString as NSString)
    }

    static func set(_ image: NSImage, forID id: UUID) {
        cache.setObject(image, forKey: id.uuidString as NSString)
    }

    /// 异步预加载并解码图片，完成后自动缓存
    static func preload(id: UUID, dataLoader: @escaping () -> Data?) {
        let idString = id.uuidString
        guard cache.object(forKey: idString as NSString) == nil, !pendingRequests.contains(id) else { return }
        pendingRequests.insert(id)
        decodeQueue.async {
            guard let data = dataLoader(),
                  let image = NSImage(data: data) else {
                Task { @MainActor in pendingRequests.remove(id) }
                return
            }
            let size = image.size
            if size.width > 0, size.height > 0 {
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(size.width * 2),
                    pixelsHigh: Int(size.height * 2),
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )
                if let rep {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    image.draw(in: NSRect(origin: .zero, size: NSSize(width: size.width * 2, height: size.height * 2)))
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            Task { @MainActor in
                pendingRequests.remove(id)
                cache.setObject(image, forKey: idString as NSString)
                NotificationCenter.default.post(name: .cardImageDidLoad, object: id)
            }
        }
    }
}

extension Notification.Name {
    static let cardImageDidLoad = Notification.Name("cardImageDidLoad")
}

/// 搜索用小写文本缓存：把带 locale 的 localizedCaseInsensitiveContains
/// 退化为普通子串匹配，量级大时快一个数量级
enum SearchTextCache {
    private static var cache: [UUID: String] = [:]
    private static let lock = NSLock()

    static func lowercaseText(for item: ClipboardItem) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[item.id] { return cached }
        let text = (item.text ?? "").lowercased()
        cache[item.id] = text
        return text
    }
}
