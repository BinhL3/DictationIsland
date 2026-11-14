import CoreGraphics
import Foundation
import os

private let triggerLog = Logger(subsystem: "dev.voicedictation.DictationIsland", category: "trigger")

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

    /// Whether `flags` show any other supported modifier held (caps lock doesn't count).
    func othersDown(flags: UInt64) -> Bool {
        flags & (Self.allMasks & ~mask) != 0
    }

    private static let allMasks = table.values.reduce(UInt64(0)) { $0 | $1.mask }
}

/// Push-to-talk on one or more trigger keys (e.g. fn on an external keyboard *and* right ⌥ on the
/// laptop), seen through a listen-only CGEvent tap.
///
/// Because modifiers are also shortcut keys, a trigger only fires when its key is used *alone*:
/// it must go down with no other modifier held, and any key, click, or other modifier while it
/// is held turns the press into a chord and it is ignored (or cancels a session it already
/// started).
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
    /// Keys that may be tapped while a trigger is held without turning it into a chord (the
    /// computer-audio toggle, tapped mid-dictation).
    var passThroughKeys: Set<TriggerKey> = []
    /// Checked on key-down: true leaves this press alone entirely (the app has the key).
    var ignoresPress: (() -> Bool)?
    /// The person typed or clicked (not our own synthetic keys). "Fix that" uses it to know the
    /// last paste is still the latest thing in the field.
    var onUserInput: (() -> Void)?
    /// The trigger key went down (the key) or came up / was dropped (nil). For showing it.
    var onKeyState: ((TriggerKey?) -> Void)?

    /// Changing the keys mid-press drops the press.
    var keys: Set<TriggerKey> {
        didSet { if keys != oldValue { reset() } }
    }
    /// Short enough to feel instant, long enough that shortcuts and ⌥-characters typed with the
    /// key never show the island.
    static let holdThreshold: TimeInterval = 0.2

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// macOS can switch the tap off without telling us (sleep, secure input, an Accessibility
    /// change); this checks every few seconds and turns it back on, or rebuilds it.
    private var healthTimer: Timer?
    /// Keeps App Nap from throttling the main run loop the tap is delivered on.
    private var activity: NSObjectProtocol?
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
        tapSource = source
        if healthTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkTapHealth() }
            RunLoop.main.add(timer, forMode: .common)
            healthTimer = timer
        }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Listening for the push-to-talk key"
            )
        }
        return true
    }

    /// Removes the event tap. Must run before the trigger is freed: the tap's callback holds an
    /// unretained pointer to it.
    func stop() {
        holdWork?.cancel()
        healthTimer?.invalidate()
        healthTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    deinit {
        stop()
    }

    private func checkTapHealth() {
        guard let tap else { return }
        if !CFMachPortIsValid(tap) {
            reset()
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            self.tap = nil
            tapSource = nil
            start()
        } else if !CGEvent.tapIsEnabled(tap: tap) {
            triggerLog.notice("The key listener was switched off by macOS; turning it back on")
            // Events were missed while it was off, so the held-key state can't be trusted.
            reset()
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        // Our own ⌘V (pasting a finished take while the next one is held) isn't a chord.
        if event.getIntegerValueField(.eventSourceUserData) == TextInserter.syntheticEventMarker { return }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // A release may have been missed while the tap was off.
            reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if downKey != nil, passThroughKeys.contains(where: { $0.keyCode == code }) { return }
            if let downKey, code != downKey.keyCode, !downKey.isDown(flags: event.flags.rawValue) {
                // Another modifier changed and the flags say the held key is already up: its
                // release never arrived, so drop the stale press.
                reset()
            }
            if let key = keys.first(where: { $0.keyCode == code }), downKey == nil || downKey == key {
                let flags = event.flags.rawValue
                if key.isDown(flags: flags) {
                    // Only a press from a neutral keyboard counts. With ⇧ (or any other modifier)
                    // already held it's the start of a shortcut, and a firmware macro like ⇧⌥←
                    // must not read as a tap that latches hands-free (Hex #1076). The press is
                    // ignored until the key comes up again.
                    if downKey == nil, key.othersDown(flags: flags) { return }
                    pressed(key)
                } else {
                    released(key)
                }
            } else if downKey != nil {
                chord()
            }
        default:
            if type != .scrollWheel { onUserInput?() }
            if downKey != nil { chord() }
        }
    }

    /// Forgets the current press. A hold in progress is finished rather than dropped, so the
    /// dictation isn't lost; a press that hadn't become a hold is treated as a shortcut.
    private func reset() {
        if downKey != nil, !isChorded { isHolding ? onHoldEnd?() : onChordBeforeHold?() }
        if downKey != nil { onKeyState?(nil) }
        holdWork?.cancel()
        downKey = nil
        isHolding = false
        isChorded = false
    }

    private func pressed(_ key: TriggerKey) {
        guard downKey == nil, ignoresPress?() != true else { return }
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
        onKeyState?(key)
        onPress?()
    }

    private func released(_ key: TriggerKey) {
        guard downKey == key else { return }
        downKey = nil
        holdWork?.cancel()
        onKeyState?(nil)
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
