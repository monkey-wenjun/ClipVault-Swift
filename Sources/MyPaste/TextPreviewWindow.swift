import AppKit

private final class TextPreviewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// 文本内容浮动预览窗口：可直接在窗口内编辑文本并保存。
@MainActor
final class TextPreviewWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private var window: NSWindow?
    private var textView: NSTextView?
    private var statsLabel: NSTextField?
    private var saveButton: NSButton?
    private var item: ClipboardItem?
    private var onSave: ((UUID, String) -> Void)?
    private weak var monitor: ClipboardMonitor?

    var isVisible: Bool { window?.isVisible == true }

    init(monitor: ClipboardMonitor? = nil) {
        self.monitor = monitor
        super.init()
    }

    func show(item: ClipboardItem, onSave: ((UUID, String) -> Void)? = nil) {
        let text = item.text ?? ""
        if window == nil { makeWindow() }
        textView?.string = text
        updateStats(text: text)
        self.item = item
        self.onSave = onSave
        saveButton?.title = NSLocalizedString("保存", comment: "Save button")
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    func hide() {
        window?.close()
    }

    private func makeWindow() {
        let window = TextPreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = NSLocalizedString("文本", comment: "Text preview window title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        window.level = .floating
        window.hidesOnDeactivate = true
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active

        // 顶栏：标题居中，复制/保存靠右；左上角使用系统交通灯关闭按钮
        let titleLabel = NSTextField(labelWithString: NSLocalizedString("文本", comment: "Text preview title label"))
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let copy = NSButton(title: NSLocalizedString("复制", comment: "Copy button"), target: self, action: #selector(copyClicked))
        copy.bezelStyle = .rounded

        let save = NSButton(title: NSLocalizedString("保存", comment: "Save button"), target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        save.bezelColor = .controlAccentColor
        saveButton = save

        let buttonStack = NSStackView(views: [copy, save])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 10
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        // 内容区
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
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

        background.addSubview(titleLabel)
        background.addSubview(buttonStack)
        background.addSubview(scroll)
        background.addSubview(stats)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: 32),

            buttonStack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            buttonStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: stats.topAnchor, constant: -10),

            stats.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stats.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
        ])

        window.contentView = background
        self.window = window
    }

    @objc private func closeWindow() {
        window?.close()
    }

    @objc private func copyClicked() {
        guard let text = textView?.string, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        monitor?.syncChangeCount()
    }

    @objc private func saveClicked() {
        guard let item, let text = textView?.string else { return }
        onSave?(item.id, text)
        closeWindow()
    }

    private func updateStats(text: String) {
        let chars = text.count
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        statsLabel?.stringValue = String(format: NSLocalizedString("%d 个字符 · %d 单词 · %d 行", comment: "Text stats label"), chars, words, lines)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        updateStats(text: textView?.string ?? "")
    }
}
