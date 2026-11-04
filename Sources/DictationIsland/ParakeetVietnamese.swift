import CoreML

// NVIDIA Parakeet CTC 0.6B Vietnamese: FastConformer-CTC trained on Vietnamese with English
// code-switching, with punctuation and capitalisation. NVIDIA Open Model License.
//
// Runs on Core ML from OpenVoiceOS's int8 export (per-channel weights, about 600 MB): one model
// takes 15 s of 16 kHz audio to encoder frames (the mel front-end is inside it), a second maps
// frames to token log-probabilities. CTC greedy decoding is a few lines. Live text comes from
// `SegmentedTranscriber`, like the other downloaded models.

/// The downloaded model files, pinned to one Hugging Face revision.
enum ParakeetVietnameseModel {
    static let pinned = PinnedModel(
        repo: "OpenVoiceOS/parakeet-ctc-0.6b-vi-coreml-int8",
        revision: "50fd6b4ee437349025bc7ee3f9a2097447ceb315",
        folder: "parakeet-ctc-0.6b-vi",
        files: [
            ("vocab.json", 12117),
            ("parakeet_mel_encoder.mlpackage/Manifest.json", 617),
            ("parakeet_mel_encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", 713447),
            ("parakeet_mel_encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 596273408),
            ("parakeet_ctc_decoder.mlpackage/Manifest.json", 617),
            ("parakeet_ctc_decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", 2623),
            ("parakeet_ctc_decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 1059268),
        ]
    )

    static var downloadSize: Int64 { pinned.downloadSize }
    static var directory: URL { pinned.directory }
    static var isInstalled: Bool { pinned.isInstalled }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await pinned.download(progress: progress)
    }
}

// MARK: - Inference

/// The two Core ML models plus the vocabulary, loaded once and kept warm between dictations.
/// The first load compiles both packages for this Mac and keeps the result next to them.
final class ParakeetVietnameseModels: @unchecked Sendable {
    /// The encoder takes exactly 15 s (240 000 samples); shorter audio is zero-padded.
    static let windowSamples = 240_000

    private let encoder: MLModel
    private let ctc: MLModel
    /// Token pieces by ID; the CTC blank is the ID one past the end.
    private let pieces: [String]

    private init(encoder: MLModel, ctc: MLModel, pieces: [String]) {
        self.encoder = encoder
        self.ctc = ctc
        self.pieces = pieces
    }

    private static let loader = LoadOnce { try await ParakeetVietnameseModels.load() }

    /// Loaded and warm, so a dictation can start on it without waiting.
    static var isLoaded: Bool { loader.isLoaded }

    static func shared() async throws -> ParakeetVietnameseModels {
        try await loader.value()
    }

    /// Warms the models in the background so the first dictation doesn't wait for them.
    static func preload() {
        guard ParakeetVietnameseModel.isInstalled else { return }
        ModelWarmup.warm(.parakeetVietnamese) { _ = try await shared() }
    }

    private static func load() async throws -> ParakeetVietnameseModels {
        guard ParakeetVietnameseModel.isInstalled else { throw TranscriberError.unavailable }
        let directory = ParakeetVietnameseModel.directory
        @Sendable func model(_ name: String, _ units: MLComputeUnits) async throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try await MLModel.load(contentsOf: try await compiled(name, in: directory), configuration: configuration)
        }
        async let encoder = model("parakeet_mel_encoder", .cpuAndNeuralEngine)
        async let ctc = model("parakeet_ctc_decoder", .cpuOnly)
        let data = try Data(contentsOf: directory.appending(path: "vocab.json"))
        let raw = try JSONDecoder().decode([String].self, from: data)
        // Control tokens (<unk>) never belong in the text.
        let pieces = raw.map { $0.hasPrefix("<") && $0.hasSuffix(">") ? "" : $0 }
        let models = try await ParakeetVietnameseModels(encoder: encoder, ctc: ctc, pieces: pieces)
        // The Neural Engine is slow for the first couple of predictions (about 5 s, then 1 s)
        // before settling at about 0.3 s per window. Pay that here, at load, not in a dictation.
        // (The GPU is faster once warm but takes about a minute on its first prediction in every
        // new process.)
        let silence = [Float](repeating: 0, count: 16_000)
        for _ in 0..<2 { _ = try? models.decode(silence[...]) }
        return models
    }

    /// `name.mlmodelc`, compiling `name.mlpackage` the first time.
    private static func compiled(_ name: String, in directory: URL) async throws -> URL {
        let compiled = directory.appending(path: "\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) { return compiled }
        let temporary = try await MLModel.compileModel(at: directory.appending(path: "\(name).mlpackage"))
        try? FileManager.default.removeItem(at: compiled)
        try FileManager.default.moveItem(at: temporary, to: compiled)
        return compiled
    }

    /// Transcribes up to 15 s of 16 kHz mono audio.
    func decode(_ samples: ArraySlice<Float>) throws -> String {
        precondition(samples.count <= Self.windowSamples)
        let audio = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        audio.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            buffer.initialize(repeating: 0)
            _ = buffer.update(fromContentsOf: samples)
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: samples.count)

        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": audio, "audio_length": length,
        ]))
        guard let frames = encoded.featureValue(for: "encoder"),
              let frameCount = encoded.featureValue(for: "encoder_length")?.multiArrayValue?[0].intValue
        else { throw TranscriberError.unavailable }
        let out = try ctc.prediction(from: MLDictionaryFeatureProvider(dictionary: ["encoder": frames]))
        guard let logProbs = out.featureValue(for: "log_probs")?.multiArrayValue else { throw TranscriberError.unavailable }
        return text(greedy(logProbs, frames: frameCount))
    }

    /// CTC greedy search: the likeliest token per frame, repeats merged, blanks dropped.
    private func greedy(_ logProbs: MLMultiArray, frames: Int) -> [Int] {
        let count = min(frames, logProbs.shape[1].intValue)
        let classes = logProbs.shape[2].intValue
        let frameStride = logProbs.strides[1].intValue
        let classStride = logProbs.strides[2].intValue
        let blank = classes - 1
        var tokens: [Int] = []
        var previous = blank
        func best(_ score: (Int) -> Float, _ t: Int) -> Int {
            var bestID = 0
            var bestScore = -Float.infinity
            for id in 0..<classes {
                let value = score(t * frameStride + id * classStride)
                if value > bestScore { bestScore = value; bestID = id }
            }
            return bestID
        }
        for t in 0..<count {
            let id: Int
            if logProbs.dataType == .float16 {
                id = logProbs.withUnsafeBufferPointer(ofType: Float16.self) { src in best({ Float(src[$0]) }, t) }
            } else {
                id = logProbs.withUnsafeBufferPointer(ofType: Float.self) { src in best({ src[$0] }, t) }
            }
            if id != blank, id != previous { tokens.append(id) }
            previous = id
        }
        return tokens
    }

    private func text(_ tokens: [Int]) -> String {
        let joined = tokens.map { $0 < pieces.count ? pieces[$0] : "" }.joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
        // Punctuation is its own word-initial piece ("▁."), so it arrives with a space before it.
        return joined
            .replacingOccurrences(of: #"\s+([.,?!:;])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ParakeetVietnameseModels: SegmentModel {
    var maxSegmentSamples: Int { Self.windowSamples }

    func transcribe(_ samples: ArraySlice<Float>) throws -> String {
        try decode(samples)
    }
}
