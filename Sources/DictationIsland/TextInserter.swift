import AppKit
import ApplicationServices
import Carbon

/// Puts the transcript where the user was typing. The island panel never becomes key, so the
/// frontmost app still owns focus and a synthetic ⌘V lands in its text field.
enum TextInserter {
    @MainActor private static var didPrompt = false
    /// Stamped on the keystrokes we post, so our own key listener can ignore them.
    static let syntheticEventMarker: Int64 = 0x4449_534C  // "DISL"

    @MainActor static func insert(_ text: String, autoPaste: Bool) -> InsertResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Lists and paragraphs also go on as HTML, so rich editors paste a real bulleted list.
        if let html = RichText.html(for: trimmed) {
            pasteboard.declareTypes([.html, .string], owner: nil)
            pasteboard.setString(html, forType: .html)
        }
        pasteboard.setString(trimmed, forType: .string)

        // Synthesizing keystrokes requires Accessibility permission; without it, copy only and
        // show the system prompt (once per launch) so the next dictation can paste.
        guard autoPaste else { return .copied }
        guard AXIsProcessTrusted() else {
            if !didPrompt {
                didPrompt = true
                promptForAccessibility()
            }
            return .copied
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = pasteKeyCode()
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        for event in [down, up] {
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return .pasted
    }

    /// The key that types "v" with ⌘ held on the current layout. Key 9 is only V on QWERTY; on
    /// Dvorak it's "k", so a hard-coded ⌘ + key 9 silently doesn't paste. Layouts like
    /// "Dvorak – QWERTY ⌘" switch to QWERTY while ⌘ is down, which the ⌘ lookup honours.
    /// Non-Latin layouts (Russian, Greek) fall back to the ASCII-capable layout, as AppKit does.
    private static func pasteKeyCode() -> CGKeyCode { commandKeyCode(for: "v", qwerty: 9) }

    private static func commandKeyCode(for character: Character, qwerty: CGKeyCode) -> CGKeyCode {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for source in sources.compactMap({ $0?.takeRetainedValue() }) {
            if let code = keyCode(typing: character, in: source) { return code }
        }
        return qwerty
    }

    /// ⌘Z in the frontmost app, to take back our last paste ("Fix that").
    @MainActor static func undo() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = commandKeyCode(for: "z", qwerty: 6)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func keyCode(typing character: Character, in source: TISInputSource) -> CGKeyCode? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            // With ⌘ held first, then without, for layouts that don't define a ⌘ table.
            for modifiers in [UInt32(cmdKey >> 8), 0] {
                for code in 0..<UInt16(128) {
                    var deadKeys: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    let status = UCKeyTranslate(
                        layout, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
                    )
                    if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1).lowercased() == String(character) {
                        return CGKeyCode(code)
                    }
                }
            }
            return nil
        }
    }

    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
