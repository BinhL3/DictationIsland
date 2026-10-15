import CoreGraphics
import Foundation

/// A key that can trigger push-to-talk on its own: any modifier (each side separately) or fn.
/// These keys don't type anything, so a listen-only tap can use them without swallowing input.
struct TriggerKey: Codable, Hashable, Identifiable {
    let keyCode: Int64

    var id: Int64 { keyCode }

    /// Every supported key: keycode → (name, flag bits that are set while it's held).
    /// Side-specific bits are the device-dependent masks from IOLLEvent.h; fn uses
    /// `NX_SECONDARYFNMASK`, which Apple keyboards and the Globe key set.
    private static let table: [Int64: (name: String, mask: UInt64)] = [
        63: ("fn", 0x80_0000),
        61: ("right ⌥", 0x40),
        58: ("left ⌥", 0x20),
        54: ("right ⌘", 0x10),
        55: ("left ⌘", 0x08),
        62: ("right ⌃", 0x2000),
        59: ("left ⌃", 0x01),
        60: ("right ⇧", 0x04),
        56: ("left ⇧", 0x02),
    ]

    static let fn = TriggerKey(keyCode: 63)
    static let rightOption = TriggerKey(keyCode: 61)
    static let rightCommand = TriggerKey(keyCode: 54)

    init(keyCode: Int64) {
        self.keyCode = keyCode
    }

    /// nil for keys that can't be a trigger (letters, caps lock, …).
    init?(supportedKeyCode keyCode: Int64) {
        guard Self.table[keyCode] != nil else { return nil }
        self.keyCode = keyCode
    }

    var name: String { Self.table[keyCode]?.name ?? "key \(keyCode)" }
    fileprivate var mask: UInt64 { Self.table[keyCode]?.mask ?? 0 }

    /// Whether a `flagsChanged` event for this key means it went down.
    func isDown(flags: UInt64) -> Bool { flags & mask != 0 }
}

/// Push-to-talk on one or more trigger keys (e.g. fn on an external keyboard *and* right ⌥ on the
/// laptop), seen through a listen-only CGEvent tap.
///
/// Because modifiers are also shortcut keys, a trigger only fires when its key is used *alone*:
/// any key, click, or other modifier while it is held turns the press into a chord and it is
/// ignored (or cancels a session it already started).
///
/// Needs Input Monitoring permission; listen-only taps can't block or alter events.
final class ModifierKeyTrigger {
    /// The key went down on its own. It may still become a hold, a tap, or a shortcut chord.
    var onPress: (() -> Void)?
    /// Became a shortcut chord (or was dropped) before the hold started.
    var onChordBeforeHold: (() -> Void)?
    /// Held past `holdThreshold`: hold-to-talk begins.
    var onHoldStart: (() -> Void)?
    /// Released after a hold.
    var onHoldEnd: (() -> Void)?
    /// Pressed and released quickly on its own.
    var onTap: (() -> Void)?
    /// Became a shortcut chord after the hold had already started.
    var onChordAfterHold: (() -> Void)?

    /// Changing the keys mid-press drops the press.
    var keys: Set<TriggerKey> {
        didSet { if keys != oldValue { reset() } }
    }
    /// Short enough to feel instant, long enough that shortcuts and ⌥-characters typed with the
    /// key never show the island.
    static let holdThreshold: TimeInterval = 0.2

    private var tap: CFMachPort?
    /// The trigger key currently held, if any.
    private var downKey: TriggerKey?
    private var isHolding = false
    private var isChorded = false
    private var holdWork: DispatchWorkItem?

    init(keys: Set<TriggerKey>) {
        self.keys = keys
    }

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    static func requestPermission() {
        CGRequestListenEventAccess()
    }

    /// Returns false until Input Monitoring is granted.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                Unmanaged<ModifierKeyTrigger>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if let key = keys.first(where: { $0.keyCode == code }), downKey == nil || downKey == key {
                key.isDown(flags: event.flags.rawValue) ? pressed(key) : released(key)
            } else if downKey != nil {
                chord()
            }
        default:
            if downKey != nil { chord() }
        }
    }

    private func reset() {
        if downKey != nil, !isHolding, !isChorded { onChordBeforeHold?() }
        holdWork?.cancel()
        downKey = nil
        isHolding = false
        isChorded = false
    }

    private func pressed(_ key: TriggerKey) {
        guard downKey == nil else { return }
        downKey = key
        isHolding = false
        isChorded = false
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.downKey != nil, !self.isChorded else { return }
            self.isHolding = true
            self.onHoldStart?()
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdThreshold, execute: work)
        onPress?()
    }

    private func released(_ key: TriggerKey) {
        guard downKey == key else { return }
        downKey = nil
        holdWork?.cancel()
        if isChorded { return }
        isHolding ? onHoldEnd?() : onTap?()
        isHolding = false
    }

    private func chord() {
        guard !isChorded else { return }
        isChorded = true
        holdWork?.cancel()
        if isHolding {
            isHolding = false
            onChordAfterHold?()
        } else {
            onChordBeforeHold?()
        }
    }
}
