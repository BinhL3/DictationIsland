import CoreML

// NVIDIA Parakeet TDT 0.6B v3: the model Handy and Noi recommend. 25 European languages,
// auto-detected, with punctuation and capitalisation.
//
// Runs on Core ML (Neural Engine) from FluidInference's CoreML export of the NVIDIA weights
// (CC-BY-4.0). No third-party code: preprocessing, the encoder and the joint network are Core ML
// models, and the TDT greedy decode below is ~80 lines. Live text comes from `SegmentedTranscriber`.

/// The downloaded model files, pinned to one Hugging Face revision.
enum ParakeetModel {
    static let pinned = PinnedModel(
        repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
        folder: "parakeet-tdt-0.6b-v3",
        files: [
            ("Preprocessor.mlmodelc/analytics/coremldata.bin", 243),
            ("Preprocessor.mlmodelc/coremldata.bin", 486),
            ("Preprocessor.mlmodelc/metadata.json", 2841),
            ("Preprocessor.mlmodelc/model.mil", 28181),
            ("Preprocessor.mlmodelc/weights/weight.bin", 491072),
            // Int8 per-channel re-quantisation; the original 6-bit palettised encoder corrupts tokens
            // in some contexts (FluidAudio issue #760).
            ("Encoder_v2.mlmodelc/analytics/coremldata.bin", 243),
            ("Encoder_v2.mlmodelc/coremldata.bin", 478),
            ("Encoder_v2.mlmodelc/model.mil", 1002653),
            ("Encoder_v2.mlmodelc/weights/weight.bin", 594211328),
            ("Decoder.mlmodelc/analytics/coremldata.bin", 243),
            ("Decoder.mlmodelc/coremldata.bin", 554),
            ("Decoder.mlmodelc/metadata.json", 3427),
            ("Decoder.mlmodelc/model.mil", 13110),
            ("Decoder.mlmodelc/weights/weight.bin", 23604992),
            ("JointDecision.mlmodelc/analytics/coremldata.bin", 243),
            ("JointDecision.mlmodelc/coremldata.bin", 534),
            ("JointDecision.mlmodelc/metadata.json", 2936),
            ("JointDecision.mlmodelc/model.mil", 9723),
            ("JointDecision.mlmodelc/weights/weight.bin", 12642764),
            ("parakeet_v3_vocab.json", 151122),
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

/// The four Core ML models plus the vocabulary, loaded once and kept warm between dictations
/// (the first load compiles the encoder for the Neural Engine, which takes a while).
final class ParakeetModels: @unchecked Sendable {
    /// The preprocessor takes exactly 15 s (240 000 samples); shorter audio is zero-padded.
    static let windowSamples = 240_000
    static let blankID = 8192

    let preprocessor: MLModel
    let encoder: MLModel
    let decoder: MLModel
    let joint: MLModel
    private let vocabulary: [Int: String]
    /// The prediction network after the start-of-sequence blank; every segment decodes from it.
    private var freshState: DecoderState?

    private init(preprocessor: MLModel, encoder: MLModel, decoder: MLModel, joint: MLModel, vocabulary: [Int: String]) {
        self.preprocessor = preprocessor
        self.encoder = encoder
        self.decoder = decoder
        self.joint = joint
        self.vocabulary = vocabulary
    }

    private static let loader = LoadOnce { try await ParakeetModels.load() }

    /// Loads once; concurrent callers share the same load.
    static func shared() async throws -> ParakeetModels {
        try await loader.value()
    }

    /// Warms the models in the background so the first dictation doesn't wait for them.
    static func preload() {
        guard ParakeetModel.isInstalled else { return }
        Task.detached(priority: .utility) { _ = try? await shared() }
    }

    private static func load() async throws -> ParakeetModels {
        guard ParakeetModel.isInstalled else { throw TranscriberError.unavailable }
        let directory = ParakeetModel.directory
        @Sendable func model(_ name: String, _ units: MLComputeUnits) async throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try await MLModel.load(contentsOf: directory.appending(path: name), configuration: configuration)
        }
        // The mel front-end is cheap and most accurate on the CPU; the rest targets the Neural Engine.
        async let preprocessor = model("Preprocessor.mlmodelc", .cpuOnly)
        async let encoder = model("Encoder_v2.mlmodelc", .cpuAndNeuralEngine)
        async let decoder = model("Decoder.mlmodelc", .cpuAndNeuralEngine)
        async let joint = model("JointDecision.mlmodelc", .cpuAndNeuralEngine)

        let data = try Data(contentsOf: directory.appending(path: "parakeet_v3_vocab.json"))
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        var vocabulary: [Int: String] = [:]
        for (key, piece) in raw {
            guard let id = Int(key) else { continue }
            // Control tokens (<unk>, <|endoftext|>, …) never belong in the text.
            vocabulary[id] = piece.hasPrefix("<") && piece.hasSuffix(">") ? "" : piece
        }
        let models = try await ParakeetModels(
            preprocessor: preprocessor, encoder: encoder, decoder: decoder, joint: joint, vocabulary: vocabulary
        )
        models.freshState = try models.initialState()
        return models
    }

    func text(_ tokens: [Int]) -> String {
        tokens.map { vocabulary[$0] ?? "" }.joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prediction-network state after consuming `lastToken`: its output `g` and LSTM state.
    struct DecoderState {
        var lastToken: Int
        var g: MLMultiArray
        var h: MLMultiArray
        var c: MLMultiArray
    }

    func initialState() throws -> DecoderState {
        let zeros = { try MLMultiArray(shape: [2, 1, 640], dataType: .float32).zeroed() }
        let (g, h, c) = try predict(token: Self.blankID, h: zeros(), c: zeros())
        return DecoderState(lastToken: Self.blankID, g: g, h: h, c: c)
    }

    /// Transcribes up to 15 s of 16 kHz mono audio, continuing from `state`.
    func decode(_ samples: ArraySlice<Float>, from state: DecoderState) throws -> (tokens: [Int], state: DecoderState) {
        precondition(samples.count <= Self.windowSamples)
        let audio = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32).zeroed()
        audio.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            _ = buffer.update(fromContentsOf: samples)
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: samples.count)

        let mel = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": audio, "audio_length": length,
        ]))
        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": mel.featureValue(for: "mel")!, "mel_length": mel.featureValue(for: "mel_length")!,
        ]))
        guard let frames = encoded.featureValue(for: "encoder")?.multiArrayValue,
              let frameCount = encoded.featureValue(for: "encoder_length")?.multiArrayValue?[0].intValue
        else { throw TranscriberError.unavailable }

        return try greedyDecode(frames: frames, count: min(frameCount, frames.shape[2].intValue), state: state)
    }

    /// Token-and-Duration Transducer greedy search: at each encoder frame the joint network picks a
    /// token and how many frames to skip. Blanks don't touch the prediction network.
    private func greedyDecode(frames: MLMultiArray, count: Int, state: DecoderState) throws -> (tokens: [Int], state: DecoderState) {
        let maxSymbolsPerFrame = 10
        var state = state
        var tokens: [Int] = []
        let frame = try MLMultiArray(shape: [1, 1024, 1], dataType: .float32)
        var t = 0
        var symbolsHere = 0
        var loadedFrame = -1

        while t < count {
            if loadedFrame != t {
                copyFrame(t, of: frames, into: frame)
                loadedFrame = t
            }
            let out = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "encoder_step": frame, "decoder_step": state.g,
            ]))
            let token = out.featureValue(for: "token_id")!.multiArrayValue![0].intValue
            var duration = out.featureValue(for: "duration")!.multiArrayValue![0].intValue

            if token != Self.blankID {
                tokens.append(token)
                let (g, h, c) = try predict(token: token, h: state.h, c: state.c)
                state = DecoderState(lastToken: token, g: g, h: h, c: c)
                symbolsHere += 1
                // Several tokens may share a frame, but never unboundedly.
                if duration == 0 && symbolsHere >= maxSymbolsPerFrame { duration = 1 }
            } else if duration == 0 {
                duration = 1
            }
            if duration > 0 {
                t += duration
                symbolsHere = 0
            }
        }
        return (tokens, state)
    }

    private func predict(token: Int, h: MLMultiArray, c: MLMultiArray) throws -> (MLMultiArray, MLMultiArray, MLMultiArray) {
        let target = try MLMultiArray(shape: [1, 1], dataType: .int32)
        target[0] = NSNumber(value: token)
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = 1
        let out = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": target, "target_length": length, "h_in": h, "c_in": c,
        ]))
        return (
            out.featureValue(for: "decoder")!.multiArrayValue!,
            out.featureValue(for: "h_out")!.multiArrayValue!,
            out.featureValue(for: "c_out")!.multiArrayValue!
        )
    }

    /// Copies encoder frame `t` ([1, 1024, T], any strides, fp16 or fp32) into a [1, 1024, 1] array.
    private func copyFrame(_ t: Int, of frames: MLMultiArray, into frame: MLMultiArray) {
        let channels = frames.shape[1].intValue
        let channelStride = frames.strides[1].intValue
        let timeStride = frames.strides[2].intValue
        frame.withUnsafeMutableBufferPointer(ofType: Float.self) { dst, dstStrides in
            let dstStride = dstStrides[1]
            if frames.dataType == .float16 {
                frames.withUnsafeBufferPointer(ofType: Float16.self) { src in
                    for ch in 0..<channels { dst[ch * dstStride] = Float(src[ch * channelStride + t * timeStride]) }
                }
            } else {
                frames.withUnsafeBufferPointer(ofType: Float.self) { src in
                    for ch in 0..<channels { dst[ch * dstStride] = src[ch * channelStride + t * timeStride] }
                }
            }
        }
    }
}

private extension MLMultiArray {
    func zeroed() -> MLMultiArray {
        withUnsafeMutableBytes { pointer, _ in _ = pointer.initializeMemory(as: UInt8.self, repeating: 0) }
        return self
    }
}

extension ParakeetModels: SegmentModel {
    var maxSegmentSamples: Int { Self.windowSamples }

    func transcribe(_ samples: ArraySlice<Float>) throws -> String {
        guard let freshState else { throw TranscriberError.unavailable }
        return text(try decode(samples, from: freshState).tokens)
    }
}
