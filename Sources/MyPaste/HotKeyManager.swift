import AppKit
import Carbon

/// 使用 Carbon RegisterEventHotKey 注册全局快捷键，支持在设置中自定义和重载。
final class HotKeyManager {
    var handler: ((HotKeyAction) -> Void)?

    private var registered: [UInt32: (ref: EventHotKeyRef, action: HotKeyAction)] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    func reload(shortcuts: [HotKeyAction: Shortcut]) {
        unregisterAll()
        installHandlerIfNeeded()
        for (action, shortcut) in shortcuts {
            // 全选是面板内快捷键，不做全局注册
            if action == .selectAll { continue }
            register(shortcut, action: action)
        }
    }

    // MARK: - Private

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if let action = manager.registered[hotKeyID.id]?.action {
                DispatchQueue.main.async { manager.handler?(action) }
            }
            return noErr
        }, 1, &eventType, userData, &handlerRef)
    }

    private func register(_ shortcut: Shortcut, action: HotKeyAction) {
        let id = nextID
        nextID += 1
        // 'MYPS'
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D595053), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registered[id] = (ref, action)
        }
    }

    private func unregisterAll() {
        for (_, entry) in registered {
            UnregisterEventHotKey(entry.ref)
        }
        registered.removeAll()
    }

    deinit {
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
