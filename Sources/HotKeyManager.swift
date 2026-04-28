import Carbon
import Foundation

final class HotKeyManager {
    private static var callbacks: [UInt32: () -> Void] = [:]
    private static var eventHandler: EventHandlerRef?
    private static var nextID: UInt32 = 1

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let callback: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.callback = callback
        self.id = Self.nextID
        Self.nextID += 1
    }

    deinit {
        unregister()
    }

    func register() {
        Self.installHandlerIfNeeded()
        Self.callbacks[id] = callback

        let hotKeyID = EventHotKeyID(signature: OSType("SPCH".fourCharCode), id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        Self.callbacks[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                HotKeyManager.callbacks[hotKeyID.id]?()
                return noErr
            },
            1,
            &eventType,
            nil,
            &handler
        )
        eventHandler = handler
    }
}

private extension String {
    var fourCharCode: UInt32 {
        utf8.reduce(0) { ($0 << 8) + UInt32($1) }
    }
}
