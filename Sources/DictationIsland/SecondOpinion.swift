import AVFoundation
import Speech
import os

/// Keeps a take's audio (mono, at the mic's rate) so "Fix that" can listen again. Written on the
/// mic thread, read once the take is done. Capped so a very long hands-free take can't grow
/// without bound.
final class TakeRecording: @unchecked Sendable {
    static let maxSeconds = 180.0
    private var lock = os_unfair_lock()
    private var samples: [Float] = []
    private(set) var sampleRate: Double = 48_000

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        sampleRate = buffer.format.sampleRate
        guard Double(samples.count) < Self.maxSeconds * sampleRate else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    var audio: (samples: [Float], sampleRate: Double) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (samples, sampleRate)
    }
}

/// "Fix that", part one: transcribe the same audio again with a *different* engine, since the
/// first one evidently misheard it. Apple Speech when the take used Bark or Parakeet, Parakeet
/// (or Bark) when it used Apple's engines. Returns nil when no other engine is available.
enum SecondOpinion {
    /// The whole second listen gives up after this; a slow fix isn't a fix.
    static let deadline: Duration = .seconds(8)

    static func transcribe(_ samples: [Float], sampleRate: Double, firstEngine: SpeechEngine?, locale: Locale) async -> (text: String, engine: SpeechEngine)? {
        final class Box: @unchecked Sendable { var result: (text: String, engine: SpeechEngine)? }
        let box = Box()
        let finished = await withDeadline(deadline) {
            box.result = await choose(samples, sampleRate: sampleRate, firstEngine: firstEngine, locale: locale)
        }
        return finished ? box.result : nil
    }

    /// Apple's models first: already on the Mac and quick (Parakeet loaded cold took ~30 s).
    private static func choose(_ samples: [Float], sampleRate: Double, firstEngine: SpeechEngine?, locale: Locale) async -> (text: String, engine: SpeechEngine)? {
        guard samples.count > Int(sampleRate * 0.2) else { return nil }
        if firstEngine != .appleSpeech, let text = await apple(.appleSpeech, samples, sampleRate: sampleRate, locale: locale) {
            return (text, .appleSpeech)
        }
        if firstEngine != .appleDictation, let text = await apple(.appleDictation, samples, sampleRate: sampleRate, locale: locale) {
            return (text, .appleDictation)
        }
        if firstEngine != .parakeet, ParakeetModel.isInstalled,
           let text = await segmented(samples, sampleRate: sampleRate, model: { try await ParakeetModels.shared() }) {
            return (text, .parakeet)
        }
        if firstEngine != .bark, BarkModel.isInstalled,
           let text = await segmented(samples, sampleRate: sampleRate, model: { try await BarkModels.shared() }) {
            return (text, .bark)
        }
        return nil
    }

    /// One of Apple's on-device models (Speech or Dictation) over the whole clip, via a temp file.
    private static func apple(_ engine: SpeechEngine, _ samples: [Float], sampleRate: Double, locale: Locale) async -> String? {
        let resolution = await SpeechModelCatalog.resolve(engine, locale: locale)
        guard resolution.engine == engine,
              await SpeechModelCatalog.status(of: resolution) == .installed,
              let module = SpeechModelCatalog.makeModule(resolution),
              let url = try? writeWAV(samples, sampleRate: sampleRate),
              let file = try? AVAudioFile(forReading: url)
        else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let collector = Task { () -> String in
            var text = ""
            func add(_ piece: String) {
                let piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { text += (text.isEmpty ? "" : " ") + piece }
            }
            if let transcriber = module as? SpeechTranscriber {
                for try await result in transcriber.results where result.isFinal { add(String(result.text.characters)) }
            } else if let transcriber = module as? DictationTranscriber {
                for try await result in transcriber.results where result.isFinal { add(String(result.text.characters)) }
            }
            return text
        }
        guard let analyzer = try? await SpeechAnalyzer(inputAudioFile: file, modules: [module], finishAfterFile: true) else {
            collector.cancel()
            return nil
        }
        let text = (try? await collector.value) ?? ""
        withExtendedLifetime(analyzer) {}
        return text.isEmpty ? nil : text
    }

    /// A Core ML engine (Parakeet, Bark), fed the clip in mic-sized chunks.
    private static func segmented(_ samples: [Float], sampleRate: Double, model: @escaping () async throws -> any SegmentModel) async -> String? {
        let transcriber = SegmentedTranscriber(model: model)
        guard (try? await transcriber.begin(locale: .current)) != nil,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        var offset = 0
        while offset < samples.count {
            let count = min(4096, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
            }
            transcriber.append(buffer)
            offset += count
        }
        let text = await transcriber.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func writeWAV(_ samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictationisland-fix-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw TranscriberError.unavailable
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
