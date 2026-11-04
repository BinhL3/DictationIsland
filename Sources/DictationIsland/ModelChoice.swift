import Foundation

/// The speech model picked during setup. Downloaded models come in the background: dictation
/// uses Apple's built-in model until the pick is ready, then switches to it by itself, even if
/// setup was closed long before.
@MainActor
@Observable
final class ModelChoice {
    static let shared = ModelChoice()

    enum Option: String, CaseIterable, Identifiable {
        case bark, parakeet, vietnamese, apple

        var id: String { rawValue }

        var engine: SpeechEngine {
            switch self {
            case .bark: return .bark
            case .parakeet: return .parakeet
            case .vietnamese: return .parakeetVietnamese
            case .apple: return .automatic
            }
        }

        var title: String {
            switch self {
            case .bark: return "Bark 3.0"
            case .parakeet: return "Parakeet V3"
            case .vietnamese: return "Parakeet Tiếng Việt"
            case .apple: return "Apple Speech"
            }
        }

        var summary: String {
            switch self {
            case .bark: return "The most accurate for English."
            case .parakeet: return "25 European languages, detected as you speak."
            case .vietnamese: return "Vietnamese, with English words mixed in."
            case .apple: return "Built into macOS, in many languages."
            }
        }

        /// Download size, or nil for Apple's model (macOS manages that one).
        var size: String? {
            let bytes: Int64
            switch self {
            case .bark: bytes = BarkModel.downloadSize
            case .parakeet: bytes = ParakeetModel.downloadSize
            case .vietnamese: bytes = ParakeetVietnameseModel.downloadSize
            case .apple: return nil
            }
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }

        var isInstalled: Bool {
            switch self {
            case .bark: return BarkModel.isInstalled
            case .parakeet: return ParakeetModel.isInstalled
            case .vietnamese: return ParakeetVietnameseModel.isInstalled
            case .apple: return true
            }
        }

        /// Bark for English, Parakeet for the other languages it covers, otherwise Apple's.
        static func recommended(for locale: Locale) -> Option {
            let language = locale.language.languageCode?.identifier ?? "en"
            if language == "en" { return .bark }
            if language == "vi" { return .vietnamese }
            return parakeetLanguages.contains(language) ? .parakeet : .apple
        }

        static let parakeetLanguages: Set<String> = [
            "bg", "hr", "cs", "da", "nl", "et", "fi", "fr", "de", "el", "hu", "it", "lv",
            "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
        ]
    }

    enum State: Equatable {
        case idle
        case downloading(Double)
        /// Bark compiles itself for this Mac's Neural Engine on first load; that takes minutes.
        case preparing
        case ready
        case failed
    }

    private(set) var selected: Option?
    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    var recommended: Option { .recommended(for: AppSettings.shared.locale) }

    /// Setup calls this when it appears: shows what's already in use, or picks the
    /// recommendation for a fresh install.
    func startIfNeeded() {
        guard selected == nil else { return }
        switch AppSettings.shared.speechEngine {
        case .bark: BarkModel.isInstalled ? adopt(.bark) : choose(.bark)
        case .parakeet: ParakeetModel.isInstalled ? adopt(.parakeet) : choose(.parakeet)
        case .parakeetVietnamese: ParakeetVietnameseModel.isInstalled ? adopt(.vietnamese) : choose(.vietnamese)
        case .automatic: choose(recommended)
        default: adopt(.apple)  // something picked by hand in Settings; leave it be
        }
    }

    func choose(_ option: Option) {
        if option == selected, state != .failed { return }
        task?.cancel()
        task = nil
        selected = option
        let settings = AppSettings.shared
        if option.isInstalled {
            settings.speechEngine = option.engine
            state = .ready
            return
        }
        // Apple's model covers dictation (and Try it) until this one is ready.
        settings.speechEngine = .automatic
        state = .downloading(0)
        task = Task { [weak self] in
            do {
                let report: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor in
                        guard let self, self.selected == option, case .downloading = self.state else { return }
                        self.state = .downloading(fraction)
                    }
                }
                switch option {
                case .bark: try await BarkModel.download(progress: report)
                case .parakeet: try await ParakeetModel.download(progress: report)
                case .vietnamese: try await ParakeetVietnameseModel.download(progress: report)
                case .apple: break
                }
                try Task.checkCancellation()
                if option == .bark {
                    self?.state = .preparing
                    _ = try await BarkModels.shared()
                }
                if option == .vietnamese {
                    self?.state = .preparing
                    _ = try await ParakeetVietnameseModels.shared()
                }
                try Task.checkCancellation()
                guard let self, self.selected == option else { return }
                // Only switch if nobody has picked another engine in Settings meanwhile.
                if AppSettings.shared.speechEngine == .automatic { AppSettings.shared.speechEngine = option.engine }
                self.state = .ready
            } catch {
                guard let self, !Task.isCancelled, self.selected == option else { return }
                self.state = .failed
            }
        }
    }

    /// `--setup-preview`: a fresh install's picker partway through its download, for screenshots.
    func showPreview() {
        selected = recommended
        state = .downloading(0.42)
    }

    private func adopt(_ option: Option) {
        selected = option
        state = .ready
    }
}
