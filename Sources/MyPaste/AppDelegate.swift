import AppKit
import SwiftUI
import UserNotifications
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var settings: AppSettings!
    private var store: HistoryStore!
    private var monitor: ClipboardMonitor!
    private var panelController: PanelController!
    private var pasteService: PasteService!
    private var syncController: SyncController!
    private var settingsWindow: SettingsWindowController!
    private var textEditor: TextEditorWindowController!
    private var jsonViewer: JSONViewerWindowController!
    private var textPreview: TextPreviewWindowController!
    private var imagePreview: ImagePreviewWindowController!
    private let hotKeys = HotKeyManager()
    private var statusItem: NSStatusItem!
    private var rightClickMonitor: Any?
    private var aboutWindow: NSWindow?
    private var pruneTimer: Timer?
    private var onboardingWindow: OnboardingWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        // 尽早应用后台运行设置，避免创建窗口后再切换激活策略失效
        applyRunInBackground()

        store = HistoryStore()
        if let tagConfig = CloseTicketTagger.loadConfig() {
            store.syncAttributionPinboard(with: tagConfig)
        }
        monitor = ClipboardMonitor(store: store, settings: settings)
        monitor.start()
        pasteService = PasteService(store: store, monitor: monitor, settings: settings)
        syncController = SyncController(store: store, settings: settings)
        syncController.start()
        settingsWindow = SettingsWindowController(settings: settings, store: store,
                                                  syncController: syncController)
        textEditor = TextEditorWindowController()
        jsonViewer = JSONViewerWindowController(monitor: monitor)
        textPreview = TextPreviewWindowController(monitor: monitor)
        imagePreview = ImagePreviewWindowController()
        textEditor.onCreate = { [weak self] text in
            self?.store.addText(text, sourceBundleID: nil)
        }

        panelController = PanelController(store: store, settings: settings) { [weak self] item, target in
            self?.pasteService.paste(item, to: target)
        }
        panelController.shouldStayVisibleWhenPanelResignsKey = { [weak self] in
            guard let self else { return false }
            return self.jsonViewer.isVisible || self.textPreview.isVisible || self.imagePreview.isVisible
        }
        panelController.shouldSuppressKeyHandling = { [weak self] in
            guard let self else { return false }
            return self.jsonViewer.isVisible || self.textPreview.isVisible || self.imagePreview.isVisible || self.textEditor.isVisible || self.settingsWindow.isVisible
        }
        panelController.viewModel.jsonViewerHandler = { [weak self] item in
            self?.jsonViewer.show(item: item)
        }
        panelController.viewModel.jsonViewerToggleHandler = { [weak self] in
            guard let self else { return false }
            if self.jsonViewer.isVisible {
                self.jsonViewer.hide()
                self.panelController.refocus()
                return true
            }
            return false
        }
        panelController.viewModel.textPreviewHandler = { [weak self] item in
            self?.textPreview.show(item: item) { [weak self] id, text in
                self?.store.updateText(id: id, text: text)
                for board in self?.store.pinboards ?? [] where board.items.contains(where: { $0.id == id }) {
                    self?.store.updatePinboardText(pinboardID: board.id, itemID: id, text: text)
                }
            }
        }
        panelController.viewModel.textPreviewToggleHandler = { [weak self] in
            guard let self else { return false }
            if self.textPreview.isVisible {
                self.textPreview.hide()
                self.panelController.refocus()
                return true
            }
            return false
        }

        panelController.viewModel.imagePreviewHandler = { [weak self] item in
            guard let image = self?.panelController.viewModel.cardImage(for: item) else { return }
            self?.imagePreview.show(image: image)
        }
        panelController.viewModel.imagePreviewToggleHandler = { [weak self] in
            guard let self else { return false }
            if self.imagePreview.isVisible {
                self.imagePreview.hide()
                self.panelController.refocus()
                return true
            }
            return false
        }

        settingsWindow.onShortcutsChanged = { [weak self] in
            self?.reloadHotKeys()
        }
        panelController.menuProvider = { [weak self] in
            self?.buildMenu() ?? NSMenu()
        }

        hotKeys.handler = { [weak self] action in
            Task { @MainActor [weak self] in self?.handleHotKey(action) }
        }
        reloadHotKeys()

        setupStatusItem()
        applyRetention()
        // 每天执行一次保留策略清理
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyRetention() }
        }

        promptAccessibilityIfNeeded()
        requestNotificationAuthorization()
        NSApp.mainMenu = buildMainMenu()
        applyAppearance(settings.appearance)
        applyLanguage()
        observeSettingsChanges()
        observeSystemAppearanceChanges()
        showOnboardingIfNeeded()
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        let nsAppearance = appearance.nsAppearance
        NSApp.appearance = nsAppearance
        NSApp.windows.forEach { window in
            window.appearance = nsAppearance
            window.contentView?.needsLayout = true
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
        }
    }

    private func applyRunInBackground() {
        let targetPolicy: NSApplication.ActivationPolicy = settings.runInBackground ? .accessory : .regular
        guard NSApp.activationPolicy() != targetPolicy else { return }

        // 切换激活策略前先把可见窗口隐藏，否则 macOS 可能不生效或导致 Dock 图标残留
        let visibleWindows = NSApp.windows.filter { $0.isVisible }
        let keyWindow = NSApp.keyWindow
        visibleWindows.forEach { $0.orderOut(nil) }

        let success = NSApp.setActivationPolicy(targetPolicy)

        // 恢复刚才隐藏的窗口
        visibleWindows.forEach { window in
            if targetPolicy == .accessory {
                window.orderFrontRegardless()
            } else {
                window.makeKeyAndOrderFront(nil)
            }
        }
        keyWindow?.makeKeyAndOrderFront(nil)

        if !success {
            promptRestartForRunInBackground()
        }
    }

    private func applyLanguage() {
        if let language = settings.language.localeIdentifier {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    private func observeSettingsChanges() {
        settings.$appearance
            .dropFirst()
            .sink { [weak self] appearance in self?.applyAppearance(appearance) }
            .store(in: &cancellables)
        settings.$runInBackground
            .dropFirst()
            .sink { [weak self] _ in self?.applyRunInBackground() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .appLanguageDidChange)
            .sink { [weak self] _ in
                self?.applyLanguage()
            }
            .store(in: &cancellables)
    }

    private func promptRestartForRunInBackground() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("需要重启", comment: "Restart required alert title")
        alert.informativeText = NSLocalizedString("Dock 图标设置已保存，需要重启 ClipVault 才能生效。", comment: "Run in background restart message")
        alert.addButton(withTitle: NSLocalizedString("立即重启", comment: "Restart now button"))
        alert.addButton(withTitle: NSLocalizedString("稍后", comment: "Later button"))
        if alert.runModal() == .alertFirstButtonReturn {
            relaunchApp()
        }
    }

    private func observeSystemAppearanceChanges() {
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func systemAppearanceChanged() {
        guard settings.appearance == .system else { return }
        applyAppearance(settings.appearance)
    }

    private func relaunchApp() {
        let appURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", appURL.path]
        do {
            try task.run()
        } catch {
            // 若无法自动重启，提示用户手动重启
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("需要重启", comment: "Relaunch required alert title")
            alert.informativeText = NSLocalizedString("语言设置已保存，请手动重新打开 ClipVault 以生效。", comment: "Relaunch required alert message")
            alert.addButton(withTitle: NSLocalizedString("好", comment: "OK button"))
            alert.runModal()
        }
        // 给新实例留出启动时间后退出当前实例
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.terminate(nil)
        }
    }

    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") else { return }
        let controller = OnboardingWindowController(settings: settings)
        onboardingWindow = controller
        controller.show()
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
    }

    // MARK: - 主菜单（提供剪切/复制/粘贴等编辑命令）

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: NSLocalizedString("退出 ClipVault", comment: "Quit menu item"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem(title: NSLocalizedString("编辑", comment: "Edit menu"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: NSLocalizedString("编辑", comment: "Edit menu"))
        editMenu.addItem(withTitle: NSLocalizedString("撤销", comment: "Undo menu item"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: NSLocalizedString("重做", comment: "Redo menu item"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: NSLocalizedString("剪切", comment: "Cut menu item"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: NSLocalizedString("复制", comment: "Copy menu item"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: NSLocalizedString("粘贴", comment: "Paste menu item"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: NSLocalizedString("全选", comment: "Select All menu item"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        return mainMenu
    }

    // MARK: - 快捷键

    private func reloadHotKeys() {
        var map: [HotKeyAction: Shortcut] = [:]
        for action in HotKeyAction.allCases {
            if let shortcut = settings.shortcut(for: action) {
                map[action] = shortcut
            }
        }
        hotKeys.reload(shortcuts: map)
    }

    private func handleHotKey(_ action: HotKeyAction) {
        switch action {
        case .showPanel:
            panelController.toggle()
        case .search:
            panelController.focusSearch()
        case .nextPinboard:
            panelController.showAndSelectTab(delta: 1)
        case .prevPinboard:
            panelController.showAndSelectTab(delta: -1)
        case .uploadToImageHosting:
            Task { @MainActor [weak self] in await self?.uploadImageToHosting() }
        case .selectAll:
            // 面板内快捷键，不会走到这里（未做全局注册）
            break
        }
    }

    // MARK: - 图床上传

    private func uploadImageToHosting() async {
        // 优先上传面板中当前选中的图片
        let viewModel = panelController.viewModel
        let selectedData: Data?
        let selectedFileName: String?
        if panelController.isVisible,
           viewModel.filtered.indices.contains(viewModel.selectedIndex),
           viewModel.selectedIndex >= 0 {
            let item = viewModel.filtered[viewModel.selectedIndex]
            if item.kind == .image {
                selectedData = viewModel.store.imageData(for: item)
                selectedFileName = item.imageFile
            } else {
                selectedData = nil
                selectedFileName = nil
            }
        } else {
            selectedData = nil
            selectedFileName = nil
        }

        let data: Data
        let fileName: String
        if let selectedData, let selectedFileName, !selectedFileName.isEmpty {
            data = selectedData
            fileName = selectedFileName
        } else if let pasted = ImageHostingService.readImageFromPasteboard() {
            data = pasted.data
            fileName = pasted.fileName
        } else {
            sendNotification(title: NSLocalizedString("图床上传失败", comment: "Image upload failed notification title"), body: NSLocalizedString("未选中图片且剪贴板中没有图片", comment: "No selected image or image in clipboard notification body"))
            return
        }

        let result = await ImageHostingService.shared.uploadToDefault(
            data: data,
            fileName: ImageHostingService.generateFileName(originalName: fileName, settings: settings),
            settings: settings
        )

        if result.success, let url = result.url {
            let output = settings.imageHostingGenerateMarkdown ? (result.markdownUrl ?? url) : url
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
            monitor.syncChangeCount()
            sendNotification(title: NSLocalizedString("图床上传成功", comment: "Image upload succeeded notification title"), body: output)
        } else {
            sendNotification(title: NSLocalizedString("图床上传失败", comment: "Image upload failed notification title"), body: result.error ?? NSLocalizedString("未知错误", comment: "Unknown error"))
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(120))
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: - 保留策略

    private func applyRetention() {
        store.prune(olderThanDays: settings.retention.rawValue)
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 菜单栏图标：单色模板图（系统自动适配明暗菜单栏）
        if let path = Bundle.main.path(forResource: "StatusIcon", ofType: "png"),
           let icon = NSImage(contentsOfFile: path) {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            statusItem.button?.image = icon
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                               accessibilityDescription: "ClipVault")
        }
        // 左键展开/收起面板（按钮默认 action）
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemLeftClicked)
        // 右键弹菜单：监听落在状态栏按钮窗口上的右键事件
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp) { [weak self] event in
            guard let self, let button = self.statusItem?.button,
                  event.window === button.window else { return event }
            let menu = self.buildMenu()
            menu.delegate = self
            let firstItem = menu.items.first
            menu.popUp(positioning: firstItem, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            return nil
        }
    }

    @objc private func statusItemLeftClicked() {
        panelController.toggle()
    }

    // MARK: - NSMenuDelegate

    /// 每次展开菜单时原地刷新，保证"暂停剩余时间"是最新的
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu: menu)
    }

    /// 菜单栏菜单与面板右上 ··· 菜单共用；每次构建以反映暂停状态
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        populate(menu: menu)
        return menu
    }

    private func populate(menu: NSMenu) {
        let items = [
            NSMenuItem(title: NSLocalizedString("关于 ClipVault", comment: "About menu item"), action: #selector(showAbout), keyEquivalent: ""),
            NSMenuItem(title: NSLocalizedString("显示面板", comment: "Show panel menu item"), action: #selector(showPanel), keyEquivalent: ""),
            NSMenuItem(title: NSLocalizedString("新文本项", comment: "New text item menu item"), action: #selector(newTextItem), keyEquivalent: ""),
        ]
        items.forEach { item in
            item.target = self
            menu.addItem(item)
        }

        let pauseItem = NSMenuItem(title: pauseMenuTitle, action: nil, keyEquivalent: "")
        pauseItem.submenu = buildPauseMenu()
        menu.addItem(pauseItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: NSLocalizedString("设置…", comment: "Settings menu item"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let clear = NSMenuItem(title: NSLocalizedString("清除历史…", comment: "Clear history menu item"), action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())
        // target 为 nil，沿响应链找到 NSApplication 的 terminate(_:)
        menu.addItem(withTitle: NSLocalizedString("退出 ClipVault", comment: "Quit menu item"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // MARK: - 暂停记录

    private var pauseMenuTitle: String {
        monitor.isPaused
            ? String(format: NSLocalizedString("暂停记录中（剩余 %@）", comment: "Paused recording menu title"), pausedRemainingText)
            : NSLocalizedString("暂停记录", comment: "Pause recording menu title")
    }

    private var pausedRemainingText: String {
        guard let until = monitor.pausedUntil else { return "" }
        let remaining = until.timeIntervalSinceNow
        switch remaining {
        case ..<60: return NSLocalizedString("不到 1 分钟", comment: "Less than one minute remaining")
        case ..<3600: return String(format: NSLocalizedString("%d 分钟", comment: "Minutes remaining"), Int(remaining / 60))
        case ..<86400: return String(format: NSLocalizedString("%d 小时", comment: "Hours remaining"), Int(remaining / 3600))
        default: return String(format: NSLocalizedString("%d 天", comment: "Days remaining"), Int(remaining / 86400))
        }
    }

    private func buildPauseMenu() -> NSMenu {
        let submenu = NSMenu()
        if monitor.isPaused {
            let resume = NSMenuItem(title: NSLocalizedString("继续记录", comment: "Resume recording menu item"), action: #selector(resumeRecording), keyEquivalent: "")
            resume.target = self
            submenu.addItem(resume)
        } else {
            let options: [(String, TimeInterval)] = [
                (NSLocalizedString("5 分钟", comment: "5 minutes"), 300),
                (NSLocalizedString("30 分钟", comment: "30 minutes"), 1800),
                (NSLocalizedString("1 小时", comment: "1 hour"), 3600),
                (NSLocalizedString("1 天", comment: "1 day"), 86400),
            ]
            for (title, interval) in options {
                let item = NSMenuItem(title: title, action: #selector(pauseRecording(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = interval
                submenu.addItem(item)
            }
        }
        return submenu
    }

    @objc private func pauseRecording(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval else { return }
        monitor.pause(for: interval)
    }

    @objc private func resumeRecording() {
        monitor.resume()
    }

    @objc private func showPanel() {
        panelController.show()
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func showAbout() {
        if aboutWindow == nil {
            let view = AppearanceRoot(settings: settings) { AboutView() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = NSLocalizedString("关于 ClipVault", comment: "About window title")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            aboutWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func newTextItem() {
        textEditor.show()
    }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("清除全部历史？", comment: "Clear history alert title")
        alert.informativeText = NSLocalizedString("将删除所有已保存的剪贴板记录，此操作不可撤销。", comment: "Clear history alert message")
        alert.addButton(withTitle: NSLocalizedString("清除", comment: "Clear button"))
        alert.addButton(withTitle: NSLocalizedString("取消", comment: "Cancel button"))
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear()
        }
    }

    // MARK: - 辅助功能权限

    /// 模拟 ⌘V 需要辅助功能权限；启动时若无权限则触发一次系统提示。
    private func promptAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
