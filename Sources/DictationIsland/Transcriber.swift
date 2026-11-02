import AVFoundation
import Speech

/// Seam for the speech engine (`SpeechAnalyzerTranscriber`, `AppleSpeechTranscriber`). The UI only sees partial/final text, so swapping in Whisper,
/// a cloud API, or SpeechAnalyzer means writing another conformer.
protocol Transcriber: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    func requestPermission() async -> Bool
    func begin(locale: Locale) async throws
    func append(_ buffer: AVAudioPCMBuffer)
    /// Ends audio input and resolves with the final transcript.
    func finish() async -> String
    func cancel()
}

/// Runs `work`, but stops waiting after `timeout`. Returns false if the deadline won; the work
/// keeps running in the background and its result is ignored. Used so a recognizer that never
/// finalizes can't leave the island stuck on "finishing".
func withDeadline(_ timeout: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }
    return await withCheckedContinuation { continuation in
        let once = Once(continuation)
        Task {
            await work()
            once.resume(true)
        }
        Task {
            try? await Task.sleep(for: timeout)
            once.resume(false)
        }
    }
}

enum TranscriberError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Speech recognition unavailable" }
}

/// Legacy `SFSpeechRecognizer` engine.
final class AppleSpeechTranscriber: Transcriber {
    var onPartial: ((String) -> Void)?
    /// Names and jargon the recognizer should favour (from the corrections list).
    var contextualStrings: [String] = []

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finalContinuation: CheckedContinuation<String, Never>?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    func begin(locale: Locale) async throws {
        if recognizer?.locale != locale {
            recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        guard let recognizer, recognizer.isAvailable else { throw TranscriberError.unavailable }
        latest = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = contextualStrings
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.latest = result.bestTranscription.formattedString
                    self.onPartial?(self.latest)
                    if result.isFinal { self.resolveFinal() }
                }
                if error != nil { self.resolveFinal() }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func finish() async -> String {
        request?.endAudio()
        return await withCheckedContinuation { continuation in
            finalContinuation = continuation
            // Don't hang the UI if the recognizer never delivers an isFinal result.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.resolveFinal() }
        }
    }

    func cancel() {
        task?.cancel()
        request = nil
        task = nil
        resolveFinal()
    }

    private func resolveFinal() {
        guard let continuation = finalContinuation else { return }
        finalContinuation = nil
        request = nil
        task = nil
        continuation.resume(returning: latest)
    }
}
