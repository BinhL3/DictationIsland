import AVFoundation
import os

// Shared plumbing for the downloaded Core ML engines (Parakeet, Bark): pinned downloads, a
// load-once cache, and live transcription by re-decoding pause-aligned 15 s segments.

/// Model files pinned to one Hugging Face revision, mirrored into Application Support.
struct PinnedModel: Sendable {
    let repo: String
    let revision: String
    /// Folder under `Application Support/DictationIsland/Models`.
    let folder: String
    let files: [(path: String, size: Int64)]

    var downloadSize: Int64 { files.reduce(0) { $0 + $1.size } }

    var directory: URL {
        URL.applicationSupportDirectory
            .appending(path: "DictationIsland/Models/\(folder)", directoryHint: .isDirectory)
    }

    var isInstalled: Bool {
        files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appending(path: file.path).path)
            return (attributes?[.size] as? Int64) == file.size
        }
    }

    /// Downloads whatever is missing. `progress` reports 0...1 over the whole model.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
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

    func remove() throws {
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

/// Runs an expensive load once; concurrent callers share it, and a failed load is retried next time.
actor LoadOnce<Value: Sendable> {
    private let load: @Sendable () async throws -> Value
    private var task: Task<Value, Error>?
    private let loaded = OSAllocatedUnfairLock(initialState: false)

    /// True once a load has finished, readable from anywhere without waiting.
    nonisolated var isLoaded: Bool { loaded.withLock { $0 } }

    init(_ load: @escaping @Sendable () async throws -> Value) {
        self.load = load
    }

    func value() async throws -> Value {
        if let task { return try await task.value }
        let task = Task { try await load() }
        self.task = task
        do {
            let value = try await task.value
            loaded.withLock { $0 = true }
            return value
        } catch {
            self.task = nil
            throw error
        }
    }
}

// MARK: - Segmented transcription

/// A non-streaming model that reads up to ~15 s of 16 kHz mono audio per call.
protocol SegmentModel: AnyObject, Sendable {
    /// Longest audio one `transcribe` call accepts, in samples.
    var maxSegmentSamples: Int { get }
    /// Transcribes one segment from a fresh decoder state.
    func transcribe(_ samples: ArraySlice<Float>) throws -> String
}

let modelSampleRate = 16_000.0

/// Owns one dictation's committed text. Decoding is serialised here.
///
/// The models see fixed windows and don't stream, so live text comes from re-decoding the open
/// segment every ~0.6 s. Once a segment passes 12 s it is cut at the quietest moment and committed.
/// Each segment decodes from a fresh state: carrying the prediction network across the cut made
/// the model drop the next segment's first words.
private actor SegmentedSession {
    /// Past this, the open segment is cut at a pause and committed (live and final).
    static let commitAfter = 12 * 16_000
    /// The cut is searched for in this range of the open segment, quietest 80 ms wins.
    static let cutSearch = (8 * 16_000)..<(14 * 16_000)
    /// Silence appended to the last segment so the model hears the sentence end and keeps its
    /// closing punctuation (Hex found Parakeet drops the full stop without it).
    static let finalSilence = 6_400
    /// Very short takes are padded to this length before the final decode.
    static let minimumFinal = 24_000
    /// The model wrappers keep decoder state, and two takes can overlap (one finishing while the
    /// next listens), so every decode across sessions goes through this lock.
    private static let modelLock = NSLock()

    let model: any SegmentModel
    private var committedText = ""
    private(set) var committedSamples = 0
    private var lastOpenLength = -1

    init(model: any SegmentModel) {
        self.model = model
    }

    /// `open` is the audio after `committedSamples`. Returns the full transcript, or nil if
    /// nothing changed since the last live update.
    func update(open: [Float], final: Bool) throws -> String? {
        var open = open[...]
        // The final segment keeps room for its trailing silence.
        let limit = final ? model.maxSegmentSamples - Self.finalSilence : Self.commitAfter
        while open.count > limit {
            let cut = quietestCut(in: open)
            let segment = open.prefix(cut)
            committedText = Self.join(committedText, try decode(segment))
            committedSamples += cut
            open = open.dropFirst(cut)
            lastOpenLength = -1
        }

        if !final && open.count == lastOpenLength { return nil }
        lastOpenLength = open.count

        // Under 0.1 s there's nothing to hear, and the encoder output would be empty anyway.
        guard open.count >= 1_600 else { return committedText }
        var audio = open
        if final {
            let padding = max(Self.finalSilence, Self.minimumFinal - open.count)
            audio = (Array(open) + [Float](repeating: 0, count: padding))[...]
        }
        let text = Self.join(committedText, try decode(audio))
        if final {
            committedText = text
            committedSamples += open.count
        }
        return text
    }

    private func decode(_ samples: ArraySlice<Float>) throws -> String {
        Self.modelLock.lock()
        defer { Self.modelLock.unlock() }
        return try model.transcribe(samples)
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
    private func quietestCut(in samples: ArraySlice<Float>) -> Int {
        let frame = 1_280
        let upper = min(Self.cutSearch.upperBound, samples.count, model.maxSegmentSamples) - frame
        var best = min(Self.cutSearch.lowerBound, upper)
        var bestEnergy = Float.greatestFiniteMagnitude
        var offset = Self.cutSearch.lowerBound
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

/// Collects 16 kHz audio from the capture thread for `SegmentedTranscriber`.
private final class SampleBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private var lock = os_unfair_lock()
    private var converter: AVAudioConverter?
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: modelSampleRate, channels: 1, interleaved: false
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

/// `Transcriber` for any `SegmentModel`: live text every ~0.6 s, final text on `finish`.
final class SegmentedTranscriber: Transcriber {
    var onPartial: ((String) -> Void)?

    private let loadModel: () async throws -> any SegmentModel
    private let audio = SampleBuffer()
    private var session: SegmentedSession?
    private var liveTask: Task<Void, Never>?

    init(model: @escaping () async throws -> any SegmentModel) {
        loadModel = model
    }

    func requestPermission() async -> Bool { true }

    func begin(locale: Locale) async throws {
        // These models pick their language themselves (or only speak one), so `locale` isn't needed.
        let session = SegmentedSession(model: try await loadModel())
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
