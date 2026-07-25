import Carbon
import Foundation

/// System-wide hotkey via Carbon `RegisterEventHotKey` — does not require Accessibility.
/// `@unchecked Sendable` because Carbon delivers the press on an arbitrary queue; we
/// hop to the main queue before invoking `handler`.
final class GlobalHotKey: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let lock = NSLock()
    private var handler: (() -> Void)?

    /// ⌘⇧R — key code `kVK_ANSI_R` (15).
    func registerCommandShiftR(_ handler: @escaping () -> Void) {
        unregister()
        lock.lock()
        self.handler = handler
        lock.unlock()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if hkID.id == 1 {
                    hotKey.lock.lock()
                    let action = hotKey.handler
                    hotKey.lock.unlock()
                    DispatchQueue.main.async {
                        action?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
        guard status == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4F4B524D), id: 1) // 'OKRM'
        let modifiers = UInt32(cmdKey | shiftKey)
        var mutableID = hotKeyID
        RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            modifiers,
            mutableID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        lock.lock()
        handler = nil
        lock.unlock()
    }

    deinit {
        unregister()
    }
}
