import AppKit

/// 把条目写回系统剪贴板，并模拟 ⌘V 粘贴到之前的活动应用。
/// 模拟按键需要辅助功能权限；没有权限时至少保证内容已在剪贴板里，可手动 ⌘V。
@MainActor
final class PasteService {
    private let store: HistoryStore
    private let monitor: ClipboardMonitor
    private let settings: AppSettings

    init(store: HistoryStore, monitor: ClipboardMonitor, settings: AppSettings) {
        self.store = store
        self.monitor = monitor
        self.settings = settings
    }

    func paste(_ item: ClipboardItem, to app: NSRunningApplication?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text, .color:
            pb.setString(item.pasteContent, forType: .string)
        case .image:
            if let data = store.imageData(for: item) {
                pb.setData(data, forType: .png)
            }
        case .file:
            if let path = item.text {
                let url = URL(fileURLWithPath: path)
                pb.writeObjects([url as NSURL])
                pb.setString(path, forType: .string)
            }
        }
        monitor.syncChangeCount()

        // “到剪贴板”模式：只写入剪贴板，由用户手动 ⌘V
        guard settings.pasteTarget == .activeApp else { return }
        guard AXIsProcessTrusted() else {
            warnAccessibilityOnce()
            return
        }
        if let app {
            // macOS 13 仍使用旧版 activate(options:)；macOS 14+ 推荐的新 API
            // activate(from:options:) 在此不可用。
            app.activate(options: [.activateAllWindows])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.postCommandV()
        }
    }

    /// 无辅助功能权限时引导一次（ad-hoc 重签或权限被关都会走到这里）
    private var didWarnAccessibility = false
    private func warnAccessibilityOnce() {
        guard !didWarnAccessibility else { return }
        didWarnAccessibility = true
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("需要辅助功能权限才能自动粘贴", comment: "Accessibility permission alert title")
        alert.informativeText = NSLocalizedString("内容已写入剪贴板，可手动 ⌘V。要自动粘贴，请在 系统设置 → 隐私与安全性 → 辅助功能 中启用 ClipVault；若已在列表中，请关闭再重新打开（应用更新签名后授权会失效）。", comment: "Accessibility permission alert message")
        alert.addButton(withTitle: NSLocalizedString("打开设置", comment: "Open settings button"))
        alert.addButton(withTitle: NSLocalizedString("好", comment: "OK button"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // kVK_ANSI_V
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
