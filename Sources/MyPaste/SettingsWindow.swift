import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings
    private let store: HistoryStore
    private let syncController: SyncController
    var onShortcutsChanged: (() -> Void)?

    var isVisible: Bool { window?.isVisible == true }

    init(settings: AppSettings, store: HistoryStore, syncController: SyncController) {
        self.settings = settings
        self.store = store
        self.syncController = syncController
    }

    func show() {
        if window == nil { makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        let view = AppearanceRoot(settings: self.settings) {
            SettingsView(settings: self.settings,
                         syncController: self.syncController,
                         onSyncNow: { [weak self] in self?.syncController.syncCycle() },
                         onClearHistory: { [weak self] in self?.store.clear() },
                         onShortcutsChanged: { [weak self] in self?.onShortcutsChanged?() })
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = NSLocalizedString("设置", comment: "Settings window title")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 780, height: 560))
        window.isReleasedWhenClosed = false
        self.window = window
    }
}

// MARK: - 主视图：左侧边栏 + 右侧内容

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case privacy
    case shortcuts
    case imageHosting
    case sync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return NSLocalizedString("通用", comment: "Settings tab: General")
        case .privacy: return NSLocalizedString("隐私", comment: "Settings tab: Privacy")
        case .shortcuts: return NSLocalizedString("快捷键", comment: "Settings tab: Shortcuts")
        case .imageHosting: return NSLocalizedString("图床", comment: "Settings tab: Image Hosting")
        case .sync: return NSLocalizedString("同步", comment: "Settings tab: Sync")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .privacy: return "hand.raised"
        case .shortcuts: return "keyboard"
        case .imageHosting: return "arrow.up.circle"
        case .sync: return "icloud"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var syncController: SyncController
    var onSyncNow: () -> Void
    var onClearHistory: () -> Void
    var onShortcutsChanged: () -> Void

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(minWidth: 780, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(selectedTab == tab ? .white : .primary)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 190)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(selectedTab.title)
                    .font(.title2).bold()
                switch selectedTab {
                case .general:
                    GeneralTab(settings: settings, onClearHistory: onClearHistory)
                case .privacy:
                    PrivacyTab(settings: settings)
                case .shortcuts:
                    ShortcutsTab(settings: settings, onChanged: onShortcutsChanged)
                case .imageHosting:
                    ImageHostingTab(settings: settings)
                case .sync:
                    SyncTab(settings: settings, syncController: syncController, onSyncNow: onSyncNow)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 区块卡片容器
struct SettingsSection<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 通用

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    var onClearHistory: () -> Void
    @State private var loginItemError: String?

    var body: some View {
        SettingsSection {
            Toggle("登录时打开", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    settings.launchAtLogin = newValue
                    setLoginItem(newValue)
                }
            ))
            Toggle("后台运行（不显示 Dock 图标）", isOn: $settings.runInBackground)
                .help("关闭后 ClipVault 会出现在 Dock 栏")
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.red)
            }
        }

        Text("外观").font(.headline)
        SettingsSection {
            HStack(spacing: 0) {
                ForEach(AppAppearance.allCases) { appearance in
                    Button {
                        settings.appearance = appearance
                    } label: {
                        Text(appearance.title)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(settings.appearance == appearance
                                        ? Color.accentColor
                                        : Color.primary.opacity(0.06))
                            .foregroundStyle(settings.appearance == appearance ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }

        Text("面板位置").font(.headline)
        SettingsSection {
            Picker("面板位置", selection: $settings.panelPosition) {
                ForEach(PanelPosition.allCases) { position in
                    Text(position.title).tag(position)
                }
            }
            .pickerStyle(.segmented)
            Text("面板将出现在屏幕对应边缘；左右侧会自动调整为竖向布局。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Text("语言").font(.headline)
        SettingsSection {
            Picker("语言", selection: $settings.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.segmented)
            Text("语言设置将在下次启动时生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Text("粘贴项目").font(.headline)
        SettingsSection {
            ForEach(PasteTarget.allCases) { target in
                Button {
                    settings.pasteTarget = target
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: settings.pasteTarget == target
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(settings.pasteTarget == target
                                             ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.title)
                                .foregroundStyle(.primary)
                            Text(target.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }

        Text("保留历史").font(.headline)
        SettingsSection {
            Slider(
                value: Binding(
                    get: { Double(Retention.allCases.firstIndex(of: settings.retention) ?? 0) },
                    set: { settings.retention = Retention.allCases[Int($0.rounded())] }
                ),
                in: 0 ... Double(Retention.allCases.count - 1),
                step: 1
            )
            HStack {
                ForEach(Retention.allCases) { retention in
                    Text(retention.title)
                        .font(.caption)
                        .foregroundStyle(retention == settings.retention ? .primary : .secondary)
                    if retention != Retention.allCases.last { Spacer() }
                }
            }
            HStack {
                Spacer()
                Button("删除历史…") {
                    onClearHistory()
                }
            }
        }
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = String(format: NSLocalizedString("设置登录项失败：%@", comment: "Login item setup failed"), error.localizedDescription)
        }
    }
}

// MARK: - 隐私

private struct PrivacyTab: View {
    @ObservedObject var settings: AppSettings
    @State private var selection: String?
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        SettingsSection {
            Toggle("忽略机密内容", isOn: $settings.ignoreConfidential)
            Text("在检测到时不保存密码和敏感数据。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("忽略瞬时内容", isOn: $settings.ignoreTransient)
            Text("不保存其他应用程序生成的临时数据。")
                .font(.caption).foregroundStyle(.secondary)
        }

        Text("权限").font(.headline)
        SettingsSection {
            HStack(spacing: 12) {
                Image(systemName: accessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .font(.system(size: 24))
                    .foregroundStyle(accessibilityTrusted ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("辅助功能权限")
                        .font(.system(size: 13, weight: .medium))
                    Text("通过模拟 ⌘V 将选中的剪贴板内容自动粘贴到当前应用；仅在您选择「粘贴到当前活动应用」时触发。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if accessibilityTrusted {
                    Label("已授权", systemImage: "checkmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                } else {
                    Button("打开系统设置…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            .onAppear { accessibilityTrusted = AXIsProcessTrusted() }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                accessibilityTrusted = AXIsProcessTrusted()
            }
        }

        Text("忽略应用程序").font(.headline)
        Text("不保存从以下应用程序复制的内容。")
            .font(.caption).foregroundStyle(.secondary)
        SettingsSection {
            List(selection: $selection) {
                ForEach(settings.ignoredBundleIDs, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        if let icon = icon(for: bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        Text(appName(for: bundleID))
                    }
                    .tag(bundleID)
                }
                .onDelete { offsets in
                    settings.ignoredBundleIDs.remove(atOffsets: offsets)
                }
            }
            .frame(minHeight: 120)
            .scrollContentBackground(.hidden)

            HStack {
                Button("＋") { pickApp() }
                Button("－") {
                    if let selection {
                        settings.ignoredBundleIDs.removeAll { $0 == selection }
                        self.selection = nil
                    }
                }
                .disabled(selection == nil)
                Spacer()
            }
        }
    }

    private func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return url.deletingPathExtension().lastPathComponent
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier,
              !settings.ignoredBundleIDs.contains(bundleID) else { return }
        settings.ignoredBundleIDs.append(bundleID)
    }
}

// MARK: - 快捷键

private struct ShortcutsTab: View {
    @ObservedObject var settings: AppSettings
    var onChanged: () -> Void

    var body: some View {
        SettingsSection {
            ForEach(Array(HotKeyAction.configurableCases.enumerated()), id: \.element) { index, action in
                if index > 0 { Divider() }
                HStack {
                    Text(action.title)
                    Spacer()
                    ShortcutRecorder(shortcut: Binding(
                        get: { settings.shortcut(for: action) },
                        set: { newValue in
                            settings.setShortcut(newValue, for: action)
                            onChanged()
                        }
                    ))
                }
            }
        }
        Text("快速粘贴：⌘ Command + 1…9（面板打开时）")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("将快捷方式重置为默认…") {
                settings.resetShortcuts()
                onChanged()
            }
        }
    }
}

// MARK: - 同步

private struct SyncTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var syncController: SyncController
    var onSyncNow: () -> Void

    private var statusText: String {
        switch syncController.status {
        case .idle:
            return settings.syncEnabled ? NSLocalizedString("尚未开始同步", comment: "Sync not started") : NSLocalizedString("同步未启用", comment: "Sync disabled")
        case .syncing:
            return NSLocalizedString("同步中…", comment: "Syncing")
        case .succeeded(let date):
            return String(format: NSLocalizedString("上次同步成功：%@", comment: "Last sync succeeded"), Self.timeFormatter.string(from: date))
        case .failed(let message):
            return String(format: NSLocalizedString("同步失败：%@", comment: "Sync failed"), message)
        }
    }

    private var statusColor: Color {
        switch syncController.status {
        case .failed:
            return .red
        case .succeeded:
            return .green
        default:
            return .secondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        SettingsSection {
            Toggle("启用同步", isOn: $settings.syncEnabled)
            Divider()
            HStack {
                TextField("同步目录", text: $settings.syncFolderPath)
                    .textFieldStyle(.roundedBorder)
                Button("选择…") { pickFolder() }
            }
            Text("默认使用 iCloud Drive 下的 ClipVault 文件夹。历史与集合按条目合并，删除操作不会同步。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if case .syncing = syncController.status {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            HStack {
                Spacer()
                Button("立即同步") { onSyncNow() }
                    .disabled(!settings.syncEnabled || isSyncing)
            }
        }
    }

    private var isSyncing: Bool {
        if case .syncing = syncController.status { return true }
        return false
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.syncFolderPath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.syncFolderPath = url.path

        // 沙盒下需要保存安全作用域书签才能跨启动访问该目录
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            settings.syncFolderBookmark = bookmark
        } catch {
            settings.syncFolderBookmark = nil
        }
    }
}

// MARK: - 图床

private struct ImageHostingTab: View {
    @ObservedObject var settings: AppSettings
    @State private var showingEditor = false
    @State private var editingConfig: ImageHostingConfig?
    @State private var draft = ImageHostingConfig(name: "", provider: .aliyun)
    @State private var testing = false
    @State private var alertMessage: String?
    @State private var showAlert = false

    var body: some View {
        SettingsSection {
            Toggle("启用图床", isOn: $settings.imageHostingEnabled)
            Divider()
            Toggle("复制 Markdown 图片链接", isOn: $settings.imageHostingGenerateMarkdown)
            Divider()
            Toggle("上传前重命名", isOn: $settings.imageHostingRenameEnabled)
            if settings.imageHostingRenameEnabled {
                Picker("规则", selection: $settings.imageHostingRenameRule) {
                    ForEach(ImageHostingRenameRule.allCases) { rule in
                        Text(rule.displayName).tag(rule)
                    }
                }
                if settings.imageHostingRenameRule == .customPrefix {
                    TextField("前缀", text: $settings.imageHostingCustomPrefix)
                }
            }
        }

        Text("图床配置").font(.headline)
        SettingsSection {
            if settings.imageHostingConfigs.isEmpty {
                Text("暂无配置，点击右下角“新增”添加一个图床。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.imageHostingConfigs) { config in
                    HStack(spacing: 10) {
                        Image(systemName: config.provider.iconName)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(config.name).font(.system(size: 13, weight: .medium))
                                if config.id.uuidString == settings.imageHostingDefaultID {
                                    Text("默认")
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                }
                                if !config.isEnabled {
                                    Text("已禁用")
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15), in: Capsule())
                                }
                            }
                            Text("\(config.provider.displayName) · \(config.bucket)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("编辑") { startEditing(config) }
                            .buttonStyle(.borderless)
                        if config.id.uuidString != settings.imageHostingDefaultID {
                            Button("设为默认") { settings.imageHostingDefaultID = config.id.uuidString }
                                .buttonStyle(.borderless)
                        }
                        Button("删除") { delete(config) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Spacer()
                Button("新增") { startAdding() }
            }
        }
        .sheet(isPresented: $showingEditor) {
            ImageHostingEditor(
                draft: $draft,
                isEditing: editingConfig != nil,
                testing: $testing,
                onSave: saveDraft,
                onTest: testDraft
            )
            .frame(minWidth: 460, minHeight: 420)
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定") {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func startAdding() {
        editingConfig = nil
        draft = ImageHostingConfig(name: "", provider: .aliyun)
        showingEditor = true
    }

    private func startEditing(_ config: ImageHostingConfig) {
        editingConfig = config
        draft = ImageHostingConfig(
            id: config.id,
            name: config.name,
            provider: config.provider,
            accessKey: "",
            secretKey: "",
            bucket: config.bucket,
            region: config.region,
            customDomain: config.customDomain,
            pathRule: config.pathRule,
            pathPrefix: config.pathPrefix,
            endpoint: config.endpoint,
            isEnabled: config.isEnabled,
            createdAt: config.createdAt
        )
        showingEditor = true
    }

    private func delete(_ config: ImageHostingConfig) {
        settings.imageHostingConfigs.removeAll { $0.id == config.id }
        if settings.imageHostingDefaultID == config.id.uuidString {
            settings.imageHostingDefaultID = settings.imageHostingConfigs.first?.id.uuidString
        }
    }

    private func saveDraft() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            alertMessage = NSLocalizedString("请输入配置名称", comment: "Please enter config name")
            showAlert = true
            return
        }
        guard !draft.accessKey.isEmpty || editingConfig != nil else {
            alertMessage = NSLocalizedString("请输入 Access Key", comment: "Please enter Access Key")
            showAlert = true
            return
        }
        guard !draft.secretKey.isEmpty || editingConfig != nil else {
            alertMessage = NSLocalizedString("请输入 Secret Key", comment: "Please enter Secret Key")
            showAlert = true
            return
        }
        guard !draft.bucket.isEmpty else {
            alertMessage = NSLocalizedString("请输入 Bucket", comment: "Please enter Bucket")
            showAlert = true
            return
        }
        guard !draft.region.isEmpty else {
            alertMessage = NSLocalizedString("请输入 Region", comment: "Please enter Region")
            showAlert = true
            return
        }

        var config = draft
        config.name = name
        if let original = editingConfig {
            if draft.accessKey.isEmpty { config.accessKey = original.accessKey }
            if draft.secretKey.isEmpty { config.secretKey = original.secretKey }
        }

        if let original = editingConfig,
           let index = settings.imageHostingConfigs.firstIndex(where: { $0.id == original.id }) {
            settings.imageHostingConfigs[index] = config
        } else {
            settings.imageHostingConfigs.append(config)
            if settings.imageHostingDefaultID == nil {
                settings.imageHostingDefaultID = config.id.uuidString
            }
        }
        showingEditor = false
    }

    private func testDraft() async {
        testing = true
        defer { testing = false }

        var config = draft
        config.name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.name.isEmpty { config.name = NSLocalizedString("测试配置", comment: "Default test config name") }
        if let original = editingConfig {
            if config.accessKey.isEmpty { config.accessKey = original.accessKey }
            if config.secretKey.isEmpty { config.secretKey = original.secretKey }
        }

        let testImage = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0x0F, 0x00, 0x00,
            0x01, 0x01, 0x00, 0x05, 0x18, 0xD8, 0xAE, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82,
        ])

        let result = await ImageHostingService.shared.upload(testImage, fileName: "test.png", config: config)
        if result.success, let url = result.url {
            alertMessage = String(format: NSLocalizedString("测试上传成功：%@", comment: "Test upload succeeded"), url)
        } else {
            alertMessage = String(format: NSLocalizedString("测试上传失败：%@", comment: "Test upload failed"), result.error ?? NSLocalizedString("未知错误", comment: "Unknown error"))
        }
        showAlert = true
    }
}

private struct ImageHostingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: ImageHostingConfig
    let isEditing: Bool
    @Binding var testing: Bool
    var onSave: () -> Void
    var onTest: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "编辑图床配置" : "新增图床配置")
                .font(.headline)

            Form {
                TextField("名称", text: $draft.name)
                Picker("厂商", selection: $draft.provider) {
                    ForEach(ImageHostingProvider.implementedCases) { provider in
                        Label(provider.displayName, systemImage: provider.iconName).tag(provider)
                    }
                }
                TextField("Access Key", text: $draft.accessKey)
                SecureField(isEditing ? "Secret Key（留空保留原值）" : "Secret Key", text: $draft.secretKey)
                TextField("Bucket", text: $draft.bucket)
                TextField("Region", text: $draft.region)
                TextField("自定义域名（可选）", text: optionalBinding($draft.customDomain))
                Picker("存储路径", selection: $draft.pathRule) {
                    ForEach(ImageHostingPathRule.allCases) { rule in
                        Text(rule.displayName).tag(rule)
                    }
                }
                if draft.pathRule == .custom {
                    TextField("路径前缀", text: optionalBinding($draft.pathPrefix))
                }
                TextField("Endpoint（可选）", text: optionalBinding($draft.endpoint))
                Toggle("启用", isOn: $draft.isEnabled)
            }

            HStack {
                Spacer()
                Button(testing ? "测试中…" : "测试") {
                    Task { await onTest() }
                }
                .disabled(testing)
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { onSave() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }

    private func optionalBinding(_ value: Binding<String?>) -> Binding<String> {
        Binding<String>(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

// MARK: - 关于（独立小窗口，从菜单栏菜单打开）

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection {
                HStack(spacing: 12) {
                    if let path = Bundle.main.path(forResource: "ClipVault", ofType: "icns"),
                       let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: 48, height: 48)
                    } else {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ClipVault")
                            .font(.headline)
                        Text("版本 \(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsSection {
                HStack {
                    Text("作者")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("阿文")
                }
                Divider()
                Link(destination: URL(string: "https://www.awen.me")!) {
                    HStack {
                        Label("博客", systemImage: "globe")
                        Spacer()
                        Text("www.awen.me")
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                Link(destination: URL(string: "mailto:hi@awen.me")!) {
                    HStack {
                        Label("邮箱", systemImage: "envelope")
                        Spacer()
                        Text("hi@awen.me")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - 快捷键录制器

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onChange = { shortcut = $0 }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.shortcut = shortcut
    }
}

final class ShortcutRecorderNSView: NSView {
    var shortcut: Shortcut? {
        didSet { updateTitle() }
    }
    var onChange: ((Shortcut?) -> Void)?

    private let button = NSButton(title: "", target: nil, action: nil)
    private var recording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(toggleRecording)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
        ])
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func toggleRecording() {
        recording.toggle()
        if recording {
            window?.makeFirstResponder(self)
        }
        updateTitle()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Esc 取消
            recording = false
            updateTitle()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete 清除
            shortcut = nil
            recording = false
            onChange?(nil)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !flags.isEmpty else { return } // 必须带修饰键
        let new = Shortcut(keyCode: event.keyCode, modifiers: flags.rawValue)
        shortcut = new
        recording = false
        onChange?(new)
    }

    override func flagsChanged(with event: NSEvent) {
        // 录制中只按了修饰键时给出即时反馈
        if recording {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            var s = ""
            if flags.contains(.control) { s += "⌃" }
            if flags.contains(.option) { s += "⌥" }
            if flags.contains(.shift) { s += "⇧" }
            if flags.contains(.command) { s += "⌘" }
            button.title = s.isEmpty ? "输入快捷键…" : s + "…"
        }
    }

    override func resignFirstResponder() -> Bool {
        if recording {
            recording = false
            updateTitle()
        }
        return super.resignFirstResponder()
    }

    private func updateTitle() {
        if recording {
            button.title = NSLocalizedString("输入快捷键…", comment: "Shortcut recording button title")
        } else if let shortcut {
            button.title = shortcut.displayString
        } else {
            button.title = NSLocalizedString("点击录制", comment: "Shortcut record button title")
        }
    }
}
