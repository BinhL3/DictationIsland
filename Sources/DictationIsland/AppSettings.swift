import AppKit
import Foundation
import Observation

/// Where the island lives on screen.
enum IslandPlacement: String, CaseIterable, Identifiable {
    /// In the notch / menu bar. If another notch app (such as Alcove) is running, the island grows
    /// out of the same spot and draws over it while dictating.
    case automatic
    case menuBar
    case belowMenuBar
    /// Floating just above the Dock.
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "In the notch (automatic)"
        case .menuBar: return "In the notch / menu bar"
        case .belowMenuBar: return "Below the menu bar"
        case .bottom: return "Above the Dock"
        }
    }

    /// Apps that draw their own island in the same spot.
    static let notchAppBundleIDs: Set<String> = [
        "com.henrikruscon.Alcove",
        "theboringteam.boringnotch",
        "lo.cafe.NotchNook",
    ]

    var resolved: IslandPlacement {
        self == .automatic ? .menuBar : self
    }

    /// A notch app such as Alcove already draws a pill in the notch / menu bar.
    static var notchAppIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            notchAppBundleIDs.contains($0.bundleIdentifier ?? "")
        }
    }
}

/// What the built-in display has at the top for its camera.
enum CameraCutout: String, CaseIterable, Identifiable {
    /// The notch if macOS reports one, otherwise nothing.
    case automatic
    /// A notch the island grows out of (2021–2025 MacBook Pros and Airs).
    case notch
    /// A hole-punch camera in the menu bar (OLED MacBook Pros): the island rests as a pill
    /// around it, like the iPhone's Dynamic Island.
    case hole

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .notch: return "Notch"
        case .hole: return "Camera hole"
        }
    }

    /// What this screen has, with automatic resolved.
    @MainActor
    func resolved(for screen: NSScreen) -> CameraCutout {
        guard self == .automatic else { return self }
        return NotchGeometry.hasNotch(screen) ? .notch : .automatic
    }
}

/// How the push-to-talk key starts and ends a dictation.
enum TalkMode: String, CaseIterable, Identifiable {
    /// Hold to talk and let go to finish, or tap once for hands-free (the default).
    case holdOrTap
    /// Only while the key is held; a tap on its own does nothing.
    case hold
    /// Press once to start, press again to finish, however long you talk in between.
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdOrTap: return "Hold or tap"
        case .hold: return "Hold to talk"
        case .toggle: return "Press to start and stop"
        }
    }

    /// "Hold right ⌥ to talk, …" for onboarding, Home and Settings.
    func howTo(_ key: String) -> String {
        switch self {
        case .holdOrTap: return "Hold \(key) to talk, or tap it once for hands-free and tap again to finish."
        case .hold: return "Hold \(key) to talk and let go to finish."
        case .toggle: return "Press \(key) once to start and again to finish. Talk as long as you like."
        }
    }
}

/// Which channel of a multi-channel mic to listen to. Stereo USB mics like the Blue Yeti
/// deliver two channels; some modes only carry signal on one.
enum InputChannel: String, CaseIterable, Identifiable {
    case mix
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mix: return "Mix all channels"
        case .left: return "Channel 1 (left)"
        case .right: return "Channel 2 (right)"
        }
    }
}

struct DictationStats: Codable, Equatable {
    var words = 0
    var dictations = 0
    var secondsSpoken: Double = 0

    /// Typing the same words at 40 wpm, minus the time spent saying them.
    var minutesSaved: Double {
        max(0, Double(words) / 40 - secondsSpoken / 60)
    }
}

struct DictationRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var date: Date
}

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Any of these keys triggers push-to-talk, so one setup works on several keyboards
    /// (fn on a Keychron at home, right ⌥ on the laptop).
    var pushToTalkKeys: [TriggerKey] {
        didSet { defaults.set(try? JSONEncoder().encode(pushToTalkKeys), forKey: Keys.pushToTalkKeys) }
    }
    /// ⌃⌥Space as a no-permission backup. Off by default: plain ⌥Space collides with Raycast.
    var fallbackShortcutEnabled: Bool {
        didSet { defaults.set(fallbackShortcutEnabled, forKey: Keys.fallbackShortcut) }
    }
    var placement: IslandPlacement {
        didSet { defaults.set(placement.rawValue, forKey: Keys.placement) }
    }
    /// Show the resting pill in the menu bar while idle (only on screens without a notch).
    var showIdlePill: Bool {
        didSet { defaults.set(showIdlePill, forKey: Keys.showIdlePill) }
    }
    var cameraCutout: CameraCutout {
        didSet { defaults.set(cameraCutout.rawValue, forKey: Keys.cameraCutout) }
    }
    var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Keys.autoPaste) }
    }
    var talkMode: TalkMode {
        didSet { defaults.set(talkMode.rawValue, forKey: Keys.talkMode) }
    }
    /// Experiment: the live transcript shows its own revisions and the final clean-up, fixed
    /// words in green and dropped ones struck through in red.
    var liveEdits: Bool {
        didSet { defaults.set(liveEdits, forKey: Keys.liveEdits) }
    }
    /// Per app (bundle ID): whether the dictation keys work there. See `AppRules`.
    var appRules: [String: Bool] {
        didSet { defaults.set(appRules, forKey: Keys.appRules) }
    }
    /// Muffle music and videos while dictating.
    var muffleMedia: Bool {
        didSet { defaults.set(muffleMedia, forKey: Keys.muffleMedia) }
    }
    /// Sounds at start / stop / done (Hex's sets).
    var soundSet: SoundSet {
        didSet { defaults.set(soundSet.rawValue, forKey: Keys.soundSet) }
    }
    var soundVolume: Double {
        didSet { defaults.set(soundVolume, forKey: Keys.soundVolume) }
    }
    /// How loud media stays while muffled, 0...1.
    var muffleLevel: Double {
        didSet { defaults.set(muffleLevel, forKey: Keys.muffleLevel) }
    }
    /// Core Audio device UID; nil follows the system default input.
    var microphoneUID: String? {
        didSet { defaults.set(microphoneUID, forKey: Keys.microphoneUID) }
    }
    var inputChannel: InputChannel {
        didSet { defaults.set(inputChannel.rawValue, forKey: Keys.inputChannel) }
    }
    /// With the system default input, use the built-in mic instead of a Bluetooth headset's.
    var avoidBluetoothMic: Bool {
        didSet { defaults.set(avoidBluetoothMic, forKey: Keys.avoidBluetoothMic) }
    }
    /// One rule per line: `heard -> written`, or a bare word to only hint the recognizer.
    var correctionsText: String {
        didSet {
            defaults.set(correctionsText, forKey: Keys.corrections)
            corrections = Corrections(correctionsText)
        }
    }
    private(set) var corrections: Corrections
    /// "new line", "new paragraph" and "bullet point" become formatting.
    var spokenFormatting: Bool {
        didSet { defaults.set(spokenFormatting, forKey: Keys.spokenFormatting) }
    }
    /// Laughing while dictating adds a 😂 where you laughed.
    var laughEmoji: Bool {
        didSet { defaults.set(laughEmoji, forKey: Keys.laughEmoji) }
    }
    /// Rewrites and replaces the last dictation. A modifier key here can't also be a
    /// push-to-talk key (a tap would mean two things), so setting one removes it from those.
    var fixShortcut: Shortcut? {
        didSet {
            defaults.set(try? JSONEncoder().encode(fixShortcut), forKey: Keys.fixShortcut)
            if case .modifier(let code)? = fixShortcut { pushToTalkKeys.removeAll { $0.keyCode == code } }
        }
    }
    /// Tapped during a dictation, adds what the Mac is playing to it. Default: left ⇧.
    var computerAudioShortcut: Shortcut? {
        didSet { defaults.set(try? JSONEncoder().encode(computerAudioShortcut), forKey: Keys.computerAudioShortcut) }
    }
    /// Starts and stops a screen annotation.
    var annotateShortcut: Shortcut? {
        didSet { defaults.set(try? JSONEncoder().encode(annotateShortcut), forKey: Keys.annotateShortcut) }
    }
    /// ⌃⌥A records a screen annotation for an AI agent.
    var annotateEnabled: Bool {
        didSet { defaults.set(annotateEnabled, forKey: Keys.annotateEnabled) }
    }
    /// Tidy each dictation with Apple Intelligence, following `styleInstructions`.
    var styleRewrite: Bool {
        didSet {
            defaults.set(styleRewrite, forKey: Keys.styleRewrite)
            if styleRewrite { StyleRewriter.prewarm() }
        }
    }
    /// Let the tidy-up know which app the text is going to (chat, mail, code…).
    var adaptToApp: Bool {
        didSet { defaults.set(adaptToApp, forKey: Keys.adaptToApp) }
    }
    /// The user's description of how they want to be written.
    var styleInstructions: String {
        didSet { defaults.set(styleInstructions, forKey: Keys.styleInstructions) }
    }
    var speechEngine: SpeechEngine {
        didSet {
            defaults.set(speechEngine.rawValue, forKey: Keys.speechEngine)
            if speechEngine == .bark { BarkModels.preload() }
            if speechEngine == .parakeet { ParakeetModels.preload() }
        }
    }
    /// nil follows the system language.
    var localeIdentifier: String? {
        didSet { defaults.set(localeIdentifier, forKey: Keys.locale) }
    }
    /// Lifetime totals for Home. History keeps only the last 100; these keep counting.
    private(set) var stats: DictationStats {
        didSet { defaults.set(try? JSONEncoder().encode(stats), forKey: Keys.stats) }
    }
    private(set) var history: [DictationRecord] {
        didSet { defaults.set(try? JSONEncoder().encode(history), forKey: Keys.history) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        pushToTalkKeys = defaults.data(forKey: Keys.pushToTalkKeys).flatMap { try? JSONDecoder().decode([TriggerKey].self, from: $0) }
            ?? Self.migratedKeys(from: defaults.string(forKey: Keys.legacyPushToTalkKey))
        fallbackShortcutEnabled = defaults.bool(forKey: Keys.fallbackShortcut)
        placement = defaults.string(forKey: Keys.placement).flatMap(IslandPlacement.init) ?? .automatic
        showIdlePill = defaults.object(forKey: Keys.showIdlePill) as? Bool ?? false
        cameraCutout = defaults.string(forKey: Keys.cameraCutout).flatMap(CameraCutout.init) ?? .automatic
        autoPaste = defaults.object(forKey: Keys.autoPaste) as? Bool ?? true
        // Off unless chosen: setting up the filter as a dictation starts can make it feel laggy.
        talkMode = defaults.string(forKey: Keys.talkMode).flatMap(TalkMode.init) ?? .holdOrTap
        liveEdits = defaults.object(forKey: Keys.liveEdits) as? Bool ?? true
        appRules = defaults.dictionary(forKey: Keys.appRules) as? [String: Bool] ?? [:]
        muffleMedia = defaults.object(forKey: Keys.muffleMedia) as? Bool ?? false
        soundSet = defaults.string(forKey: Keys.soundSet).flatMap(SoundSet.init) ?? .classic
        soundVolume = defaults.object(forKey: Keys.soundVolume) as? Double ?? 0.5
        muffleLevel = defaults.object(forKey: Keys.muffleLevel) as? Double ?? 0.2
        microphoneUID = defaults.string(forKey: Keys.microphoneUID)
        inputChannel = defaults.string(forKey: Keys.inputChannel).flatMap(InputChannel.init) ?? .mix
        avoidBluetoothMic = defaults.object(forKey: Keys.avoidBluetoothMic) as? Bool ?? true
        let correctionsText = defaults.string(forKey: Keys.corrections) ?? ""
        self.correctionsText = correctionsText
        corrections = Corrections(correctionsText)
        spokenFormatting = defaults.object(forKey: Keys.spokenFormatting) as? Bool ?? true
        styleRewrite = defaults.bool(forKey: Keys.styleRewrite)
        adaptToApp = defaults.object(forKey: Keys.adaptToApp) as? Bool ?? true
        annotateEnabled = defaults.object(forKey: Keys.annotateEnabled) as? Bool ?? true
        laughEmoji = defaults.object(forKey: Keys.laughEmoji) as? Bool ?? true
        annotateShortcut = defaults.data(forKey: Keys.annotateShortcut).map { try? JSONDecoder().decode(Shortcut?.self, from: $0) } ?? Shortcut.annotateDefault
        computerAudioShortcut = defaults.data(forKey: Keys.computerAudioShortcut).map { try? JSONDecoder().decode(Shortcut?.self, from: $0) } ?? Shortcut.modifier(56)
        fixShortcut = defaults.data(forKey: Keys.fixShortcut).flatMap { try? JSONDecoder().decode(Shortcut?.self, from: $0) } ?? nil
        styleInstructions = defaults.string(forKey: Keys.styleInstructions) ?? ""
        localeIdentifier = defaults.string(forKey: Keys.locale)
        speechEngine = defaults.string(forKey: Keys.speechEngine).flatMap(SpeechEngine.init) ?? .automatic
        let savedHistory = defaults.data(forKey: Keys.history).flatMap { try? JSONDecoder().decode([DictationRecord].self, from: $0) } ?? []
        // Before stats existed, history is the best estimate of what's been dictated.
        stats = defaults.data(forKey: Keys.stats).flatMap { try? JSONDecoder().decode(DictationStats.self, from: $0) }
            ?? DictationStats(words: savedHistory.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }, dictations: savedHistory.count)
        history = savedHistory

        if defaults.data(forKey: Keys.fixShortcut) == nil {
            // First run with Fix that: right ⌘, taken out of the push-to-talk keys if it was one
            // (unless it was the only one).
            let right = TriggerKey.rightCommand
            if pushToTalkKeys != [right] {
                fixShortcut = Shortcut.fixDefault
                pushToTalkKeys.removeAll { $0 == right }
            }
            defaults.set(try? JSONEncoder().encode(fixShortcut), forKey: Keys.fixShortcut)
            defaults.set(try? JSONEncoder().encode(pushToTalkKeys), forKey: Keys.pushToTalkKeys)
        }
    }

    /// Earlier builds stored a single key; carry that choice over and add fn.
    private static func migratedKeys(from legacy: String?) -> [TriggerKey] {
        switch legacy {
        case "rightCommand": return [.fn, .rightCommand]
        case "off": return []
        default: return [.fn, .rightOption]
        }
    }

    /// The key to suggest to a new user. fn is skipped while the 🌐 key still has a job in
    /// System Settings (emoji picker, input source, dictation): letting go of it would trigger that.
    var suggestedKey: TriggerKey? {
        let globeBusy = (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int ?? 2) != 0
        return pushToTalkKeys.first { !(globeBusy && $0 == .fn) } ?? pushToTalkKeys.first
    }

    /// Display text like "fn or right ⌥".
    var pushToTalkDescription: String? {
        guard !pushToTalkKeys.isEmpty else { return nil }
        return ListFormatter.localizedString(byJoining: pushToTalkKeys.map(\.name))
            .replacingOccurrences(of: " and ", with: " or ")
    }

    /// The mic a take should open right now; see `AudioDevices.preferredInputUID`.
    var resolvedMicrophoneUID: String? {
        AudioDevices.preferredInputUID(selected: microphoneUID, avoidBluetooth: avoidBluetoothMic)
    }

    var locale: Locale {
        localeIdentifier.map(Locale.init(identifier:)) ?? .current
    }

    func record(_ text: String, seconds: Double? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stats.words += trimmed.split(whereSeparator: \.isWhitespace).count
        stats.dictations += 1
        stats.secondsSpoken += seconds ?? 0
        history.insert(DictationRecord(text: trimmed, date: Date()), at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
    }

    /// "Fix that" replaced the last dictation: keep History showing what was actually pasted.
    func replaceLatest(with text: String) {
        guard !history.isEmpty, !text.isEmpty else { return }
        history[0].text = text
    }

    func clearHistory() {
        history = []
    }

    private enum Keys {
        static let pushToTalkKeys = "pushToTalkKeys"
        static let legacyPushToTalkKey = "pushToTalkKey"
        static let fallbackShortcut = "fallbackShortcutEnabled"
        static let placement = "placement"
        static let showIdlePill = "showIdlePill"
        static let cameraCutout = "cameraCutout"
        static let autoPaste = "autoPaste"
        static let muffleMedia = "muffleMedia"
        static let talkMode = "talkMode"
        static let liveEdits = "liveEdits"
        static let appRules = "appRules"
        static let soundSet = "soundSet"
        static let soundVolume = "soundVolume"
        static let muffleLevel = "muffleLevel"
        static let microphoneUID = "microphoneUID"
        static let inputChannel = "inputChannel"
        static let avoidBluetoothMic = "avoidBluetoothMic"
        static let corrections = "correctionRules"
        static let spokenFormatting = "spokenFormatting"
        static let styleRewrite = "styleRewrite"
        static let adaptToApp = "adaptToApp"
        static let annotateEnabled = "annotateEnabled"
        static let laughEmoji = "laughEmoji"
        static let fixShortcut = "fixShortcut"
        static let annotateShortcut = "annotateShortcut"
        static let computerAudioShortcut = "computerAudioShortcut"
        static let styleInstructions = "styleInstructions"
        static let locale = "localeIdentifier"
        static let speechEngine = "speechEngine"
        static let history = "history"
        static let stats = "dictationStats"
    }
}
