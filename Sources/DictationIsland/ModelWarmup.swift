import Foundation

/// Loads the downloaded models in the background and says when one is taking a while.
///
/// A cached model loads in a few seconds. The first load (and again whenever macOS clears its
/// Neural Engine cache, after an OS update say) compiles the model for this Mac, which takes
/// minutes. Dictation doesn't wait for it (it uses Apple's model meanwhile, see
/// `IslandModel.fallbackWhileLoading`), and Home and Settings show this so it isn't a mystery.
@MainActor
@Observable
final class ModelWarmup {
    static let shared = ModelWarmup()

    /// The downloaded model that's still loading after a few seconds, i.e. compiling.
    private(set) var preparing: SpeechEngine?
    @ObservationIgnored private var inFlight: Set<SpeechEngine> = []

    /// A downloaded model is loading right now. Other Core ML work in this process (the laugh
    /// detector's classifier) can wait behind its first load until it's done.
    var isLoading: Bool { !inFlight.isEmpty }

    /// Starts loading `engine` unless it's already loading.
    nonisolated static func warm(_ engine: SpeechEngine, _ load: @escaping @Sendable () async throws -> Void) {
        Task { @MainActor in shared.start(engine, load) }
    }

    private func start(_ engine: SpeechEngine, _ load: @escaping @Sendable () async throws -> Void) {
        guard inFlight.insert(engine).inserted else { return }
        let task = Task.detached(priority: .utility) { try? await load() }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if inFlight.contains(engine) { preparing = engine }
        }
        Task {
            await task.value
            inFlight.remove(engine)
            if preparing == engine { preparing = nil }
        }
    }

    /// One line for Home and Settings, or nil when nothing is getting ready.
    var message: String? {
        guard let preparing else { return nil }
        let fallback = preparing == .parakeetVietnamese ? "Apple Dictation" : "Apple Speech"
        return "Optimizing \(preparing.shortName) for this Mac's Neural Engine, \(Self.setupTime(preparing)) and only once. Dictating with \(fallback) until then."
    }

    /// How long the one-time compile takes (measured on an M1 Pro: Bark ~4 min, Parakeet ~25 s);
    /// `short` for the island.
    static func setupTime(_ engine: SpeechEngine, short: Bool = false) -> String {
        switch (engine, short) {
        case (.bark, false): return "about 4 minutes"
        case (.bark, true): return "~4 min"
        case (.parakeet, false): return "about 30 seconds"
        case (.parakeet, true): return "~30 s"
        case (_, false): return "a few minutes"
        case (_, true): return "a few min"
        }
    }
}
