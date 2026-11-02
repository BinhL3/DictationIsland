import AppKit
import Observation
import SwiftUI

/// What the dictation session is doing.
enum DictationPhase: Equatable {
    case idle
    /// Downloading the on-device speech model (first use of a language), 0...1.
    case preparing(Double)
    case listening
    case finishing
    case done(InsertResult)
    case error(String)
}

enum InsertResult: Equatable {
    case pasted
    case copied
    case empty
}

/// How big the island is. One derived value rather than several independent flags, so every
/// view animates off the same key.
enum Presentation: Equatable {
    case closed
    /// Wings either side of the notch: status glyph left, waveform right.
    case compact
    /// One centred row with an icon and a short message ("Pasted", errors). Pill style only;
    /// on a notch the message can't sit under the camera, so it uses compact/peek instead.
    case message
    /// Compact plus one line of live transcript underneath.
    case peek
    /// Hovered or erroring: full transcript and controls.
    case expanded
}

@MainActor
@Observable
final class IslandModel {
    private(set) var phase: DictationPhase = .idle
    private(set) var transcript = ""
    /// Drives the elapsed timer; `listeningEndedAt` freezes it while transcribing.
    private(set) var listeningStartedAt: Date?
    private(set) var listeningEndedAt: Date?
    var isHovering = false {
        didSet { if isHovering != oldValue { hoverChangedAt = Date() } }
    }
    /// Lets `shapeAnimation` give hover morphs a snappier spring than state-driven ones.
    @ObservationIgnored private var hoverChangedAt = Date.distantPast
    private(set) var geometry: NotchGeometry
    /// Bumped to replay the error shake.
    private(set) var shakeTrigger: CGFloat = 0

    /// False hides the resting island (screens without a notch, or when placed below the menu bar).
    var showsIdleIsland = true

    @ObservationIgnored let settings = AppSettings.shared
    @ObservationIgnored let meter = LevelMeter(bandCount: 6)
    @ObservationIgnored var simulatesAudio = false
    @ObservationIgnored private lazy var audio = AudioCapture(meter: meter)
    /// The take being captured. `stop()` hands it off to `outputChain`, so the next press can
    /// start a new one while it finishes.
    @ObservationIgnored private var transcriber: Transcriber?
    @ObservationIgnored private var gate: AudioGate?
    /// Resolves once the transcriber is ready; finishing waits on it so a quick tap can't race setup.
    @ObservationIgnored private var sessionSetup: Task<Bool, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    /// The current take's id. Bumped for every new take and whenever one is abandoned, so setup
    /// still in flight for it gives up.
    @ObservationIgnored private var generation = 0
    /// The take whose transcript and result the island shows. Lags `generation` while a take
    /// is armed but hidden, and while an earlier take finishes behind a newer one.
    @ObservationIgnored private var shownTake = 0
    /// Latest live text of the current take, shown when an armed take is revealed.
    @ObservationIgnored private var activePartial = ""
    /// Finished takes paste in the order they were spoken: each job waits for the one before.
    @ObservationIgnored private var outputChain: Task<Void, Never>?
    /// Finishing takes the user cancelled; their text is dropped instead of pasted.
    @ObservationIgnored private var cancelledTakes: Set<Int> = []
    /// The mic stays open this long after release, because a release often lands while the last
    /// word is still sounding (Hex measured clipped final words without it).
    static let releaseTail: Duration = .milliseconds(200)
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// The take the tail is still recording for.
    @ObservationIgnored private var tailTake: Int?
    /// Safety net for any engine whose final result never arrives; the last live text is used.
    static let finishDeadline: Duration = .seconds(15)
    /// A session is being set up or is capturing (the phase may still be idle while armed).
    @ObservationIgnored private var isCapturing = false
    /// The mic is running for the current session.
    @ObservationIgnored private var isCaptureRunning = false
    /// Capturing on key-down but not shown yet; see `arm()`.
    @ObservationIgnored private(set) var isArmed = false
    /// Engine actually used for the current/last session, for display.
    private(set) var activeEngine: SpeechEngine?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    // MARK: Derived presentation

    var presentation: Presentation {
        let isPill = geometry.style == .pill
        switch phase {
        case .idle: return .closed
        case .preparing: return isPill ? .message : .compact
        case .error: return isHovering ? .expanded : (isPill ? .message : .peek)
        case .done: return isHovering ? .expanded : (isPill ? .message : .compact)
        case .listening, .finishing:
            if isHovering { return .expanded }
            return transcript.isEmpty ? .compact : .peek
        }
    }

    /// Text for the `.message` row and for notch-style done/error states.
    var messageText: String? {
        switch phase {
        case .done(.pasted): return "Pasted"
        case .done(.copied): return "Copied to clipboard"
        case .done(.empty): return "No speech detected"
        case .preparing(let fraction): return "Downloading speech model · \(Int(fraction * 100))%"
        case .error(let message): return message
        default: return nil
        }
    }

    // MARK: Layout
    //
    // One spacing system for every state:
    // - every row shares `contentInset`, so the dot, transcript, hint and message line up;
    // - header glyphs and the waveform sit in `glyphSize` boxes on one centre line;
    // - footer controls are inset by `controlInset` so they sit concentric with the bottom corner
    //   (corner radius = controlInset + control height / 2).

    enum Metrics {
        static let contentInset: CGFloat = 12
        static let glyphSize: CGFloat = 14
        static let glyphSpacing: CGFloat = 6
        static let timerWidth: CGFloat = 32
        static let waveformWidth: CGFloat = 31
        static let wingGap: CGFloat = 20
        static let transcriptLineHeight: CGFloat = 20
        static let rowBottomPadding: CGFloat = 10
        static let controlInset: CGFloat = 10
        static let controlHeight: CGFloat = 24
        static let transcriptFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        static let transcriptLineSpacing: CGFloat = 3
        static let maxTranscriptLines = 4
        static let messageFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)

        static var leadingWingWidth: CGFloat { glyphSize + glyphSpacing + timerWidth }
    }

    /// Concave "ears" of the notch shape; content must stay inside them.
    var earInset: CGFloat {
        geometry.style == .notch ? cornerRadii.top : 0
    }

    var horizontalInset: CGFloat {
        Metrics.contentInset + earInset
    }

    /// Top-row height that stays constant across presentations, so the header never jumps. It
    /// matches the resting island, so opening only stretches it sideways out of the same spot
    /// (and a menu-bar pill never hangs below the menu bar).
    var headerHeight: CGFloat {
        geometry.closedSize.height
    }

    private var compactWidth: CGFloat {
        let wings = Metrics.leadingWingWidth + Metrics.waveformWidth
        switch geometry.style {
        case .notch:
            // Both wings get the wider wing's width so the camera stays centred between them.
            let wing = Metrics.contentInset + Metrics.leadingWingWidth + 8
            return geometry.closedSize.width + 2 * (wing + cornerRadii.top)
        case .pill:
            return 2 * Metrics.contentInset + wings + Metrics.wingGap
        }
    }

    private var messageWidth: CGFloat {
        let text = (messageText ?? "") as NSString
        let textWidth = ceil(text.size(withAttributes: [.font: Metrics.messageFont]).width)
        let width = 2 * Metrics.contentInset + Metrics.glyphSize + 8 + textWidth + 6
        return min(max(width, compactWidth), 420)
    }

    var islandSize: CGSize {
        switch presentation {
        case .closed:
            return geometry.closedSize
        case .compact:
            return CGSize(width: compactWidth, height: headerHeight)
        case .message:
            return CGSize(width: messageWidth, height: headerHeight)
        case .peek:
            return CGSize(
                width: max(compactWidth, 360),
                height: headerHeight + Metrics.transcriptLineHeight + Metrics.rowBottomPadding
            )
        case .expanded:
            let width = max(compactWidth, 420)
            return CGSize(width: width, height: headerHeight + expandedBodyHeight(width: width))
        }
    }

    /// Grows with the transcript, 1–4 lines, so short dictations don't leave a dead block.
    private func expandedBodyHeight(width: CGFloat) -> CGFloat {
        let text: String
        switch phase {
        case .error(let message): text = message
        default: text = transcript.isEmpty ? "Listening…" : transcript
        }
        let textWidth = width - 2 * horizontalInset
        let lineHeight = ceil(Metrics.transcriptFont.ascender - Metrics.transcriptFont.descender + Metrics.transcriptFont.leading)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: Metrics.transcriptFont]
        )
        let lines = min(Metrics.maxTranscriptLines, max(1, Int(ceil(bounds.height / lineHeight - 0.1))))
        let textHeight = CGFloat(lines) * lineHeight + CGFloat(lines - 1) * Metrics.transcriptLineSpacing
        // top 2 + text + gap 10 + controls + bottom inset
        return 2 + textHeight + 10 + Metrics.controlHeight + Metrics.controlInset
    }

    var cornerRadii: (top: CGFloat, bottom: CGFloat) {
        let concentric = Metrics.controlInset + Metrics.controlHeight / 2
        switch (geometry.style, presentation) {
        case (.notch, .closed): return (6, 10)
        case (.notch, .compact), (.notch, .message): return (6, 14)
        case (.notch, .peek): return (8, 18)
        case (.notch, .expanded): return (12, concentric)
        case (.pill, .closed): return (0, geometry.closedSize.height / 2)
        case (.pill, .compact), (.pill, .message): return (0, headerHeight / 2)
        case (.pill, .peek): return (0, 18)
        case (.pill, .expanded): return (0, concentric)
        }
    }

    /// Shape morphs use bouncy springs; collapses use the overdamped one so they settle cleanly.
    var shapeAnimation: Animation {
        if Date().timeIntervalSince(hoverChangedAt) < 0.05, presentation != .closed { return Motion.hover }
        switch presentation {
        case .closed: return Motion.close
        case .compact, .message: return Motion.widen
        case .peek, .expanded: return Motion.open
        }
    }

    // MARK: Actions

    func updateGeometry(_ geometry: NotchGeometry) {
        self.geometry = geometry
    }

    func toggle() {
        switch phase {
        case .listening: stop()
        case .preparing: cancel()
        // Includes .finishing: the next take starts while the last one finishes.
        default: start()
        }
    }

    /// Starts listening without showing anything, as soon as a trigger key goes down, so the mic is
    /// already running by the time the press counts as a hold (~200 ms later). `start()` reveals
    /// the session; `disarm()` drops it if the press turned out to be a shortcut. Nothing is shown
    /// and media isn't muffled until then; only the system mic indicator flashes.
    func arm() {
        switch phase {
        case .idle, .done, .error, .finishing: break
        default: return
        }
        guard !simulatesAudio, !isCapturing else { return }
        isArmed = true
        beginSession()
    }

    /// The armed press became a shortcut: stop the hidden session.
    func disarm() {
        guard isArmed else { return }
        isArmed = false
        endCapture()
    }

    func start() {
        if isArmed {
            isArmed = false
            dismissTask?.cancel()
            // Still setting up: `beginSession` shows the island once the mic is running.
            if isCaptureRunning { reveal(.listening) }
            return
        }
        switch phase {
        case .listening, .preparing: return
        default: break
        }
        guard !isCapturing else { return }
        dismissTask?.cancel()
        if simulatesAudio {
            transcript = ""
            setPhase(.listening)
            return
        }
        beginSession()
    }

    /// Puts the current take on the island.
    private func reveal(_ newPhase: DictationPhase) {
        shownTake = generation
        transcript = activePartial
        setPhase(newPhase)
    }

    private func beginSession() {
        // A previous take still in its release tail gives up the mic now.
        cutTail()
        generation += 1
        let session = generation
        isCapturing = true
        isCaptureRunning = false
        activePartial = ""
        if settings.styleRewrite { StyleRewriter.prepare(style: settings.styleInstructions) }
        Task {
            // Each await can outlive the session (a disarm or cancel meanwhile).
            @MainActor func current() -> Bool { session == generation }
            guard await AudioCapture.requestPermission() else {
                return failSession(session, "Microphone access denied")
            }
            let resolution = await SpeechModelCatalog.resolve(settings.speechEngine, locale: settings.locale)
            let transcriber = makeTranscriber(for: resolution, take: session)
            guard await transcriber.requestPermission() else {
                return failSession(session, "Speech recognition denied")
            }
            guard current() else { return }

            // First use of a language: fetch the on-device model before listening. This needs the
            // island, so an armed press reveals itself.
            if await SpeechModelCatalog.status(of: resolution) == .downloadable {
                guard current() else { return }
                isArmed = false
                reveal(.preparing(0))
                do {
                    try await SpeechModelCatalog.install(resolution) { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, case .preparing = self.phase else { return }
                            self.phase = .preparing(fraction)
                        }
                    }
                } catch {
                    return failSession(session, "Couldn't download the speech model")
                }
                guard current(), case .preparing = phase else { return }  // cancelled meanwhile
            }
            guard current() else { return }

            // Capture starts immediately; audio is held by the gate until the model is ready,
            // so the first words aren't lost while SpeechAnalyzer spins up.
            let gate = AudioGate()
            self.gate = gate
            self.transcriber = transcriber
            activeEngine = resolution.engine
            do {
                try audio.start(deviceUID: settings.resolvedMicrophoneUID, channel: settings.inputChannel) { buffer in
                    gate.push(buffer)
                }
            } catch {
                return failSession(session, error.localizedDescription)
            }
            isCaptureRunning = true
            if !isArmed { reveal(.listening) }

            let setup = Task { @MainActor [weak self] () -> Bool in
                do {
                    try await transcriber.begin(locale: resolution.locale)
                    gate.open(into: transcriber)
                    return true
                } catch {
                    self?.failSession(session, error.localizedDescription)
                    return false
                }
            }
            sessionSetup = setup
        }
    }

    func stop() {
        guard phase == .listening else { return }
        // The island and media react at the release; only the mic keeps going for the tail.
        setPhase(.finishing)
        if simulatesAudio { return }
        let take = generation
        let spoken = listeningStartedAt.map { Date().timeIntervalSince($0) }
        let transcriber = self.transcriber, setup = sessionSetup, fallback = activePartial
        self.transcriber = nil
        gate = nil
        sessionSetup = nil
        isCapturing = false
        isCaptureRunning = false
        startTail(for: take)

        let tail = self.tail, previous = outputChain
        outputChain = Task { [weak self] in
            await tail?.value
            var text = ""
            if await setup?.value == true, let transcriber {
                text = await Self.finish(transcriber, fallback: fallback)
            }
            // Formatting and the style rewrite run alongside earlier takes' pastes; only the
            // paste itself waits its turn.
            if let settings = self?.settings { text = await TextPipeline.process(text, settings: settings) }
            await previous?.value
            self?.deliver(text, take: take, seconds: spoken)
        }
    }

    private static func finish(_ transcriber: Transcriber, fallback: String) async -> String {
        final class Result: @unchecked Sendable { var text = "" }
        let result = Result()
        let finished = await withDeadline(finishDeadline) { result.text = await transcriber.finish() }
        return finished ? result.text : fallback
    }

    /// Records and pastes one finished take. Only the take on the island changes the island; an
    /// earlier take finishing behind a newer one pastes without showing anything.
    private func deliver(_ text: String, take: Int, seconds: Double?) {
        if cancelledTakes.remove(take) != nil { return }
        settings.record(text, seconds: seconds)
        let result = TextInserter.insert(text, autoPaste: settings.autoPaste)
        guard take == shownTake, phase == .finishing else { return }
        transcript = text
        setPhase(.done(result))
        scheduleDismiss(after: 1.4)
    }

    private func startTail(for take: Int) {
        tailTake = take
        tail = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseTail)
            guard let self, self.tailTake == take else { return }
            self.tailTake = nil
            self.audio.stop()
        }
    }

    /// Ends a release tail early, because a new take needs the mic.
    private func cutTail() {
        guard tailTake != nil else { return }
        tailTake = nil
        tail?.cancel()
        audio.stop()
    }

    /// Gets the next dictation ready to start quickly: builds the mic engine for the current input
    /// (without opening the mic) and warms up the speech model lookup. Cheap to call again.
    func prepare() {
        guard !simulatesAudio else { return }
        // Not during a release tail: the engine is still recording the last take.
        guard tailTake == nil else { return }
        audio.prepare(deviceUID: settings.resolvedMicrophoneUID, channel: settings.inputChannel)
        let engine = settings.speechEngine, locale = settings.locale
        Task.detached(priority: .utility) {
            let resolution = await SpeechModelCatalog.resolve(engine, locale: locale)
            _ = await SpeechModelCatalog.status(of: resolution)
        }
    }

    func cancel() {
        isArmed = false
        if phase == .finishing { cancelledTakes.insert(shownTake) }
        if !simulatesAudio { endCapture() }
        transcript = ""
        setPhase(.idle)
    }

    /// Stops the mic and abandons the current session, including one still being set up.
    private func endCapture() {
        generation += 1
        isCapturing = false
        isCaptureRunning = false
        cutTail()
        audio.stop()
        transcriber?.cancel()
        transcriber = nil
        gate = nil
        sessionSetup = nil
    }

    private func failSession(_ session: Int, _ message: String) {
        guard session == generation else { return }
        isArmed = false
        endCapture()
        fail(message)
    }

    private func makeTranscriber(for resolution: SpeechModelCatalog.Resolution, take: Int) -> Transcriber {
        let transcriber: Transcriber
        let hints = settings.corrections.hints
        switch resolution.engine {
        case .legacy:
            let apple = AppleSpeechTranscriber()
            apple.contextualStrings = hints
            transcriber = apple
        case .bark: transcriber = SegmentedTranscriber { try await BarkModels.shared() }
        case .parakeet: transcriber = SegmentedTranscriber { try await ParakeetModels.shared() }
        default:
            let analyzer = SpeechAnalyzerTranscriber(resolution: resolution)
            analyzer.contextualStrings = hints
            transcriber = analyzer
        }
        transcriber.onPartial = { [weak self] text in
            guard let self else { return }
            let text = self.settings.corrections.apply(to: text)
            if take == self.generation { self.activePartial = text }
            guard take == self.shownTake, self.phase == .listening || self.phase == .finishing else { return }
            withAnimation(Motion.content) { self.transcript = text }
        }
        return transcriber
    }

    private func fail(_ message: String) {
        setPhase(.error(message))
        withAnimation(.linear(duration: 0.4)) { shakeTrigger += 1 }
        scheduleDismiss(after: 2.5)
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.isHovering else { return }
            self.transcript = ""
            self.setPhase(.idle)
        }
    }

    private func setPhase(_ newPhase: DictationPhase) {
        if newPhase == .listening {
            listeningStartedAt = Date()
            listeningEndedAt = nil
            if !simulatesAudio { MediaMuffler.shared.engage() }
        } else if phase == .listening {
            listeningEndedAt = Date()
            MediaMuffler.shared.release()
        }
        withAnimation(Motion.content) { phase = newPhase }
    }

    // MARK: Demo / screenshot support

    /// Pins a state for UI iteration without a microphone (`--state <name>`).
    func pin(_ state: String) {
        simulatesAudio = true
        let sample = "Let's move the design review to Thursday and loop in the platform team"
        listeningStartedAt = Date().addingTimeInterval(-4)
        if state == "finishing" { listeningEndedAt = Date() }
        switch state {
        case "compact": phase = .listening
        case "peek": phase = .listening; transcript = sample
        case "expanded": phase = .listening; transcript = sample; isHovering = true
        case "finishing": phase = .finishing; transcript = sample
        case "done": phase = .done(.pasted)
        case "copied": phase = .done(.copied)
        case "error": phase = .error("Microphone access denied")
        case "preparing": phase = .preparing(0.42)
        default: phase = .idle
        }
    }

    /// Walks through a full dictation (`--demo`).
    func runDemo() async {
        simulatesAudio = true
        let words = "Let's move the design review to Thursday and loop in the platform team so they can weigh in on latency".split(separator: " ")
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.2))
            start()
            try? await Task.sleep(for: .seconds(1.2))
            for count in 1...words.count {
                withAnimation(Motion.content) { transcript = words.prefix(count).joined(separator: " ") }
                try? await Task.sleep(for: .milliseconds(220))
            }
            try? await Task.sleep(for: .seconds(0.6))
            stop()
            try? await Task.sleep(for: .seconds(1.0))
            setPhase(.done(.pasted))
            try? await Task.sleep(for: .seconds(1.4))
            transcript = ""
            setPhase(.idle)
        }
    }

    /// One scripted dictation that really pastes into the frontmost app, then quits (`--record`).
    /// For screen recordings: words stream in like a live recognizer, then the text lands.
    func runRecording(_ text: String) async {
        simulatesAudio = true
        let words = text.split(separator: " ")
        try? await Task.sleep(for: .seconds(1.5))
        FileHandle.standardError.write("listening \(Date().timeIntervalSince1970)\n".data(using: .utf8)!)
        start()
        try? await Task.sleep(for: .seconds(0.9))
        var shown = 0
        while shown < words.count {
            // Recognizers publish in small bursts, not one word at a time.
            shown = min(words.count, shown + Int.random(in: 1...2))
            withAnimation(Motion.content) { transcript = words.prefix(shown).joined(separator: " ") }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 230...380)))
        }
        try? await Task.sleep(for: .seconds(0.7))
        FileHandle.standardError.write("released \(Date().timeIntervalSince1970)\n".data(using: .utf8)!)
        stop()
        try? await Task.sleep(for: .seconds(0.8))
        setPhase(.done(TextInserter.insert(text, autoPaste: true)))
        scheduleDismiss(after: 1.4)
        try? await Task.sleep(for: .seconds(4))
        NSApp.terminate(nil)
    }
}
