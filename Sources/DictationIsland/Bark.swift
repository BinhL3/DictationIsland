import Accelerate
import Compression
import CoreML

// Underdog Bark 3.0 by Conway Research: Parakeet TDT 0.6B v3 post-trained for English and
// compressed to a 163 MB download, about as accurate as Parakeet overall and better on meetings.
// CC-BY-4.0; the downloaded NOTICE carries the attribution.
//
// The encoder is a Core ML multifunction model (8 s and 15 s windows) on the Neural Engine. The
// rest is a Swift port of the reference `coreml/ane/bark_coreml.py`: the mel frontend and the TDT
// greedy decode (a 2-layer LSTM and a joint head, int8 weights with per-row scales) run on the CPU
// with Accelerate. Live text comes from `SegmentedTranscriber`.

/// The downloaded model files, pinned to one Hugging Face revision.
enum BarkModel {
    static let pinned = PinnedModel(
        repo: "ConwayResearch/Underdog-Bark-3.0",
        revision: "85db2ad18ab41e534a222ee253c29191d77ed919",
        folder: "bark-3.0",
        files: [
            ("coreml/NOTICE", 603),
            ("coreml/ane/BarkEncoder.mlpackage/Manifest.json", 617),
            ("coreml/ane/BarkEncoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", 1784701),
            ("coreml/ane/BarkEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 189133632),
            ("coreml/ane/decoder.npz", 11168286),
            ("coreml/ane/vocab.json", 115878),
        ]
    )

    static var downloadSize: Int64 { pinned.downloadSize }
    static var isInstalled: Bool { pinned.isInstalled }
    static var directory: URL { pinned.directory.appending(path: "coreml/ane", directoryHint: .isDirectory) }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await pinned.download(progress: progress)
    }
}

// MARK: - Inference

/// Encoder, frontend and decoder, loaded once and kept warm between dictations (the first load
/// compiles the encoder for the Neural Engine, which takes a while).
final class BarkModels: SegmentModel, @unchecked Sendable {
    /// Encoder windows in seconds; each segment uses the smallest that holds it.
    private static let windows = [8, 15]
    /// 0.25 s of silence before each segment, the setting the published accuracy was measured with.
    private static let leadingSilence = 4_000

    var maxSegmentSamples: Int { 15 * 16_000 - Self.leadingSilence }

    private let encoders: [Int: MLModel]
    private let frontend: BarkFrontend
    private let decoder: BarkDecoder

    private init(encoders: [Int: MLModel], frontend: BarkFrontend, decoder: BarkDecoder) {
        self.encoders = encoders
        self.frontend = frontend
        self.decoder = decoder
    }

    private static let loader = LoadOnce { try await BarkModels.load() }

    /// Loads once; concurrent callers share the same load.
    static func shared() async throws -> BarkModels {
        try await loader.value()
    }

    /// Warms the models in the background so the first dictation doesn't wait for them.
    static func preload() {
        guard BarkModel.isInstalled else { return }
        Task.detached(priority: .utility) { _ = try? await shared() }
    }

    private static func load() async throws -> BarkModels {
        guard BarkModel.isInstalled else { throw TranscriberError.unavailable }
        let directory = BarkModel.directory
        let compiled = try await compiledEncoder(in: directory)
        @Sendable func encoder(_ seconds: Int) async throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            configuration.functionName = "w\(seconds)"
            return try await MLModel.load(contentsOf: compiled, configuration: configuration)
        }
        async let short = encoder(8)
        async let long = encoder(15)

        let weights = try NPZ(contentsOf: directory.appending(path: "decoder.npz"))
        let vocabulary = try JSONDecoder().decode(
            BarkVocabulary.self, from: Data(contentsOf: directory.appending(path: "vocab.json"))
        )
        let frontend = BarkFrontend(melFilters: try weights.floats("mel_filters"))
        let decoder = try BarkDecoder(weights: weights, vocabulary: vocabulary)
        return try await BarkModels(encoders: [8: short, 15: long], frontend: frontend, decoder: decoder)
    }

    /// The encoder ships as a source `.mlpackage`; compile it once and keep the result next to it.
    private static func compiledEncoder(in directory: URL) async throws -> URL {
        let compiled = directory.appending(path: "BarkEncoder.mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) { return compiled }
        let temporary = try await MLModel.compileModel(at: directory.appending(path: "BarkEncoder.mlpackage"))
        try FileManager.default.moveItem(at: temporary, to: compiled)
        return compiled
    }

    func transcribe(_ samples: ArraySlice<Float>) throws -> String {
        var audio = [Float](repeating: 0, count: Self.leadingSilence)
        audio.append(contentsOf: samples)
        guard let seconds = Self.windows.first(where: { audio.count <= $0 * 16_000 }),
              let encoder = encoders[seconds]
        else { throw TranscriberError.unavailable }

        let mel = frontend.features(audio)
        let length = seconds * 100 + 1
        let features = try MLMultiArray(shape: [1, NSNumber(value: length), 128], dataType: .float16)
        features.withUnsafeMutableBufferPointer(ofType: Float16.self) { dst, _ in
            dst.initialize(repeating: 0)
            for i in 0..<min(mel.values.count, length * 128) { dst[i] = Float16(mel.values[i]) }
        }
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        mask.withUnsafeMutableBufferPointer(ofType: Int32.self) { dst, _ in
            for i in 0..<length { dst[i] = i < mel.valid ? 1 : 0 }
        }

        let out = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "features": features, "mask": mask,
        ]))
        guard let encoded = out.featureValue(for: "encoded")?.multiArrayValue else { throw TranscriberError.unavailable }
        let frames = min(Self.encodedLength(mel.valid), encoded.shape[1].intValue)
        let matrix = Self.rows(frames, of: encoded)
        guard matrix.allSatisfy(\.isFinite) else { throw TranscriberError.unavailable }
        return decoder.text(decoder.decode(matrix, frames: frames))
    }

    /// Frames left after the encoder's three stride-2 convolutions.
    private static func encodedLength(_ frames: Int) -> Int {
        var n = frames
        for _ in 0..<3 { n = (n - 1) / 2 + 1 }
        return n
    }

    /// The first `count` rows of `[1, T, 640]` (any strides, fp16 or fp32) as a dense fp32 matrix.
    private static func rows(_ count: Int, of array: MLMultiArray) -> [Float] {
        let width = array.shape[2].intValue
        let rowStride = array.strides[1].intValue
        let columnStride = array.strides[2].intValue
        var matrix = [Float](repeating: 0, count: count * width)
        if array.dataType == .float16 {
            array.withUnsafeBufferPointer(ofType: Float16.self) { src in
                for r in 0..<count { for c in 0..<width { matrix[r * width + c] = Float(src[r * rowStride + c * columnStride]) } }
            }
        } else {
            array.withUnsafeBufferPointer(ofType: Float.self) { src in
                for r in 0..<count { for c in 0..<width { matrix[r * width + c] = src[r * rowStride + c * columnStride] } }
            }
        }
        return matrix
    }
}

/// Log-mel features, matching transformers' `ParakeetFeatureExtractor`: pre-emphasis, centred
/// 512-point STFT with a 400-sample Hann window, 128 Slaney mel bands, log, then per-utterance
/// normalisation of each band.
private struct BarkFrontend {
    static let fftSize = 512, hop = 160, windowLength = 400, bins = 257, bands = 128

    /// `[257, 128]`, transposed from the `[128, 257]` filters in `decoder.npz`.
    private let melFilters: [Float]
    private let window: [Float]
    /// Real-input DFT as two `[512, 257]` matrices; the power spectrum only needs magnitudes.
    private let cosines: [Float]
    private let sines: [Float]

    init(melFilters filters: [Float]) {
        var transposed = [Float](repeating: 0, count: filters.count)
        vDSP_mtrans(filters, 1, &transposed, 1, vDSP_Length(Self.bins), vDSP_Length(Self.bands))
        melFilters = transposed

        // Symmetric Hann (numpy's `hanning`), centred in the FFT frame.
        var window = [Float](repeating: 0, count: Self.fftSize)
        let offset = (Self.fftSize - Self.windowLength) / 2
        for i in 0..<Self.windowLength {
            window[offset + i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(Self.windowLength - 1)))
        }
        self.window = window

        var cosines = [Float](repeating: 0, count: Self.fftSize * Self.bins)
        var sines = cosines
        for j in 0..<Self.fftSize {
            for k in 0..<Self.bins {
                let angle = 2 * Double.pi * Double((j * k) % Self.fftSize) / Double(Self.fftSize)
                cosines[j * Self.bins + k] = Float(cos(angle))
                sines[j * Self.bins + k] = Float(sin(angle))
            }
        }
        self.cosines = cosines
        self.sines = sines
    }

    /// `values` is `[frames, 128]` row-major; frames from `valid` on are padding and zeroed.
    func features(_ x: [Float]) -> (values: [Float], valid: Int) {
        let half = Self.fftSize / 2
        var padded = [Float](repeating: 0, count: x.count + Self.fftSize)
        padded[half] = x[0]
        for i in 1..<x.count { padded[half + i] = x[i] - 0.97 * x[i - 1] }

        let frames = 1 + x.count / Self.hop
        var framed = [Float](repeating: 0, count: frames * Self.fftSize)
        for f in 0..<frames {
            for j in 0..<Self.fftSize { framed[f * Self.fftSize + j] = padded[f * Self.hop + j] * window[j] }
        }

        var real = [Float](repeating: 0, count: frames * Self.bins)
        var imaginary = real
        let (m, n, p) = (vDSP_Length(frames), vDSP_Length(Self.bins), vDSP_Length(Self.fftSize))
        vDSP_mmul(framed, 1, cosines, 1, &real, 1, m, n, p)
        vDSP_mmul(framed, 1, sines, 1, &imaginary, 1, m, n, p)
        var power = [Float](repeating: 0, count: frames * Self.bins)
        vDSP.add(multiplication: (real, real), multiplication: (imaginary, imaginary), result: &power)

        var mel = [Float](repeating: 0, count: frames * Self.bands)
        vDSP_mmul(power, 1, melFilters, 1, &mel, 1, m, vDSP_Length(Self.bands), n)
        mel = mel.map { log($0 + 0x1p-24) }

        let valid = x.count / Self.hop
        for band in 0..<Self.bands {
            var mean: Float = 0
            for f in 0..<valid { mean += mel[f * Self.bands + band] }
            mean /= Float(max(valid, 1))
            var variance: Float = 0
            for f in 0..<valid { variance += (mel[f * Self.bands + band] - mean) * (mel[f * Self.bands + band] - mean) }
            let scale = 1 / (sqrt(variance / Float(max(1, valid - 1))) + 1e-5)
            for f in 0..<frames { mel[f * Self.bands + band] = f < valid ? (mel[f * Self.bands + band] - mean) * scale : 0 }
        }
        return (mel, valid)
    }
}

private struct BarkVocabulary: Decodable {
    let pieces: [String]
    let specialIDs: [Int]
    let blankID: Int
    let vocabularySize: Int
    let durations: [Int]
    let maxSymbolsPerStep: Int

    enum CodingKeys: String, CodingKey {
        case pieces, durations
        case specialIDs = "special_ids", blankID = "blank_id", vocabularySize = "vocab_size"
        case maxSymbolsPerStep = "max_symbols_per_step"
    }
}

/// Token-and-Duration Transducer greedy search on the CPU, identical to transformers'
/// `ParakeetForTDT.generate` at batch size 1. At each encoder frame the joint head picks a token
/// and how many frames to skip; blanks don't touch the prediction network.
private final class BarkDecoder {
    private static let hidden = 640

    private let embedding: [Float]
    /// Per layer: `[2560, 1280]` with the input and recurrent weights side by side, so one matrix
    /// product computes all four gates from `[x; h]`.
    private let lstm: [(weights: [Float], bias: [Float])]
    private let projection: [Float]
    private let projectionBias: [Float]
    private let head: [Float]
    private let headBias: [Float]
    private let vocabulary: BarkVocabulary

    init(weights: NPZ, vocabulary: BarkVocabulary) throws {
        let h = Self.hidden
        embedding = try weights.matrix("decoder.embedding.weight")
        lstm = try (0..<2).map { layer in
            let input = try weights.matrix("decoder.lstm.weight_ih_l\(layer)")
            let recurrent = try weights.matrix("decoder.lstm.weight_hh_l\(layer)")
            var combined = [Float](repeating: 0, count: 4 * h * 2 * h)
            for row in 0..<(4 * h) {
                for c in 0..<h {
                    combined[row * 2 * h + c] = input[row * h + c]
                    combined[row * 2 * h + h + c] = recurrent[row * h + c]
                }
            }
            let bias = vDSP.add(try weights.floats("decoder.lstm.bias_ih_l\(layer)"), try weights.floats("decoder.lstm.bias_hh_l\(layer)"))
            return (combined, bias)
        }
        projection = try weights.matrix("decoder.decoder_projector.weight")
        projectionBias = try weights.floats("decoder.decoder_projector.bias")
        head = try weights.matrix("joint.head.weight")
        headBias = try weights.floats("joint.head.bias")
        self.vocabulary = vocabulary
    }

    private struct State {
        var h = [[Float]](repeating: [Float](repeating: 0, count: hidden), count: 2)
        var c = [[Float]](repeating: [Float](repeating: 0, count: hidden), count: 2)
    }

    /// Feeds one token through the prediction network; returns its projected output.
    private func step(_ token: Int, _ state: inout State) -> [Float] {
        let h = Self.hidden
        var x = Array(embedding[(token * h)..<((token + 1) * h)])
        for layer in 0..<2 {
            let gates = Self.multiply(lstm[layer].weights, x + state.h[layer], rows: 4 * h, bias: lstm[layer].bias)
            var c = state.c[layer]
            var out = [Float](repeating: 0, count: h)
            for k in 0..<h {
                let i = Self.sigmoid(gates[k])
                let f = Self.sigmoid(gates[h + k])
                let g = tanh(gates[2 * h + k])
                let o = Self.sigmoid(gates[3 * h + k])
                c[k] = f * c[k] + i * g
                out[k] = o * tanh(c[k])
            }
            state.c[layer] = c
            state.h[layer] = out
            x = out
        }
        return Self.multiply(projection, x, rows: h, bias: projectionBias)
    }

    /// `encoded` is `[frames, 640]` row-major, already projected into the joint space.
    func decode(_ encoded: [Float], frames: Int) -> [Int] {
        let h = Self.hidden
        let tokens = vocabulary.vocabularySize
        let blank = vocabulary.blankID
        var state = State()
        var prediction = step(blank, &state)
        var output: [Int] = []
        var t = 0
        var symbols = 0
        while t < frames {
            var joint = vDSP.add(encoded[(t * h)..<((t + 1) * h)], prediction)
            joint = vDSP.threshold(joint, to: 0, with: .clampToThreshold)
            let logits = Self.multiply(head, joint, rows: headBias.count, bias: headBias)
            let token = Int(vDSP.indexOfMaximum(logits[0..<tokens]).0)
            var duration = vocabulary.durations[Int(vDSP.indexOfMaximum(logits[tokens...]).0)]
            if token == blank {
                t += max(duration, 1)
                symbols = 0
            } else {
                output.append(token)
                prediction = step(token, &state)
                symbols += 1
                // Several tokens may share a frame, but never unboundedly.
                if duration == 0 && symbols >= vocabulary.maxSymbolsPerStep { duration = 1 }
                if duration > 0 { symbols = 0 }
                t += duration
            }
        }
        return output
    }

    func text(_ tokens: [Int]) -> String {
        let special = Set(vocabulary.specialIDs)
        return tokens
            .filter { !special.contains($0) && $0 < vocabulary.pieces.count }
            .map { vocabulary.pieces[$0] }
            // Control tokens (<|endoftext|>, …) never belong in the text.
            .filter { !($0.hasPrefix("<") && $0.hasSuffix(">")) }
            .joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `matrix · vector + bias` for a row-major `[rows, vector.count]` matrix.
    private static func multiply(_ matrix: [Float], _ vector: [Float], rows: Int, bias: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: rows)
        vDSP_mmul(matrix, 1, vector, 1, &result, 1, vDSP_Length(rows), 1, vDSP_Length(vector.count))
        vDSP.add(result, bias, result: &result)
        return result
    }

    private static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }
}

// MARK: - NumPy archives

/// Reads the `.npz` archive (a zip of `.npy` files, stored or deflated) holding Bark's decoder
/// weights: just the little-endian float16, float32 and int8 arrays it uses.
private struct NPZ {
    private struct Array {
        var type: String
        var shape: [Int]
        var bytes: [UInt8]
    }

    private var arrays: [String: Array] = [:]

    init(contentsOf url: URL) throws {
        let zip = [UInt8](try Data(contentsOf: url))
        for (name, bytes) in try Self.entries(of: zip) where name.hasSuffix(".npy") {
            arrays[String(name.dropLast(4))] = try Self.parse(bytes)
        }
    }

    /// Converts an array to fp32.
    func floats(_ key: String) throws -> [Float] {
        guard let array = arrays[key] else { throw NPZError.missing(key) }
        return array.bytes.withUnsafeBytes { raw -> [Float] in
            switch array.type {
            case "<f2": return raw.bindMemory(to: Float16.self).map(Float.init)
            case "<f4": return Swift.Array(raw.bindMemory(to: Float.self))
            case "|i1": return raw.bindMemory(to: Int8.self).map(Float.init)
            default: return []
            }
        }
    }

    /// A weight matrix as fp32, dequantising `<key>.q` (int8) by its per-row scales `<key>.s`.
    func matrix(_ key: String) throws -> [Float] {
        guard let quantised = arrays[key + ".q"] else { return try floats(key) }
        var values = try floats(key + ".q")
        let scales = try floats(key + ".s")
        let columns = quantised.shape.last ?? 1
        for row in 0..<scales.count {
            for c in 0..<columns { values[row * columns + c] *= scales[row] }
        }
        return values
    }

    private static func parse(_ bytes: [UInt8]) throws -> Array {
        guard bytes.count > 10, bytes[0] == 0x93, String(decoding: bytes[1..<6], as: UTF8.self) == "NUMPY" else {
            throw NPZError.malformed
        }
        let (headerLength, start) = bytes[6] == 1
            ? (Int(read(UInt16.self, bytes, at: 8)), 10)
            : (Int(read(UInt32.self, bytes, at: 8)), 12)
        let header = String(decoding: bytes[start..<(start + headerLength)], as: UTF8.self)
        guard let type = header.firstMatch(of: #/'descr': '([^']+)'/#)?.1,
              let shape = header.firstMatch(of: #/'shape': \(([^)]*)\)/#)?.1,
              header.contains("'fortran_order': False")
        else { throw NPZError.malformed }
        return Array(
            type: String(type),
            shape: shape.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) },
            bytes: Swift.Array(bytes[(start + headerLength)...])
        )
    }

    /// Files in a zip archive, from its central directory.
    private static func entries(of zip: [UInt8]) throws -> [(String, [UInt8])] {
        // End of central directory record: the last thing in the file, before an optional comment.
        guard let end = stride(from: zip.count - 22, through: max(0, zip.count - 65_557), by: -1)
            .first(where: { read(UInt32.self, zip, at: $0) == 0x0605_4b50 })
        else { throw NPZError.malformed }
        let count = Int(read(UInt16.self, zip, at: end + 10))
        var offset = Int(read(UInt32.self, zip, at: end + 16))

        var entries: [(String, [UInt8])] = []
        for _ in 0..<count {
            guard read(UInt32.self, zip, at: offset) == 0x0201_4b50 else { throw NPZError.malformed }
            let method = read(UInt16.self, zip, at: offset + 10)
            var compressedSize = Int(read(UInt32.self, zip, at: offset + 20))
            var size = Int(read(UInt32.self, zip, at: offset + 24))
            let nameLength = Int(read(UInt16.self, zip, at: offset + 28))
            let extraLength = Int(read(UInt16.self, zip, at: offset + 30))
            let commentLength = Int(read(UInt16.self, zip, at: offset + 32))
            var local = Int(read(UInt32.self, zip, at: offset + 42))
            let name = String(decoding: zip[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)

            // Zip64: sizes and offsets that overflow 32 bits move into an extra field, in this order.
            var extra = offset + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = read(UInt16.self, zip, at: extra)
                let length = Int(read(UInt16.self, zip, at: extra + 2))
                if id == 1 {
                    var field = extra + 4
                    if size == 0xFFFF_FFFF { size = Int(read(UInt64.self, zip, at: field)); field += 8 }
                    if compressedSize == 0xFFFF_FFFF { compressedSize = Int(read(UInt64.self, zip, at: field)); field += 8 }
                    if local == 0xFFFF_FFFF { local = Int(read(UInt64.self, zip, at: field)) }
                }
                extra += 4 + length
            }
            offset = extraEnd + commentLength

            guard read(UInt32.self, zip, at: local) == 0x0403_4b50 else { throw NPZError.malformed }
            let dataStart = local + 30 + Int(read(UInt16.self, zip, at: local + 26)) + Int(read(UInt16.self, zip, at: local + 28))
            let compressed = zip[dataStart..<(dataStart + compressedSize)]
            switch method {
            case 0:
                entries.append((name, Swift.Array(compressed)))
            case 8:
                var output = [UInt8](repeating: 0, count: size)
                let written = compressed.withUnsafeBufferPointer { src in
                    compression_decode_buffer(&output, size, src.baseAddress!, compressedSize, nil, COMPRESSION_ZLIB)
                }
                guard written == size else { throw NPZError.malformed }
                entries.append((name, output))
            default:
                throw NPZError.malformed
            }
        }
        return entries
    }

    private static func read<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8], at offset: Int) -> T {
        bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}

private enum NPZError: LocalizedError {
    case missing(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .missing(let key): return "Bark model file is missing \(key)"
        case .malformed: return "Bark model file is damaged"
        }
    }
}
