import AppKit

/// “新文本项”编辑器：顶部 取消 / B I U S / 创建，多行编辑区，底部字符统计。
/// 注：条目按纯文本存储，格式只在编辑时可见，保存后不保留。
@MainActor
final class TextEditorWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    var onCreate: ((String) -> Void)?

    private var window: NSWindow?
    private var textView: NSTextView?
    private var statsLabel: NSTextField?
    private var createButton: NSButton?
    private var keyMonitor: Any?

    var isVisible: Bool { window?.isVisible == true }

    func show(withText text: String = "") {
        if window == nil { makeWindow() }
        textView?.string = text
        textDidChange(Notification(name: NSText.didChangeNotification))
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        installKeyMonitor()
    }

    private func close() {
        removeKeyMonitor()
        window?.close()
    }

    // MARK: - 窗口

    private func makeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        window.delegate = self

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active

        // 顶栏：取消 [spacer] B I U S [spacer] 创建
        let cancel = NSButton(title: NSLocalizedString("取消", comment: "Cancel button"), target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded

        let create = NSButton(title: NSLocalizedString("创建", comment: "Create button"), target: self, action: #selector(createClicked))
        create.bezelStyle = .rounded
        create.bezelColor = .controlAccentColor
        createButton = create

        let formatStack = NSStackView(views: [
            makeFormatButton("B", traits: .boldFontMask, action: #selector(toggleBold)),
            makeFormatButton("I", traits: .italicFontMask, action: #selector(toggleItalic)),
            makeFormatButton("U", underline: true, action: #selector(toggleUnderline)),
            makeFormatButton("S", strikethrough: true, action: #selector(toggleStrikethrough)),
        ])
        formatStack.spacing = 20

        let spacer1 = NSView()
        let spacer2 = NSView()
        spacer1.translatesAutoresizingMaskIntoConstraints = false
        spacer2.translatesAutoresizingMaskIntoConstraints = false

        let topStack = NSStackView(views: [cancel, spacer1, formatStack, spacer2, create])
        topStack.orientation = .horizontal
        topStack.alignment = .centerY
        topStack.spacing = 8
        topStack.translatesAutoresizingMaskIntoConstraints = false

        // 编辑区
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.isRichText = true
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        scroll.documentView = textView
        self.textView = textView

        // 底部统计
        let stats = NSTextField(labelWithString: "")
        stats.font = .systemFont(ofSize: 12)
        stats.textColor = .secondaryLabelColor
        stats.translatesAutoresizingMaskIntoConstraints = false
        statsLabel = stats

        background.addSubview(topStack)
        background.addSubview(scroll)
        background.addSubview(stats)
        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            topStack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            topStack.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            spacer1.widthAnchor.constraint(equalTo: spacer2.widthAnchor),

            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: stats.topAnchor, constant: -10),

            stats.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stats.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
        ])

        window.contentView = background
        self.window = window
    }

    private func makeFormatButton(_ title: String,
                                  traits: NSFontTraitMask = [],
                                  underline: Bool = false,
                                  strikethrough: Bool = false,
                                  action: Selector) -> NSButton {
        var font = NSFont.systemFont(ofSize: 14)
        if !traits.isEmpty, let converted = NSFontManager.shared.convert(font, toHaveTrait: traits) as NSFont? {
            font = converted
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        return button
    }

    // MARK: - 快捷键：⌘↩ 创建，Esc 取消

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            if event.keyCode == 36, event.modifierFlags.contains(.command) {
                self.createClicked()
                return nil
            }
            if event.keyCode == 53 {
                self.cancelClicked()
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

    // MARK: - 按钮动作

    @objc private func cancelClicked() {
        close()
    }

    @objc private func createClicked() {
        let text = textView?.string ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onCreate?(text)
        close()
    }

    @objc private func toggleBold() { applyFontTrait(.boldFontMask) }
    @objc private func toggleItalic() { applyFontTrait(.italicFontMask) }
    @objc private func toggleUnderline() { applyStyleAttribute(.underlineStyle) }
    @objc private func toggleStrikethrough() { applyStyleAttribute(.strikethroughStyle) }

    // MARK: - 格式化（仅作用于编辑器内，保存为纯文本）

    private func applyFontTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let fontManager = NSFontManager.shared
        let range = textView.selectedRange()
        if range.length == 0 {
            var attrs = textView.typingAttributes
            let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 14)
            attrs[.font] = fontManager.traits(of: font).contains(trait)
                ? fontManager.convert(font, toNotHaveTrait: trait)
                : fontManager.convert(font, toHaveTrait: trait)
            textView.typingAttributes = attrs
            return
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? .systemFont(ofSize: 14)
            let newFont = fontManager.traits(of: font).contains(trait)
                ? fontManager.convert(font, toNotHaveTrait: trait)
                : fontManager.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: newFont, range: subrange)
        }
        storage.endEditing()
    }

    private func applyStyleAttribute(_ key: NSAttributedString.Key) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            var attrs = textView.typingAttributes
            let current = attrs[key] as? Int ?? 0
            attrs[key] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            textView.typingAttributes = attrs
            return
        }
        storage.beginEditing()
        storage.enumerateAttribute(key, in: range) { value, subrange, _ in
            let current = value as? Int ?? 0
            storage.addAttribute(key,
                                 value: current == 0 ? NSUnderlineStyle.single.rawValue : 0,
                                 range: subrange)
        }
        storage.endEditing()
    }

    // MARK: - NSTextViewDelegate：底部统计

    func textDidChange(_ notification: Notification) {
        let text = textView?.string ?? ""
        let chars = text.count
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        statsLabel?.stringValue = String(format: NSLocalizedString("%d 个字符 · %d 单词 · %d 行", comment: "Text stats label"), chars, words, lines)
        createButton?.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
    }
}
