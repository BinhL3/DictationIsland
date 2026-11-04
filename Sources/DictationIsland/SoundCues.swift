import AVFoundation
import AppKit

/// Short sounds at the moments of a dictation, so you know it heard the key without looking:
/// start, stop (at the release, like Hex), and for the Signature set done and error too.
/// The sound sets are Hex's (MIT), bundled in Resources/Sounds.
enum SoundSet: String, CaseIterable, Identifiable {
    case off
    case classic
    case signature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .classic: return "Classic (clicks)"
        case .signature: return "Signature (kalimba)"
        }
    }
}

enum SoundCue: String {
    case start, stop, done, error
}

@MainActor
enum SoundCues {
    /// Players are made ahead of time: a cue that lags the key is worse than none.
    private static var players: [String: AVAudioPlayer] = [:]

    static func preload() {
        for set in SoundSet.allCases where set != .off {
            for cue in [SoundCue.start, .stop, .done, .error] { _ = player(set, cue) }
        }
    }

    static func play(_ cue: SoundCue) {
        let settings = AppSettings.shared
        guard settings.soundSet != .off, let player = player(settings.soundSet, cue) else {
            // Classic has no error sound of its own; macOS's Basso, as Hex does.
            if cue == .error, settings.soundSet == .classic { NSSound(named: "Basso")?.play() }
            return
        }
        player.volume = Float(settings.soundVolume)
        player.currentTime = 0
        player.play()
    }

    /// How long `cue` sounds when played now; 0 when sound cues are off or silent.
    static func audibleLength(_ cue: SoundCue) -> TimeInterval {
        let settings = AppSettings.shared
        guard settings.soundSet != .off, settings.soundVolume > 0,
              let player = player(settings.soundSet, cue) else { return 0 }
        return player.duration
    }

    /// For the Settings picker.
    static func audition(_ set: SoundSet) {
        guard set != .off else { return }
        let volume = Float(AppSettings.shared.soundVolume)
        for (cue, delay) in [(SoundCue.start, 0.0), (.stop, 0.9), (.done, 1.4)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard let player = player(set, cue) else { return }
                    player.volume = volume
                    player.currentTime = 0
                    player.play()
                }
            }
        }
    }

    private static func player(_ set: SoundSet, _ cue: SoundCue) -> AVAudioPlayer? {
        let key = "\(set.rawValue)/\(cue.rawValue)"
        if let player = players[key] { return player }
        guard let url = Bundle.main.resourceURL?.appending(path: "Sounds/\(key).wav"),
              FileManager.default.fileExists(atPath: url.path),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        players[key] = player
        return player
    }
}
