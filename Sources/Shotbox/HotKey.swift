import AppKit
import Carbon.HIToolbox

/// 全局快捷键，基于 Carbon RegisterEventHotKey，不需要辅助功能权限。
final class HotKey {
    private var ref: EventHotKeyRef?
    private var action: (() -> Void)?
    private var id: UInt32 = 0

    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    static let cmd = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)

    @discardableResult
    static func register(keyCode: Int, modifiers: UInt32, action: @escaping () -> Void) -> HotKey {
        installHandlerIfNeeded()

        let hotKey = HotKey()
        hotKey.action = action
        hotKey.id = nextID
        nextID += 1

        var hotKeyID = EventHotKeyID(signature: OSType(0x53484F42), id: hotKey.id) // 'SHOB'
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        hotKey.ref = ref
        registry[hotKey.id] = hotKey
        return hotKey
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, let hotKey = HotKey.registry[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { hotKey.action?() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
