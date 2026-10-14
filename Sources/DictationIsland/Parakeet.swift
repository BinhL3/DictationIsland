import AVFoundation
import CoreML
import os

// NVIDIA Parakeet TDT 0.6B v3: the model Handy and Noi recommend. 25 European languages,
// auto-detected, with punctuation and capitalisation.
//
// Runs on Core ML (Neural Engine) from FluidInference's CoreML export of the NVIDIA weights
// (CC-BY-4.0). No third-party code: preprocessing, the encoder and the joint network are Core ML
// models, and the TDT greedy decode below is ~80 lines.
//
// The model sees fixed 15 s windows and isn't a streaming model, so live text comes from
// re-decoding the open segment every ~0.6 s. Once a segment passes 12 s it is cut at the quietest
// moment and committed. Each segment decodes from a fresh state: carrying the prediction network
// across the cut made the model drop the next segment's first words.

/// The downloaded model files, pinned to one Hugging Face revision.
enum ParakeetModel {
    static let repo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    static let revision = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"

    static let files: [(path: String, size: Int64)] = [
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

    static var downloadSize: Int64 { files.reduce(0) { $0 + $1.size } }

    static var directory: URL {
        URL.applicationSupportDirectory
            .appending(path: "DictationIsland/Models/parakeet-tdt-0.6b-v3", directoryHint: .isDirectory)
    }

    static var isInstalled: Bool {
        files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appending(path: file.path).path)
            return (attributes?[.size] as? Int64) == file.size
        }
    }

    /// Downloads whatever is missing. `progress` reports 0...1 over the whole model.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let total = Double(downloadSize)
        var done: Int64 = 0
        for file in files {
            let destination = directory.appending(path: file.path)
            let existing = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64
            if existing != file.size {
                let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
                let base = done
                try await FileDownload.fetch(url, to: destination) { written in
                    progress(Double(base + written) / total)
                }
            }
            done += file.size
            progress(Double(done) / total)
        }
    }

    static func remove() throws {
        try FileManager.default.removeItem(at: directory)
    }
}

/// One file over URLSession with byte progress, moved into place only once complete.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onBytes: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    private init(destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onBytes = onBytes
    }

    static func fetch(_ url: URL, to destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = FileDownload(destination: destination, onBytes: onBytes)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onBytes(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so move it now.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: location, to: destination)
            resume(.success(()))
        } catch {
            resume(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { resume(.failure(error)) }
    }
}

// MARK: - Inference

/// The four Core ML models plus the vocabulary, loaded once and kept warm between dictations
/// (the first load compiles the encoder for the Neural Engine, which takes a while).
final class ParakeetModels: @unchecked Sendable {
    static let sampleRate = 16_000.0
    /// The preprocessor takes exactly 15 s (240 000 samples); shorter audio is zero-padded.
    static let windowSamples = 240_000
    static let blankID = 8192

    let preprocessor: MLModel
    let encoder: MLModel
    let decoder: MLModel
    let joint: MLModel
    private let vocabulary: [Int: String]

    private init(preprocessor: MLModel, encoder: MLModel, decoder: MLModel, joint: MLModel, vocabulary: [Int: String]) {
        self.preprocessor = preprocessor
        self.encoder = encoder
        self.decoder = decoder
        self.joint = joint
        self.vocabulary = vocabulary
    }

    private static let loader = Loader()

    /// Loads once; concurrent callers share the same load.
    static func shared() async throws -> ParakeetModels {
        try await loader.models()
    }

    /// Warms the models in the background so the first dictation doesn't wait for them.
    static func preload() {
        guard ParakeetModel.isInstalled else { return }
        Task.detached(priority: .utility) { _ = try? await shared() }
    }

    private actor Loader {
        private var task: Task<ParakeetModels, Error>?

        func models() async throws -> ParakeetModels {
            if let task { return try await task.value }
            let task = Task { try await ParakeetModels.load() }
            self.task = task
            do {
                return try await task.value
            } catch {
                self.task = nil
                throw error
            }
        }
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
        return try await ParakeetModels(
            preprocessor: preprocessor, encoder: encoder, decoder: decoder, joint: joint, vocabulary: vocabulary
        )
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

// MARK: - Session

/// Owns one dictation's committed text. Decoding is serialised here.
private actor ParakeetSession {
    /// Past this, the open segment is cut at a pause and committed (live and final).
    static let commitAfter = 12 * 16_000
    /// The cut is searched for in this range of the open segment, quietest 80 ms wins.
    static let cutSearch = (8 * 16_000)..<(14 * 16_000)

    let models: ParakeetModels
    private let initialState: ParakeetModels.DecoderState
    private var committedText = ""
    private(set) var committedSamples = 0
    private var lastOpenLength = -1

    init(models: ParakeetModels) throws {
        self.models = models
        initialState = try models.initialState()
    }

    /// `open` is the audio after `committedSamples`. Returns the full transcript, or nil if
    /// nothing changed since the last live update.
    func update(open: [Float], final: Bool) throws -> String? {
        var open = open[...]
        let limit = final ? ParakeetModels.windowSamples : Self.commitAfter
        while open.count > limit {
            let cut = Self.quietestCut(in: open)
            let segment = open.prefix(cut)
            committedText = Self.join(committedText, try transcribe(segment))
            committedSamples += cut
            open = open.dropFirst(cut)
            lastOpenLength = -1
        }

        if !final && open.count == lastOpenLength { return nil }
        lastOpenLength = open.count

        // Under 0.1 s there's nothing to hear, and the encoder output would be empty anyway.
        guard open.count >= 1_600 else { return committedText }
        let text = Self.join(committedText, try transcribe(open))
        if final {
            committedText = text
            committedSamples += open.count
        }
        return text
    }

    private func transcribe(_ samples: ArraySlice<Float>) throws -> String {
        models.text(try models.decode(samples, from: initialState).tokens)
    }

    /// A fresh segment starts capitalised; lower it again when the cut fell mid-sentence.
    private static func join(_ head: String, _ tail: String) -> String {
        guard !head.isEmpty else { return tail }
        guard !tail.isEmpty else { return head }
        var tail = tail
        let words = tail.split(separator: " ", maxSplits: 1)
        if let last = head.last, !".?!…".contains(last), let first = words.first,
           first != "I", !first.hasPrefix("I'"), first.dropFirst().allSatisfy({ !$0.isUppercase }) {
            tail = first.prefix(1).lowercased() + tail.dropFirst()
        }
        return head + " " + tail
    }

    /// Offset (from the segment start) of the middle of its quietest 80 ms frame in `cutSearch`.
    private static func quietestCut(in samples: ArraySlice<Float>) -> Int {
        let frame = 1_280
        let upper = min(cutSearch.upperBound, samples.count, ParakeetModels.windowSamples) - frame
        var best = min(cutSearch.lowerBound, upper)
        var bestEnergy = Float.greatestFiniteMagnitude
        var offset = cutSearch.lowerBound
        let base = samples.startIndex
        while offset <= upper {
            var energy: Float = 0
            for i in (base + offset)..<(base + offset + frame) { energy += samples[i] * samples[i] }
            if energy < bestEnergy {
                bestEnergy = energy
                best = offset
            }
            offset += frame / 2
        }
        return best + frame / 2
    }
}

// MARK: - Transcriber

/// Collects 16 kHz audio from the capture thread for `ParakeetTranscriber`.
private final class SampleBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private var lock = os_unfair_lock()
    private var converter: AVAudioConverter?
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: ParakeetModels.sampleRate, channels: 1, interleaved: false
    )!

    /// Called on the audio thread with mono Float32 buffers at the device rate.
    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
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
        guard error == nil, let channel = output.floatChannelData?[0] else { return }
        let converted = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        os_unfair_lock_lock(&lock)
        samples.append(contentsOf: converted)
        os_unfair_lock_unlock(&lock)
    }

    func samples(from start: Int) -> [Float] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return start < samples.count ? Array(samples[start...]) : []
    }
}

final class ParakeetTranscriber: Transcriber {
    var onPartial: ((String) -> Void)?

    private let audio = SampleBuffer()
    private var session: ParakeetSession?
    private var liveTask: Task<Void, Never>?

    func requestPermission() async -> Bool { true }

    func begin(locale: Locale) async throws {
        // Parakeet detects the language itself, so `locale` isn't needed.
        let session = try ParakeetSession(models: try await ParakeetModels.shared())
        self.session = session
        let audio = audio
        let report: @MainActor (String) -> Void = { [weak self] text in self?.onPartial?(text) }
        liveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                let open = audio.samples(from: await session.committedSamples)
                guard let text = try? await session.update(open: open, final: false) else { continue }
                await report(text)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        audio.append(buffer)
    }

    func finish() async -> String {
        liveTask?.cancel()
        await liveTask?.value
        liveTask = nil
        guard let session else { return "" }
        self.session = nil
        let open = audio.samples(from: await session.committedSamples)
        return (try? await session.update(open: open, final: true)) ?? ""
    }

    func cancel() {
        liveTask?.cancel()
        liveTask = nil
        session = nil
    }
}
