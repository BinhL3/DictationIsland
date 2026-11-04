import AVFoundation
import NaturalLanguage
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

    static func transcribe(_ samples: [Float], sampleRate: Double, firstEngine: SpeechEngine?, language: Locale) async -> (text: String, engine: SpeechEngine)? {
        final class Box: @unchecked Sendable { var result: (text: String, engine: SpeechEngine)? }
        let box = Box()
        let finished = await withDeadline(deadline) {
            box.result = await choose(samples, sampleRate: sampleRate, firstEngine: firstEngine, language: language)
        }
        return finished ? box.result : nil
    }

    /// Apple's models first: already on the Mac and quick (Parakeet loaded cold took ~30 s).
    /// Only engines that know the take's language, and a result in another language is thrown
    /// away: an English model fed Vietnamese writes confident English nonsense.
    private static func choose(_ samples: [Float], sampleRate: Double, firstEngine: SpeechEngine?, language: Locale) async -> (text: String, engine: SpeechEngine)? {
        guard samples.count > Int(sampleRate * 0.2) else { return nil }
        let code = TakeLanguage.code(language)
        func heard(_ text: String?) -> String? {
            guard let text, TakeLanguage.matches(text, code) else { return nil }
            return text
        }
        if firstEngine != .appleSpeech, let text = heard(await apple(.appleSpeech, samples, sampleRate: sampleRate, locale: language)) {
            return (text, .appleSpeech)
        }
        if firstEngine != .appleDictation, let text = heard(await apple(.appleDictation, samples, sampleRate: sampleRate, locale: language)) {
            return (text, .appleDictation)
        }
        if code == "vi", firstEngine != .parakeetVietnamese, ParakeetVietnameseModel.isInstalled,
           let text = heard(await segmented(samples, sampleRate: sampleRate, model: { try await ParakeetVietnameseModels.shared() })) {
            return (text, .parakeetVietnamese)
        }
        if code == "en" || ModelChoice.Option.parakeetLanguages.contains(code), firstEngine != .parakeet, ParakeetModel.isInstalled,
           let text = heard(await segmented(samples, sampleRate: sampleRate, model: { try await ParakeetModels.shared() })) {
            return (text, .parakeet)
        }
        if code == "en", firstEngine != .bark, BarkModel.isInstalled,
           let text = heard(await segmented(samples, sampleRate: sampleRate, model: { try await BarkModels.shared() })) {
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

/// Which language a dictation is in. The engine's language is only a hint: Parakeet V3 detects
/// the language itself, and the Mac's language may not be the one spoken.
enum TakeLanguage {
    /// The text's language when it's clear, else the hint (the language the engine was set to).
    static func of(_ text: String, hint: Locale) -> Locale {
        guard let detected = detect(text), detected != code(hint) else { return hint }
        // With its usual region ("es" → es-ES): Apple's speech models are per region.
        let language = Locale.Language(identifier: detected)
        let region = Locale.Language(identifier: language.maximalIdentifier).region
        return Locale(languageCode: language.languageCode, languageRegion: region)
    }

    /// "en", "vi"… from a locale.
    static func code(_ locale: Locale) -> String {
        locale.language.languageCode?.identifier ?? "en"
    }

    /// True unless the text is clearly in another language than `code`.
    static func matches(_ text: String, _ code: String) -> Bool {
        guard let detected = detect(text) else { return true }
        return detected == code
    }

    /// The dominant language, only when the recognizer is fairly sure (short takes often aren't).
    static func detect(_ text: String) -> String? {
        guard text.split(whereSeparator: \.isWhitespace).count >= 3 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.6 else { return nil }
        // "zh-Hans" and the like: the base language is what engines and the model care about.
        return Locale(identifier: language.rawValue).language.languageCode?.identifier ?? language.rawValue
    }
}
