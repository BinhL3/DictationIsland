import AppKit
import ApplicationServices

/// Where a dictation is going, so the tidy-up can fit it: short and casual in a chat app, full
/// sentences in mail, hands off in a terminal. Read once per take through Accessibility (already
/// granted for pasting), with a short timeout so a slow app can't hold anything up. Stays on the
/// Mac: it only goes into the on-device model's prompt.
struct WritingContext: Sendable, Equatable {
    enum Kind: String, Sendable {
        case chat, email, document, code, terminal, other
    }

    var appName: String
    var bundleID: String
    var pid: pid_t
    var windowTitle: String?
    /// The end of what's already in the field, up to the cursor.
    var textBeforeCursor: String?

    var kind: Kind { Self.kind(bundleID: bundleID, windowTitle: windowTitle) }

    /// The front app and its focused text field. Call off the main thread.
    static func captureFocused() -> WritingContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var context = WritingContext(
            appName: app.localizedName ?? "an app",
            bundleID: app.bundleIdentifier ?? "",
            pid: app.processIdentifier
        )
        guard AXIsProcessTrusted() else { return context }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        if let window: AXUIElement = copy(element, kAXFocusedWindowAttribute),
           let title: String = copy(window, kAXTitleAttribute), !title.isEmpty {
            context.windowTitle = String(title.prefix(120))
        }
        if let focused: AXUIElement = copy(element, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(focused, 0.25)
            if let value: String = copy(focused, kAXValueAttribute), !value.isEmpty {
                var end = value.utf16.count
                if let rangeValue: AXValue = copy(focused, kAXSelectedTextRangeAttribute) {
                    var range = CFRange()
                    if AXValueGetValue(rangeValue, .cfRange, &range) { end = min(end, max(0, range.location)) }
                }
                let utf16 = Array(value.utf16.prefix(end))
                let before = String(decoding: utf16.suffix(400), as: UTF16.self)
                if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { context.textBeforeCursor = before }
            }
        }
        return context
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func kind(bundleID: String, windowTitle: String?) -> Kind {
        let chat = ["com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp",
                    "ru.keepcoder.Telegram", "com.facebook.archon", "org.whispersystems.signal-desktop", "com.microsoft.teams2"]
        let email = ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron"]
        let document = ["com.apple.Notes", "com.apple.iWork.Pages", "com.microsoft.Word", "notion.id", "md.obsidian",
                        "com.apple.TextEdit", "com.craft.craft"]
        let terminal = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                        "net.kovidgoyal.kitty", "co.zeit.hyper", "org.alacritty"]
        let code = ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
                    "com.sublimetext.4", "com.panic.Nova"]
        if chat.contains(bundleID) { return .chat }
        if email.contains(bundleID) { return .email }
        if document.contains(bundleID) { return .document }
        if terminal.contains(bundleID) { return .terminal }
        if code.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") { return .code }
        // Browsers: the tab's title usually names the site.
        let title = windowTitle?.lowercased() ?? ""
        if ["gmail", "outlook", "inbox", "superhuman"].contains(where: title.contains) { return .email }
        if ["slack", "discord", "whatsapp", "messenger", "telegram", "chat"].contains(where: title.contains) { return .chat }
        if ["google docs", "notion", "confluence"].contains(where: title.contains) { return .document }
        return .other
    }

    /// Lines for the model's prompt describing where the text is going.
    /// A marked block the instructions say never to copy; the model echoed looser phrasing.
    var promptLines: String {
        var tone: String
        switch kind {
        // Not "short": told to be brief, the model drops whole points.
        case .chat: tone = "a chat message: casual, keep their wording, no added greeting or sign-off"
        case .email: tone = "an email: complete sentences"
        case .document: tone = "a document: clear, complete sentences"
        case .code: tone = "a developer tool: keep technical terms and names exactly"
        case .terminal, .other: tone = "general text"
        }
        var lines = "<context>\nApp: \(appName)"
        if let windowTitle { lines += " (\(windowTitle))" }
        lines += "\nKind: \(tone)\n"
        if let textBeforeCursor {
            lines += "Already written before the cursor: \(textBeforeCursor.replacingOccurrences(of: "\n", with: " "))\n"
        }
        return lines + "</context>\n"
    }
}
