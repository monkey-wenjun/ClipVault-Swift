import AppKit

@MainActor
final class ImagePreviewWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var imageView: NSImageView?
    private var sizeLabel: NSTextField?
    private var keyMonitor: Any?

    var isVisible: Bool { window?.isVisible == true }

    func show(image: NSImage) {
        if window == nil { makeWindow() }
        imageView?.image = image
        if let rep = image.representations.first {
            sizeLabel?.stringValue = "\(rep.pixelsWide) × \(rep.pixelsHigh)"
        } else {
            sizeLabel?.stringValue = ""
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    private func makeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = NSLocalizedString("图片预览", comment: "Image preview window title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isOpaque = true
        window.level = .floating
        window.hidesOnDeactivate = true
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        window.delegate = self

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.cgColor

        let size = NSTextField(labelWithString: "")
        size.font = .systemFont(ofSize: 12)
        size.textColor = .white.withAlphaComponent(0.85)

        let header = NSStackView(views: [NSView(), size])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = NSColor.black.cgColor

        let imageView = NSImageView()
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        self.imageView = imageView

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            imageView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            imageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        scrollView.documentView = container

        background.addSubview(header)
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),

            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        window.contentView = background
        self.window = window
        self.sizeLabel = size
    }

    @objc private func closeWindow() {
        removeKeyMonitor()
        window?.close()
    }

    func hide() {
        closeWindow()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            if event.keyCode == 49 || event.keyCode == 53 {
                self.closeWindow()
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
