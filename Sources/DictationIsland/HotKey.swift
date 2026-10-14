import Carbon.HIToolbox

/// Backup push-to-talk shortcut via Carbon `RegisterEventHotKey`. It reports press *and* release and
/// needs no Accessibility permission, unlike a CGEvent tap.
final class HotKey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Defaults to ⌃⌥Space. Plain ⌥Space is Raycast's default, and registering it would take it from Raycast.
    static let symbol = "⌃⌥Space"

    init?(keyCode: Int = kVK_Space, modifiers: Int = controlKey | optionKey) {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                    hotKey.onPress?()
                } else {
                    hotKey.onRelease?()
                }
                return noErr
            },
            types.count,
            &types,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        let id = EventHotKeyID(signature: OSType(0x4449_4354), id: 1)  // "DICT"
        let registerStatus = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard installStatus == noErr, registerStatus == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
