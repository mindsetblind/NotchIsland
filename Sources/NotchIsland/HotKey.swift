import Carbon

/// System-wide keyboard shortcut via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    /// Called when the keys are let go (push-to-talk); nil = only presses matter.
    private let onRelease: (() -> Void)?
    private let id: UInt32
    private static var nextID: UInt32 = 1

    /// Returns nil when another app already owns this shortcut.
    init?(keyCode: Int, modifiers: Int, onRelease: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.action = action
        self.onRelease = onRelease
        id = Self.nextID
        Self.nextID += 1
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            // Every handler sees every hot key of the app — only react to our own.
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.id == me.id else { return OSStatus(eventNotHandledErr) }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                me.onRelease?()
            } else {
                me.action()
            }
            return noErr
        }, 2, &specs, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         EventHotKeyID(signature: OSType(0x4E49_4B59), id: id), // "NIKY"
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
