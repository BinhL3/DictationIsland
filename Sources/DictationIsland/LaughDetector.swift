import AVFoundation
import SoundAnalysis

/// Hears laughter during a take with Apple's built-in sound classifier (SoundAnalysis, on-device)
/// and remembers when it happened, so the transcript can carry the emotion: a 😂 lands roughly
/// where you laughed. The island's dot also turns into the emoji while you're laughing.
final class LaughDetector: NSObject, SNResultsObserving, @unchecked Sendable {
    struct Laugh: Equatable {
        /// Seconds from the start of the take.
        let time: Double
        let emoji: String
    }

    /// Classifier labels → emoji, strongest first (the first label over the bar wins).
    private static let kinds: [(label: String, emoji: String)] = [
        ("belly_laugh", "🤣"),
        ("laughter", "😂"),
        ("giggling", "😆"),
        ("chuckle_chortle", "😄"),
        ("snicker", "😄"),
    ]
    private static let threshold = 0.5
    /// Laughs closer than this are one laugh.
    private static let merge = 2.0

    /// Called on the main queue while laughter is heard (the emoji) and when it stops (nil).
    var onLaughing: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "DictationIsland.laughs")
    private var analyzer: SNAudioStreamAnalyzer?
    private var format: AVAudioFormat?
    private var framePosition: AVAudioFramePosition = 0
    private var laughs: [Laugh] = []
    private var lastLaughAt = -Double.infinity
    private var quietTask: DispatchWorkItem?

    /// Audio thread: one mono buffer from the mic.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        queue.async { [self] in
            if analyzer == nil || format != copy.format {
                format = copy.format
                framePosition = 0
                let analyzer = SNAudioStreamAnalyzer(format: copy.format)
                guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return }
                // Shorter windows than the 3 s default, so a quick laugh is caught and placed.
                request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 1000)
                request.overlapFactor = 0.5
                try? analyzer.add(request, withObserver: self)
                self.analyzer = analyzer
            }
            analyzer?.analyze(copy, atAudioFramePosition: framePosition)
            framePosition += AVAudioFramePosition(copy.frameLength)
        }
    }

    /// The laughs heard in this take, once the remaining audio is analysed. Gives up (no laughs)
    /// after `finishDeadline`: the classifier's model can be stuck loading behind a speech model's
    /// first Core ML load for minutes, and an emoji must never hold up the paste.
    func finish() async -> [Laugh] {
        final class Found: @unchecked Sendable { var laughs: [Laugh] = [] }
        let found = Found()
        let finished = await withDeadline(Self.finishDeadline) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.queue.async { [self] in
                    analyzer?.completeAnalysis()
                    analyzer = nil
                    found.laughs = laughs
                    continuation.resume()
                }
            }
        }
        return finished ? found.laughs : []
    }

    private static let finishDeadline: Duration = .seconds(2)

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let hit = Self.kinds.first { kind in
            (result.classification(forIdentifier: kind.label)?.confidence ?? 0) >= Self.threshold
        }
        guard let hit else { return }
        let time = result.timeRange.start.seconds + result.timeRange.duration.seconds / 2
        if time - lastLaughAt > Self.merge {
            laughs.append(Laugh(time: time, emoji: hit.emoji))
        } else if let last = laughs.last, Self.rank(hit.emoji) < Self.rank(last.emoji) {
            // The same laugh got bigger: keep the bigger emoji.
            laughs[laughs.count - 1] = Laugh(time: last.time, emoji: hit.emoji)
        }
        lastLaughAt = time
        let emoji = laughs.last?.emoji
        DispatchQueue.main.async { [weak self] in
            self?.onLaughing?(emoji)
            self?.quietTask?.cancel()
            let quiet = DispatchWorkItem { [weak self] in self?.onLaughing?(nil) }
            self?.quietTask = quiet
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: quiet)
        }
    }

    private static func rank(_ emoji: String) -> Int {
        kinds.firstIndex { $0.emoji == emoji } ?? kinds.count
    }

    /// The tap reuses its buffers; analysis runs later on our queue, so keep a copy.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let destination = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel], count: Int(buffer.frameLength))
        }
        return copy
    }

    /// Puts each laugh's emoji into the text at about the moment it happened: the text is
    /// spread over the take's duration, and the emoji goes after the nearest sentence end (or
    /// word) at that point. Laughs near the end go at the end.
    static func insert(_ laughs: [Laugh], into text: String, duration: Double) -> String {
        guard !laughs.isEmpty, !text.isEmpty, duration > 0 else { return text }
        var result = text
        // Insert from the back so earlier positions stay valid.
        for laugh in laughs.sorted(by: { $0.time > $1.time }) {
            let fraction = min(max(laugh.time / duration, 0), 1)
            let characters = Array(result)
            if fraction > 0.85 || characters.isEmpty {
                result = result.trimmingCharacters(in: .whitespaces) + " " + laugh.emoji
                continue
            }
            let target = Int(Double(characters.count) * fraction)
            var index = target
            // A sentence end within reach reads best ("That's hilarious. 😂 Anyway").
            // Nearest sentence end, a little behind (the laugh usually follows the funny line) or ahead.
            let window = max(0, target - 15)..<min(characters.count, target + 40)
            if let end = window.filter({ ".!?".contains(characters[$0]) }).min(by: { abs($0 - target) < abs($1 - target) }) {
                index = end + 1
            } else {
                while index < characters.count, !characters[index].isWhitespace { index += 1 }
            }
            let head = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
            let tail = String(characters[index...]).trimmingCharacters(in: .whitespaces)
            result = tail.isEmpty ? head + " " + laugh.emoji : head + " " + laugh.emoji + " " + tail
        }
        return result
    }
}
