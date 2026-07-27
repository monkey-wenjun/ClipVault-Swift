import AppKit

let app = NSApplication.shared
// main.swift 顶层代码运行在主线程
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
