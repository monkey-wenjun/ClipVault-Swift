import AppKit
import SwiftUI
import Carbon.HIToolbox

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("appLanguageDidChange")
}

/// 包装根视图，使其随 AppSettings 变化而重新评估。
/// 实际主题由 NSApp.appearance 控制，这里不覆盖 preferredColorScheme 以避免冲突。
struct AppearanceRoot<Content: View>: View {
    @ObservedObject var settings: AppSettings
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .id(settings.appearance.rawValue)
    }
}

/// 一条可配置的键盘快捷键
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    /// NSEvent.ModifierFlags.rawValue 中 cmd/shift/option/control 的子集
    var modifiers: UInt

    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    var displayString: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + Self.keyString(for: keyCode)
    }

    /// 用当前键盘布局把 keyCode 转成可读字符
    static func keyString(for keyCode: UInt16) -> String {
        guard let layoutData = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(layoutData, kTISPropertyUnicodeKeyLayoutData) else {
            return "(\(keyCode))"
        }
        let layout = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
        let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(layout), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(keyboardLayout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &deadKeyState, 4, &length, &chars)
        guard status == noErr, length > 0 else { return "(\(keyCode))" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

enum HotKeyAction: String, CaseIterable {
    case showPanel
    case search
    case nextPinboard
    case prevPinboard
    /// 上传剪贴板图片到默认图床
    case uploadToImageHosting
    /// 全选：只在面板打开时生效，不做全局注册（全局 ⌘A 会劫持所有应用）
    case selectAll

    /// 可在设置页中自定义的快捷键（上下集合切换保留默认，不在设置中展示）
    static var configurableCases: [HotKeyAction] {
        allCases.filter { $0 != .nextPinboard && $0 != .prevPinboard }
    }

    var title: String {
        switch self {
        case .showPanel: return NSLocalizedString("启动 ClipVault", comment: "Shortcut action: show ClipVault")
        case .search: return NSLocalizedString("搜索", comment: "Shortcut action: search")
        case .nextPinboard: return NSLocalizedString("显示下一个集合", comment: "Shortcut action: next pinboard")
        case .prevPinboard: return NSLocalizedString("显示上一个集合", comment: "Shortcut action: previous pinboard")
        case .uploadToImageHosting: return NSLocalizedString("上传图片到图床", comment: "Shortcut action: upload image to hosting")
        case .selectAll: return NSLocalizedString("全选（面板打开时）", comment: "Shortcut action: select all when panel is open")
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return NSLocalizedString("跟随系统", comment: "Appearance: system")
        case .light: return NSLocalizedString("浅色", comment: "Appearance: light")
        case .dark: return NSLocalizedString("深色", comment: "Appearance: dark")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum PanelPosition: String, CaseIterable, Identifiable {
    case bottom
    case top
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: return NSLocalizedString("底部", comment: "Panel position: bottom")
        case .top: return NSLocalizedString("顶部", comment: "Panel position: top")
        case .left: return NSLocalizedString("左侧", comment: "Panel position: left")
        case .right: return NSLocalizedString("右侧", comment: "Panel position: right")
        }
    }

    /// 是否为垂直边栏（左/右）
    var isVertical: Bool {
        self == .left || self == .right
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return NSLocalizedString("跟随系统", comment: "Language: system")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "zh-Hans"
        case .en: return "en"
        }
    }
}

enum Retention: Int, CaseIterable, Identifiable {
    case day = 1
    case week = 7
    case month = 30
    case year = 365
    case forever = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .day: return NSLocalizedString("天", comment: "Retention unit: days")
        case .week: return NSLocalizedString("周", comment: "Retention unit: weeks")
        case .month: return NSLocalizedString("个月", comment: "Retention unit: months")
        case .year: return NSLocalizedString("年", comment: "Retention unit: years")
        case .forever: return NSLocalizedString("永久", comment: "Retention unit: forever")
        }
    }
}

/// 粘贴行为：直接粘贴到活动应用，还是只写入剪贴板
enum PasteTarget: String, CaseIterable, Identifiable {
    case activeApp
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activeApp: return NSLocalizedString("到当前活动应用", comment: "Paste target: active app")
        case .clipboard: return NSLocalizedString("到剪贴板", comment: "Paste target: clipboard")
        }
    }

    var subtitle: String {
        switch self {
        case .activeApp: return NSLocalizedString("将选定的项目直接粘贴到您当前正在使用的应用程序中。", comment: "Paste target active app description")
        case .clipboard: return NSLocalizedString("将选定的项目复制到系统剪贴板，以便稍后手动粘贴。", comment: "Paste target clipboard description")
        }
    }
}

/// 统一的应用设置，UserDefaults 持久化。
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    static let defaultShortcuts: [HotKeyAction: Shortcut] = [
        .showPanel: Shortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue),
        .search: Shortcut(keyCode: UInt16(kVK_ANSI_F), modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue),
        .uploadToImageHosting: Shortcut(keyCode: UInt16(kVK_ANSI_P), modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue),
        .selectAll: Shortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: NSEvent.ModifierFlags([.command]).rawValue),
    ]

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    @Published var runInBackground: Bool {
        didSet { defaults.set(runInBackground, forKey: "runInBackground") }
    }
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appAppearance") }
    }
    @Published var panelPosition: PanelPosition {
        didSet { defaults.set(panelPosition.rawValue, forKey: "panelPosition") }
    }
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "appLanguage")
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        }
    }
    @Published var retention: Retention {
        didSet { defaults.set(retention.rawValue, forKey: "retentionDays") }
    }
    @Published var pasteTarget: PasteTarget {
        didSet { defaults.set(pasteTarget.rawValue, forKey: "pasteTarget") }
    }
    @Published var ignoreConfidential: Bool {
        didSet { defaults.set(ignoreConfidential, forKey: "ignoreConfidential") }
    }
    @Published var ignoreTransient: Bool {
        didSet { defaults.set(ignoreTransient, forKey: "ignoreTransient") }
    }
    @Published var ignoredBundleIDs: [String] {
        didSet { defaults.set(ignoredBundleIDs, forKey: "ignoredBundleIDs") }
    }
    @Published var syncEnabled: Bool {
        didSet { defaults.set(syncEnabled, forKey: "syncEnabled") }
    }
    @Published var syncFolderPath: String {
        didSet { defaults.set(syncFolderPath, forKey: "syncFolderPath") }
    }
    @Published var syncFolderBookmark: Data? {
        didSet { defaults.set(syncFolderBookmark, forKey: "syncFolderBookmark") }
    }
    @Published var imageHostingEnabled: Bool {
        didSet { defaults.set(imageHostingEnabled, forKey: "imageHostingEnabled") }
    }
    @Published var imageHostingAutoUpload: Bool {
        didSet { defaults.set(imageHostingAutoUpload, forKey: "imageHostingAutoUpload") }
    }
    @Published var imageHostingGenerateMarkdown: Bool {
        didSet { defaults.set(imageHostingGenerateMarkdown, forKey: "imageHostingGenerateMarkdown") }
    }
    @Published var imageHostingRenameEnabled: Bool {
        didSet { defaults.set(imageHostingRenameEnabled, forKey: "imageHostingRenameEnabled") }
    }
    @Published var imageHostingRenameRule: ImageHostingRenameRule {
        didSet { defaults.set(imageHostingRenameRule.rawValue, forKey: "imageHostingRenameRule") }
    }
    @Published var imageHostingCustomPrefix: String {
        didSet { defaults.set(imageHostingCustomPrefix, forKey: "imageHostingCustomPrefix") }
    }
    @Published var imageHostingDefaultID: String? {
        didSet { defaults.set(imageHostingDefaultID, forKey: "imageHostingDefaultID") }
    }
    @Published var imageHostingConfigs: [ImageHostingConfig] {
        didSet {
            // 删除已从列表移除的配置的凭证
            let newIDs = Set(imageHostingConfigs.map(\.id))
            for oldConfig in oldValue where !newIDs.contains(oldConfig.id) {
                KeychainService.deleteCredentials(for: oldConfig.id)
            }
            saveImageHostingConfigs()
        }
    }
    @Published private(set) var shortcuts: [HotKeyAction: Shortcut] {
        didSet { saveShortcuts() }
    }

    init() {
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        runInBackground = defaults.object(forKey: "runInBackground") as? Bool ?? true
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appAppearance") ?? "") ?? .system
        panelPosition = PanelPosition(rawValue: defaults.string(forKey: "panelPosition") ?? "") ?? .bottom
        language = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
        retention = Retention(rawValue: defaults.integer(forKey: "retentionDays")) ?? .forever
        pasteTarget = PasteTarget(rawValue: defaults.string(forKey: "pasteTarget") ?? "") ?? .activeApp
        // 默认开启：不保存机密/瞬时内容
        ignoreConfidential = defaults.object(forKey: "ignoreConfidential") as? Bool ?? true
        ignoreTransient = defaults.object(forKey: "ignoreTransient") as? Bool ?? true
        ignoredBundleIDs = defaults.stringArray(forKey: "ignoredBundleIDs") ?? []
        syncEnabled = defaults.bool(forKey: "syncEnabled")
        syncFolderPath = defaults.string(forKey: "syncFolderPath") ?? AppSettings.defaultSyncFolder
        syncFolderBookmark = defaults.data(forKey: "syncFolderBookmark")
        imageHostingEnabled = defaults.object(forKey: "imageHostingEnabled") as? Bool ?? false
        imageHostingAutoUpload = defaults.object(forKey: "imageHostingAutoUpload") as? Bool ?? true
        imageHostingGenerateMarkdown = defaults.object(forKey: "imageHostingGenerateMarkdown") as? Bool ?? true
        imageHostingRenameEnabled = defaults.object(forKey: "imageHostingRenameEnabled") as? Bool ?? true
        imageHostingRenameRule = ImageHostingRenameRule(rawValue: defaults.string(forKey: "imageHostingRenameRule") ?? "") ?? .timestamp
        imageHostingCustomPrefix = defaults.string(forKey: "imageHostingCustomPrefix") ?? "clip"
        imageHostingDefaultID = defaults.string(forKey: "imageHostingDefaultID")
        // 先迁移旧版加密凭证到 Keychain，再加载
        Self.migrateCredentialsIfNeeded()
        imageHostingConfigs = Self.loadImageHostingConfigs()

        var loaded: [HotKeyAction: Shortcut] = [:]
        for action in HotKeyAction.allCases {
            if let data = defaults.data(forKey: "shortcut.\(action.rawValue)"),
               let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) {
                loaded[action] = shortcut
            } else {
                loaded[action] = Self.defaultShortcuts[action]
            }
        }
        shortcuts = loaded
    }

    func shortcut(for action: HotKeyAction) -> Shortcut? {
        shortcuts[action]
    }

    func setShortcut(_ shortcut: Shortcut?, for action: HotKeyAction) {
        shortcuts[action] = shortcut
    }

    func resetShortcuts() {
        shortcuts = Self.defaultShortcuts
    }

    /// 默认同步目录使用应用容器内的 Application Support/ClipVault/Sync。
    /// 沙盒外直接访问 iCloud Drive 路径会被拒绝，用户如需要同步到 iCloud Drive 等外部目录，
    /// 必须通过文件选择器授权并保存安全作用域书签。
    static var defaultSyncFolder: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("ClipVault/Sync").path
    }

    private func saveShortcuts() {
        for action in HotKeyAction.allCases {
            if let shortcut = shortcuts[action],
               let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: "shortcut.\(action.rawValue)")
            } else {
                defaults.removeObject(forKey: "shortcut.\(action.rawValue)")
            }
        }
    }

    private func saveImageHostingConfigs() {
        // 1. 把凭证写入 Keychain
        for config in imageHostingConfigs {
            if !config.accessKey.isEmpty {
                _ = KeychainService.saveCredential(configID: config.id, field: .accessKey, value: config.accessKey)
            }
            if !config.secretKey.isEmpty {
                _ = KeychainService.saveCredential(configID: config.id, field: .secretKey, value: config.secretKey)
            }
        }
        // 2. 剥离凭证后写入 UserDefaults，避免敏感信息以任何形式留在 plist
        let stripped = imageHostingConfigs.map { config -> ImageHostingConfig in
            var copy = config
            copy.accessKey = ""
            copy.secretKey = ""
            return copy
        }
        if let data = try? JSONEncoder().encode(stripped) {
            defaults.set(data, forKey: "imageHostingConfigs")
        }
    }

    private static func loadImageHostingConfigs() -> [ImageHostingConfig] {
        guard let data = UserDefaults.standard.data(forKey: "imageHostingConfigs"),
              var configs = try? JSONDecoder().decode([ImageHostingConfig].self, from: data) else {
            return []
        }
        for i in configs.indices {
            if let accessKey = KeychainService.loadCredential(configID: configs[i].id, field: .accessKey) {
                configs[i].accessKey = accessKey
            }
            if let secretKey = KeychainService.loadCredential(configID: configs[i].id, field: .secretKey) {
                configs[i].secretKey = secretKey
            }
        }
        return configs
    }

    private static func loadRawImageHostingConfigs() -> [ImageHostingConfig] {
        guard let data = UserDefaults.standard.data(forKey: "imageHostingConfigs"),
              let configs = try? JSONDecoder().decode([ImageHostingConfig].self, from: data) else {
            return []
        }
        return configs
    }

    /// 把旧版 AES 加密后存在 UserDefaults 中的凭证迁移到 Keychain。
    /// 迁移后 UserDefaults 中只保留剥离凭证的配置副本。
    private static func migrateCredentialsIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "imageHostingCredentialsMigratedToKeychain"
        guard !defaults.bool(forKey: key) else { return }

        var configs = Self.loadRawImageHostingConfigs()
        var changed = false
        for i in configs.indices {
            var config = configs[i]
            if !config.accessKey.isEmpty {
                let plain = ImageHostingCrypto.isEncrypted(config.accessKey)
                    ? ImageHostingCrypto.decrypt(config.accessKey)
                    : config.accessKey
                if KeychainService.saveCredential(configID: config.id, field: .accessKey, value: plain) {
                    config.accessKey = ""
                    changed = true
                }
            }
            if !config.secretKey.isEmpty {
                let plain = ImageHostingCrypto.isEncrypted(config.secretKey)
                    ? ImageHostingCrypto.decrypt(config.secretKey)
                    : config.secretKey
                if KeychainService.saveCredential(configID: config.id, field: .secretKey, value: plain) {
                    config.secretKey = ""
                    changed = true
                }
            }
            configs[i] = config
        }

        if changed, let data = try? JSONEncoder().encode(configs) {
            defaults.set(data, forKey: "imageHostingConfigs")
        }
        defaults.set(true, forKey: key)
    }
}
