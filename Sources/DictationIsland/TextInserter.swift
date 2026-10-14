import AppKit
import ApplicationServices

/// Puts the transcript where the user was typing. The island panel never becomes key, so the
/// frontmost app still owns focus and a synthetic ⌘V lands in its text field.
enum TextInserter {
    @MainActor private static var didPrompt = false

    @MainActor static func insert(_ text: String, autoPaste: Bool) -> InsertResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
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
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return .pasted
    }

    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
