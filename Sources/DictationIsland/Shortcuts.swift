import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A user-chosen shortcut: a modifier key tapped on its own (right ⌘), or a key combination
/// (⌃⌥A). Modifier keys need the key listener; combinations use Carbon hot keys, which need no
/// permission.
enum Shortcut: Codable, Hashable {
    case modifier(Int64)
    case combo(keyCode: UInt32, modifiers: UInt32)

    static let annotateDefault = Shortcut.combo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey))
    static let fixDefault = Shortcut.modifier(TriggerKey.rightCommand.keyCode)
    /// Hex's default too.
    static let pasteLastDefault = Shortcut.combo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | shiftKey))

    var display: String {
        switch self {
        case .modifier(let code):
            return TriggerKey(keyCode: code).name
        case .combo(let keyCode, let modifiers):
            var text = ""
            if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
            return text + Self.keyName(UInt16(keyCode))
        }
    }

    private static func keyName(_ code: UInt16) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(code)] { return name }
        // What the key types on the current layout, so ⌃⌥A reads right on AZERTY too.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "#\(code)" }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            return length > 0 ? String(utf16CodeUnits: chars, count: length).uppercased() : "#\(code)"
        }
    }
}

/// Runs an action when its shortcut fires, whichever kind it is.
@MainActor
final class ShortcutListener {
    private var trigger: ModifierKeyTrigger?
    private var hotKey: HotKey?
    private var retry: Timer?
    let shortcut: Shortcut

    /// Nil when a key combination is already taken by another app.
    init?(_ shortcut: Shortcut, id: UInt32, action: @escaping @MainActor () -> Void) {
        self.shortcut = shortcut
        switch shortcut {
        case .modifier(let code):
            let trigger = ModifierKeyTrigger(keys: [TriggerKey(keyCode: code)])
            // A tap, or a hold let go without using it in a shortcut.
            trigger.onTap = { MainActor.assumeIsolated { action() } }
            trigger.onHoldEnd = { MainActor.assumeIsolated { action() } }
            self.trigger = trigger
            if !trigger.start() {
                retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak trigger] timer in
                    if trigger?.start() != false { timer.invalidate() }
                }
            }
        case .combo(let keyCode, let modifiers):
            guard let hotKey = HotKey(keyCode: Int(keyCode), modifiers: Int(modifiers), id: id) else { return nil }
            hotKey.onPress = { MainActor.assumeIsolated { action() } }
            self.hotKey = hotKey
        }
    }

    deinit {
        retry?.invalidate()
        // The event tap holds an unretained pointer to the trigger; remove it before the trigger
        // goes, or the next key event calls into freed memory.
        trigger?.stop()
    }
}

/// Click, then press a modifier key on its own or a key combination. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    /// Whether a single modifier key is accepted (it's then used by tapping it).
    var allowsModifierOnly = true
    var clearable = true

    @State private var recording = false
    @State private var monitor: Any?
    @State private var pendingModifier: TriggerKey?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : (shortcut?.display ?? "Not set"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(minWidth: 70)
            }
            if clearable, shortcut != nil, !recording {
                Button { shortcut = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Turn off")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        pendingModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                var modifiers: UInt32 = 0
                if flags.contains(.control) { modifiers |= UInt32(controlKey) }
                if flags.contains(.option) { modifiers |= UInt32(optionKey) }
                if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
                if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
                // A plain letter would fire while typing; insist on ⌃, ⌥ or ⌘ (F-keys are fine alone).
                // F-key codes aren't contiguous (F1 is 122, F12 is 111), so list them.
                let isFunctionKey = Self.functionKeys.contains(Int(event.keyCode))
                guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 || isFunctionKey else { NSSound.beep(); return nil }
                shortcut = .combo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
                stop()
                return nil
            }
            guard allowsModifierOnly, let key = TriggerKey(supportedKeyCode: Int64(event.keyCode)) else { return event }
            if key.isDown(flags: UInt64(event.modifierFlags.rawValue)) {
                pendingModifier = key
            } else if pendingModifier == key {
                // Down and up with nothing in between: the modifier on its own.
                shortcut = .modifier(key.keyCode)
                stop()
            }
            return nil
        }
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        pendingModifier = nil
    }
}
