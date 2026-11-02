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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "In the notch (automatic)"
        case .menuBar: return "In the notch / menu bar"
        case .belowMenuBar: return "Below the menu bar"
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
    var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Keys.autoPaste) }
    }
    /// Muffle music and videos while dictating.
    var muffleMedia: Bool {
        didSet { defaults.set(muffleMedia, forKey: Keys.muffleMedia) }
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
        autoPaste = defaults.object(forKey: Keys.autoPaste) as? Bool ?? true
        muffleMedia = defaults.object(forKey: Keys.muffleMedia) as? Bool ?? true
        muffleLevel = defaults.object(forKey: Keys.muffleLevel) as? Double ?? 0.2
        microphoneUID = defaults.string(forKey: Keys.microphoneUID)
        inputChannel = defaults.string(forKey: Keys.inputChannel).flatMap(InputChannel.init) ?? .mix
        avoidBluetoothMic = defaults.object(forKey: Keys.avoidBluetoothMic) as? Bool ?? true
        let correctionsText = defaults.string(forKey: Keys.corrections) ?? ""
        self.correctionsText = correctionsText
        corrections = Corrections(correctionsText)
        spokenFormatting = defaults.object(forKey: Keys.spokenFormatting) as? Bool ?? true
        styleRewrite = defaults.bool(forKey: Keys.styleRewrite)
        annotateEnabled = defaults.object(forKey: Keys.annotateEnabled) as? Bool ?? true
        styleInstructions = defaults.string(forKey: Keys.styleInstructions) ?? ""
        localeIdentifier = defaults.string(forKey: Keys.locale)
        speechEngine = defaults.string(forKey: Keys.speechEngine).flatMap(SpeechEngine.init) ?? .automatic
        let savedHistory = defaults.data(forKey: Keys.history).flatMap { try? JSONDecoder().decode([DictationRecord].self, from: $0) } ?? []
        // Before stats existed, history is the best estimate of what's been dictated.
        stats = defaults.data(forKey: Keys.stats).flatMap { try? JSONDecoder().decode(DictationStats.self, from: $0) }
            ?? DictationStats(words: savedHistory.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }, dictations: savedHistory.count)
        history = savedHistory
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

    func clearHistory() {
        history = []
    }

    private enum Keys {
        static let pushToTalkKeys = "pushToTalkKeys"
        static let legacyPushToTalkKey = "pushToTalkKey"
        static let fallbackShortcut = "fallbackShortcutEnabled"
        static let placement = "placement"
        static let showIdlePill = "showIdlePill"
        static let autoPaste = "autoPaste"
        static let muffleMedia = "muffleMedia"
        static let muffleLevel = "muffleLevel"
        static let microphoneUID = "microphoneUID"
        static let inputChannel = "inputChannel"
        static let avoidBluetoothMic = "avoidBluetoothMic"
        static let corrections = "correctionRules"
        static let spokenFormatting = "spokenFormatting"
        static let styleRewrite = "styleRewrite"
        static let annotateEnabled = "annotateEnabled"
        static let styleInstructions = "styleInstructions"
        static let locale = "localeIdentifier"
        static let speechEngine = "speechEngine"
        static let history = "history"
        static let stats = "dictationStats"
    }
}
