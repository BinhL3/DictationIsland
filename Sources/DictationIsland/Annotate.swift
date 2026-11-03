import AVFoundation
import AppKit
import ScreenCaptureKit
import Speech
import SwiftUI

/// Screen annotations for AI agents, after Hex's Annotate: tap ⌃⌥A, talk through what's on screen
/// and hold ⇧ to draw on it, tap ⌃⌥A again. The result is a folder an agent can actually use:
/// screenshots at each thing you said or drew (agents read images, not video), a timestamped
/// transcript that points at them, and the full recording. A ready-to-paste message is put on the
/// clipboard.
///
/// Everything is system frameworks: ScreenCaptureKit records screen + mic straight to MP4, the
/// narration is transcribed on-device with SpeechTranscriber's timestamps, and AVFoundation pulls
/// the frames. The island and the status capsule are left out of the recording; the ink is in it.
@MainActor
final class AnnotationController: NSObject {
    static let shared = AnnotationController()

    enum State: Equatable {
        case idle
        case starting
        case recording
        case processing
        case done(String)
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { capsule.update(state: state, startedAt: startedAt) }
    }

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingFinished: CheckedContinuation<Void, Never>?
    private var bundle: URL?
    private var startedAt: Date?
    private let ink = InkOverlay()
    private let capsule = AnnotationCapsule()
    private var flagsMonitors: [Any] = []
    private var drawTimer: Timer?
    /// Seconds into the recording when each stroke ended.
    private var strokeEnds: [TimeInterval] = []

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "DictationIsland/Annotations", directoryHint: .isDirectory)
    }

    func toggle() {
        switch state {
        case .idle, .done, .failed: Task { await start() }
        case .recording: Task { await stop() }
        case .starting, .processing: break
        }
    }

    // MARK: Recording

    private func start() async {
        guard CGPreflightScreenCaptureAccess() else {
            // The first ask shows macOS's prompt; after that only System Settings can grant it.
            if !CGRequestScreenCaptureAccess() { Permission.screenRecording.request() }
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        // The capsule and ink must exist before the window list is read, or the capsule can't
        // be left out of the recording.
        ink.show(on: screen)
        capsule.show(on: screen)
        state = .starting
        do {
            try? await Task.sleep(for: .milliseconds(100))
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
                throw AnnotationError.noDisplay
            }

            let directory = Self.folder.appending(path: Self.timestamp(), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory.appending(path: "frames"), withIntermediateDirectories: true)
            bundle = directory

            // Our own windows stay out of the video, except the ink.
            let inkID = CGWindowID(ink.windowNumber)
            let own = content.windows.filter {
                $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier && $0.windowID != inkID
            }
            let filter = SCContentFilter(display: display, excludingWindows: own)

            let configuration = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.showsCursor = true
            configuration.captureMicrophone = true
            if let uid = AppSettings.shared.resolvedMicrophoneUID { configuration.microphoneCaptureDeviceID = uid }

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            let recording = SCRecordingOutputConfiguration()
            recording.outputURL = directory.appending(path: "recording.mp4")
            recording.outputFileType = .mp4
            // HEVC keeps a minute of Retina screen to tens of megabytes instead of hundreds.
            if recording.availableVideoCodecTypes.contains(.hevc) { recording.videoCodecType = .hevc }
            let output = SCRecordingOutput(configuration: recording, delegate: self)
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
            self.stream = stream
            recordingOutput = output
            strokeEnds = []
            startedAt = Date()
            state = .recording
            watchShift()
        } catch {
            ink.hide()
            stopWatchingShift()
            fail("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    private func stop() async {
        guard let stream, let bundle, let startedAt else { return }
        stopWatchingShift()
        state = .processing
        let duration = Date().timeIntervalSince(startedAt)
        // Wait for the MP4 to be finalized before reading it.
        await withCheckedContinuation { continuation in
            recordingFinished = continuation
            Task { try? await stream.stopCapture() }
            // Never wait forever on the delegate.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.resumeRecordingFinished()
            }
        }
        self.stream = nil
        recordingOutput = nil
        ink.hide()
        do {
            let message = try await AnnotationBundle.build(at: bundle, duration: duration, strokeEnds: strokeEnds)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(message, forType: .string)
            state = .done("Copied · paste it into your agent")
        } catch {
            fail("Couldn't prepare the annotation: \(error.localizedDescription)")
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, case .done = self.state else { return }
            self.state = .idle
            self.capsule.hide()
        }
    }

    private func resumeRecordingFinished() {
        recordingFinished?.resume()
        recordingFinished = nil
    }

    private func fail(_ message: String) {
        state = .failed(message)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, case .failed = self.state else { return }
            self.state = .idle
            self.capsule.hide()
        }
    }

    // MARK: Drawing

    /// ⇧ held on its own draws where the pointer goes; no click, so the app underneath isn't
    /// touched. Typing a capital letter draws a dot at most.
    private func watchShift() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            let shiftOnly = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
            MainActor.assumeIsolated { shiftOnly ? self?.beginStroke() : self?.endStroke() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { flagsMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) {
            flagsMonitors.append(local)
        }
    }

    private func stopWatchingShift() {
        flagsMonitors.forEach(NSEvent.removeMonitor)
        flagsMonitors = []
        endStroke()
    }

    private func beginStroke() {
        guard drawTimer == nil, state == .recording else { return }
        ink.beginStroke(at: NSEvent.mouseLocation)
        drawTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ink.extendStroke(to: NSEvent.mouseLocation) }
        }
    }

    private func endStroke() {
        guard let drawTimer else { return }
        drawTimer.invalidate()
        self.drawTimer = nil
        ink.endStroke()
        if let startedAt { strokeEnds.append(Date().timeIntervalSince(startedAt)) }
    }

    /// `--annotate-test`: records ~9 s, draws a circle in ink at 3 s, then finishes. For checking
    /// the pipeline without a person at the keyboard.
    func runSelfTest() async {
        await start()
        guard state == .recording else { return }
        try? await Task.sleep(for: .seconds(3))
        let center = NSEvent.mouseLocation
        ink.beginStroke(at: CGPoint(x: center.x + 80, y: center.y))
        for step in 1...60 {
            let angle = Double(step) / 60 * 2 * .pi
            ink.extendStroke(to: CGPoint(x: center.x + 80 * cos(angle), y: center.y + 50 * sin(angle)))
            try? await Task.sleep(for: .milliseconds(16))
        }
        ink.endStroke()
        if let startedAt { strokeEnds.append(Date().timeIntervalSince(startedAt)) }
        try? await Task.sleep(for: .seconds(5))
        await stop()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}

extension AnnotationController: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.resumeRecordingFinished() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in self.resumeRecordingFinished() }
    }
}

enum AnnotationError: LocalizedError {
    case noDisplay
    case noVideo

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display to record"
        case .noVideo: return "The recording is empty"
        }
    }
}

// MARK: - Bundle

/// Turns a finished recording into something an agent can read.
enum AnnotationBundle {
    struct Line {
        let time: TimeInterval
        let text: String
    }

    static let maxFrames = 24

    /// Writes transcript.md and frames/, and returns the message to paste into an agent.
    static func build(at directory: URL, duration: TimeInterval, strokeEnds: [TimeInterval]) async throws -> String {
        let video = directory.appending(path: "recording.mp4")
        guard FileManager.default.fileExists(atPath: video.path) else { throw AnnotationError.noVideo }
        let asset = AVURLAsset(url: video)
        let lines = (try? await transcribe(asset, in: directory)) ?? []

        // A frame for each thing said (mid-sentence) and each stroke (just after it ends).
        var moments = lines.map { ($0.time, "said") } + strokeEnds.map { ($0 + 0.15, "drew") }
        if moments.isEmpty { moments = [(max(0, duration - 0.5), "end")] }
        moments.sort { $0.0 < $1.0 }
        var chosen: [TimeInterval] = []
        for (time, _) in moments where chosen.last.map({ time - $0 > 1.2 }) ?? true { chosen.append(time) }
        if chosen.count > maxFrames {
            let step = Double(chosen.count) / Double(maxFrames)
            chosen = (0..<maxFrames).map { chosen[Int(Double($0) * step)] }
        }
        let frames = try await extractFrames(asset, at: chosen, into: directory.appending(path: "frames"))

        func frame(near time: TimeInterval) -> String? {
            frames.min { abs($0.time - time) < abs($1.time - time) }.flatMap { abs($0.time - time) < 2 ? $0.path : nil }
        }
        var markdown = "# Screen annotation · \(clock(duration))\n\n"
        markdown += "I recorded my screen while talking through it and drawing on it (red ink marks what I'm pointing at). "
        markdown += "Each line is what I said at that moment, with a screenshot from then. Video: \(video.path)\n\n"
        markdown += "## Narration\n\n"
        if lines.isEmpty { markdown += "(No speech was transcribed.)\n" }
        for line in lines {
            markdown += "- [\(clock(line.time))] \(line.text)"
            if let path = frame(near: line.time) { markdown += " — \(path)" }
            markdown += "\n"
        }
        if !strokeEnds.isEmpty {
            markdown += "\n## Drawings\n\n"
            for end in strokeEnds {
                markdown += "- [\(clock(end))] drew on screen"
                if let path = frame(near: end + 0.15) { markdown += " — \(path)" }
                markdown += "\n"
            }
        }
        let transcript = directory.appending(path: "transcript.md")
        try markdown.write(to: transcript, atomically: true, encoding: .utf8)

        let spoken = lines.map(\.text).joined(separator: " ")
        var message = "Here's a screen annotation I recorded. Read \(transcript.path) and look at the screenshots it links to."
        if !spoken.isEmpty { message += "\n\nWhat I said: \(spoken)" }
        return message
    }

    /// The narration, timestamped per phrase with SpeechTranscriber, with the Words list applied.
    private static func transcribe(_ asset: AVURLAsset, in directory: URL) async throws -> [Line] {
        let audio = directory.appending(path: "narration.m4a")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return [] }
        try await export.export(to: audio, as: .m4a)
        let file = try AVAudioFile(forReading: audio)

        let settings = await MainActor.run { AppSettings.shared }
        let locale = await MainActor.run { settings.locale }
        let corrections = await MainActor.run { settings.corrections }
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return [] }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let resolution = SpeechModelCatalog.Resolution(engine: .appleSpeech, locale: supported)
        if await SpeechModelCatalog.status(of: resolution) != .installed {
            try await SpeechModelCatalog.install(resolution)
        }
        let collector = Task { () -> [Line] in
            var lines: [Line] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                lines.append(Line(time: start.isFinite ? start : 0, text: corrections.apply(to: text)))
            }
            return lines
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        let lines = try await collector.value
        withExtendedLifetime(analyzer) {}
        return lines
    }

    private static func extractFrames(_ asset: AVURLAsset, at times: [TimeInterval], into folder: URL) async throws -> [(time: TimeInterval, path: String)] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        var frames: [(TimeInterval, String)] = []
        for time in times {
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { continue }
            let url = folder.appending(path: "\(clock(time).replacingOccurrences(of: ":", with: "m"))s.jpg")
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { continue }
            try data.write(to: url)
            frames.append((time, url.path))
        }
        return frames
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Ink

/// A click-through, full-screen layer the strokes are drawn on. Strokes fade a few seconds after
/// they're finished so the screen doesn't fill up; the frames keep them.
@MainActor
final class InkOverlay {
    private var panel: NSPanel?
    private let view = InkView()

    var windowNumber: Int { panel?.windowNumber ?? 0 }

    func show(on screen: NSScreen) {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        view.strokes = []
        panel.contentView = view
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        view.stopAnimating()
        panel?.orderOut(nil)
        panel = nil
    }

    func beginStroke(at point: CGPoint) {
        guard let panel else { return }
        view.strokes.append(InkView.Stroke(points: [convert(point, panel)]))
        view.startAnimating()
    }

    func extendStroke(to point: CGPoint) {
        guard let panel, !view.strokes.isEmpty else { return }
        let local = convert(point, panel)
        if view.strokes[view.strokes.count - 1].points.last != local { view.strokes[view.strokes.count - 1].points.append(local) }
    }

    func endStroke() {
        guard !view.strokes.isEmpty else { return }
        view.strokes[view.strokes.count - 1].endedAt = Date()
    }

    private func convert(_ point: CGPoint, _ panel: NSPanel) -> CGPoint {
        CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
    }
}

final class InkView: NSView {
    struct Stroke {
        var points: [CGPoint]
        var endedAt: Date?
    }

    var strokes: [Stroke] = []
    private var timer: Timer?
    static let holdSeconds: TimeInterval = 3.5
    static let fadeSeconds: TimeInterval = 0.8

    func startAnimating() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                self.strokes.removeAll { $0.endedAt.map { now.timeIntervalSince($0) > Self.holdSeconds + Self.fadeSeconds } ?? false }
                self.needsDisplay = true
                if self.strokes.isEmpty { self.stopAnimating() }
            }
        }
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        for stroke in strokes where stroke.points.count > 0 {
            var alpha: CGFloat = 1
            if let ended = stroke.endedAt {
                let age = now.timeIntervalSince(ended) - Self.holdSeconds
                if age > 0 { alpha = max(0, 1 - CGFloat(age / Self.fadeSeconds)) }
            }
            let path = NSBezierPath()
            path.lineWidth = 5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke.points[0])
            if stroke.points.count == 1 { path.line(to: stroke.points[0]) }
            stroke.points.dropFirst().forEach { path.line(to: $0) }
            NSColor.black.withAlphaComponent(0.35 * alpha).setStroke()
            path.lineWidth = 8
            path.stroke()
            NSColor.systemRed.withAlphaComponent(alpha).setStroke()
            path.lineWidth = 5
            path.stroke()
        }
    }
}

// MARK: - Capsule

/// The small black status pill under the menu bar while annotating. Not in the recording.
@MainActor
final class AnnotationCapsule {
    private var panel: NSPanel?
    private let model = CapsuleModel()

    func show(on screen: NSScreen) {
        if panel == nil {
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = NSHostingView(rootView: CapsuleView(model: model))
            self.panel = panel
        }
        let frame = screen.visibleFrame
        panel?.setFrame(CGRect(x: frame.midX - 210, y: frame.maxY - 48, width: 420, height: 40), display: true)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func update(state: AnnotationController.State, startedAt: Date?) {
        withAnimation(Motion.content) {
            model.state = state
            model.startedAt = startedAt
        }
    }
}

@MainActor
@Observable
final class CapsuleModel {
    var state: AnnotationController.State = .idle
    var startedAt: Date?
}

private struct CapsuleView: View {
    let model: CapsuleModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .recording:
                Circle().fill(.red).frame(width: 8, height: 8)
                if let started = model.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(AnnotationBundle.clock(context.date.timeIntervalSince(started)))
                            .monospacedDigit()
                    }
                }
                Text("Hold ⇧ to draw · \(AppSettings.shared.annotateShortcut?.display ?? "menu bar") to finish").foregroundStyle(.white.opacity(0.6))
            case .starting:
                ProgressView().controlSize(.small)
                Text("Starting…")
            case .processing:
                ProgressView().controlSize(.small)
                Text("Preparing for your agent…")
            case .done(let message):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Capsule().fill(.black))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}
