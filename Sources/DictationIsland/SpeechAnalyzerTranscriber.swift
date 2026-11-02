import AVFoundation
import Speech

/// Which speech model turns audio into text.
enum SpeechEngine: String, CaseIterable, Identifiable {
    /// Apple Speech if the language supports it, else Apple Dictation, else legacy.
    case automatic
    /// `SpeechTranscriber`: Apple's newest on-device model (macOS 26+), the one behind
    /// Notes and Voice Memos transcription. Fast, accurate, long-form, automatic punctuation.
    case appleSpeech
    /// `DictationTranscriber`: the model behind macOS keyboard dictation. Covers more languages,
    /// optimised for short dictated phrases.
    case appleDictation
    /// Underdog Bark 3.0 on Core ML: Parakeet V3 post-trained for English. A one-time ~200 MB
    /// download; English only.
    case bark
    /// NVIDIA Parakeet TDT 0.6B v3 on Core ML: Handy's and Noi's recommended model. A one-time
    /// ~630 MB download; 25 European languages, detected automatically.
    case parakeet
    /// `SFSpeechRecognizer`: the pre-macOS 26 API.
    case legacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic (best available)"
        case .appleSpeech: return "Apple Speech (newest model)"
        case .appleDictation: return "Apple Dictation (system dictation model)"
        case .bark: return "Underdog Bark 3.0 (download, English)"
        case .parakeet: return "NVIDIA Parakeet V3 (download)"
        case .legacy: return "Legacy Speech Recognizer"
        }
    }

    var shortName: String {
        switch self {
        case .automatic: return "Automatic"
        case .appleSpeech: return "Apple Speech"
        case .appleDictation: return "Apple Dictation"
        case .bark: return "Bark 3.0"
        case .parakeet: return "Parakeet V3"
        case .legacy: return "Legacy"
        }
    }
}

/// Resolves the engine for a locale and checks whether its on-device model is installed.
enum SpeechModelCatalog {
    struct Resolution {
        var engine: SpeechEngine
        var locale: Locale
    }

    enum ModelStatus: Equatable {
        case installed
        case downloadable
        case unsupported
    }

    static func resolve(_ preference: SpeechEngine, locale: Locale) async -> Resolution {
        switch preference {
        case .appleSpeech:
            if let supported = await speechLocale(for: locale) { return Resolution(engine: .appleSpeech, locale: supported) }
        case .appleDictation:
            if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                return Resolution(engine: .appleDictation, locale: supported)
            }
        case .automatic:
            if let supported = await speechLocale(for: locale) { return Resolution(engine: .appleSpeech, locale: supported) }
            if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                return Resolution(engine: .appleDictation, locale: supported)
            }
        case .bark:
            return Resolution(engine: .bark, locale: locale)
        case .parakeet:
            return Resolution(engine: .parakeet, locale: locale)
        case .legacy:
            break
        }
        return Resolution(engine: .legacy, locale: locale)
    }

    static func status(of resolution: Resolution) async -> ModelStatus {
        switch resolution.engine {
        case .appleSpeech:
            let installed = await SpeechTranscriber.installedLocales
            return installed.contains { $0.identifier(.bcp47) == resolution.locale.identifier(.bcp47) } ? .installed : .downloadable
        case .appleDictation:
            let installed = await DictationTranscriber.installedLocales
            return installed.contains { $0.identifier(.bcp47) == resolution.locale.identifier(.bcp47) } ? .installed : .downloadable
        case .bark:
            return BarkModel.isInstalled ? .installed : .downloadable
        case .parakeet:
            return ParakeetModel.isInstalled ? .installed : .downloadable
        case .legacy:
            return .installed
        case .automatic:
            return .unsupported
        }
    }

    /// Downloads the on-device model if needed. `progress` reports 0...1.
    static func install(_ resolution: Resolution, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if resolution.engine == .bark {
            try await BarkModel.download { progress?($0) }
            // The first load compiles the encoder for this Mac, which takes minutes. Do it here,
            // while the island shows the download, rather than silently during a dictation.
            _ = try await BarkModels.shared()
            return
        }
        if resolution.engine == .parakeet {
            try await ParakeetModel.download { progress?($0) }
            ParakeetModels.preload()
            return
        }
        guard let module = makeModule(resolution) else { return }
        _ = try? await AssetInventory.reserve(locale: resolution.locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let observation = progress.map { report in
            request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in report(p.fractionCompleted) }
        }
        defer { observation?.invalidate() }
        try await request.downloadAndInstall()
    }

    static func makeModule(_ resolution: Resolution) -> (any SpeechModule)? {
        switch resolution.engine {
        case .appleSpeech:
            return SpeechTranscriber(
                locale: resolution.locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )
        case .appleDictation:
            return DictationTranscriber(
                locale: resolution.locale,
                contentHints: [.shortForm],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: []
            )
        case .bark, .parakeet, .legacy, .automatic:
            return nil
        }
    }

    private static func speechLocale(for locale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }
}

/// Streams mic audio through `SpeechAnalyzer` with either `SpeechTranscriber` or
/// `DictationTranscriber`. Volatile (in-progress) results replace each other; finalized results
/// accumulate, which is what keeps the live transcript stable while it is still being refined.
final class SpeechAnalyzerTranscriber: Transcriber {
    var onPartial: ((String) -> Void)?
    /// Reported while a missing model downloads (0...1).
    var onModelDownload: ((Double) -> Void)?
    /// Names and jargon the recognizer should favour (from the corrections list).
    var contextualStrings: [String] = []
    /// How long `finish` waits for the last result before using the text it already has.
    static let finishDeadline: Duration = .seconds(3)

    private let resolution: SpeechModelCatalog.Resolution
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var finalized = ""
    private var volatile = ""

    init(resolution: SpeechModelCatalog.Resolution) {
        self.resolution = resolution
    }

    /// SpeechAnalyzer runs on-device without the Speech Recognition permission (only the Legacy
    /// engine needs it), so there's no prompt in the middle of someone's first dictation.
    func requestPermission() async -> Bool { true }

    func begin(locale: Locale) async throws {
        guard let module = SpeechModelCatalog.makeModule(resolution) else { throw TranscriberError.unavailable }
        finalized = ""
        volatile = ""

        if await SpeechModelCatalog.status(of: resolution) != .installed {
            let report = onModelDownload
            try await SpeechModelCatalog.install(resolution) { fraction in
                DispatchQueue.main.async { report?(fraction) }
            }
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError.unavailable
        }
        targetFormat = format
        converter = nil

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        // `.lingering` keeps the model loaded between takes, so the next first partial comes sooner.
        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        self.analyzer = analyzer
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(context)
        }

        resultsTask = Task { [weak self] in
            do {
                if let transcriber = module as? SpeechTranscriber {
                    for try await result in transcriber.results {
                        await self?.receive(String(result.text.characters), isFinal: result.isFinal)
                    }
                } else if let transcriber = module as? DictationTranscriber {
                    for try await result in transcriber.results {
                        await self?.receive(String(result.text.characters), isFinal: result.isFinal)
                    }
                }
            } catch {
                // Cancellation or analyzer shutdown; whatever was finalized is kept.
            }
        }

        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
    }

    /// Called on the audio thread with mono Float32 buffers at the device rate.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let input, let converted = convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async -> String {
        input?.finish()
        input = nil
        let analyzer = self.analyzer, results = resultsTask
        self.analyzer = nil
        resultsTask = nil
        if let analyzer {
            let finished = await withDeadline(Self.finishDeadline) {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                await results?.value
            }
            if !finished {
                // The analyzer hung; keep the finalized + volatile text it already gave us.
                results?.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        }
        return await MainActor.run { combined() }
    }

    func cancel() {
        input?.finish()
        input = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            self.analyzer = nil
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    @MainActor
    private func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
        onPartial?(combined())
    }

    private func combined() -> String {
        Self.join(finalized, volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func join(_ head: String, _ tail: String) -> String {
        guard !head.isEmpty, !tail.isEmpty else { return head + tail }
        if head.last?.isWhitespace == true || tail.first?.isWhitespace == true { return head + tail }
        return head + " " + tail
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat else { return nil }
        if buffer.format == targetFormat { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
