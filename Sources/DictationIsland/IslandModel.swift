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
    private(set) var transcript = "" {
        didSet { syncWords() }
    }
    /// `transcript` as words to draw, with live-edit marks (see `LiveWordTrack`).
    private(set) var liveWords: [LiveWord] = []
    @ObservationIgnored private var wordTrack = LiveWordTrack()
    /// Set just before a `transcript` change that should show its edits.
    @ObservationIgnored private var markNextChange = false
    @ObservationIgnored private var nextCorrections = LiveWordTrack.Corrections.none
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    /// Keeps marks on screen (`--state edits`, for screenshots).
    @ObservationIgnored private var freezesMarks = false
    /// The finished text changed words on screen (the clean-up, Fix that): the done state keeps
    /// the transcript line open for a moment to show them.
    private(set) var showsFinalEdits = false
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
    /// Replaces "Transcribing" while finishing ("Fixing" for Fix that).
    private(set) var finishingLabel = "Transcribing"
    /// Replaces "Pasted" on the result ("Fixed").
    private(set) var doneLabel: String?
    /// What the last dictation pasted, for "Fix that".
    private struct LastDelivery {
        var text: String
        var context: WritingContext?
        /// The take's audio and the engine that heard it, so Fix that can listen again.
        var recording: TakeRecording?
        var engine: SpeechEngine?
        var pasted: Bool
        /// `AppStatus.inputRevision` right after the paste; if it moved, the person has typed
        /// or clicked since and an undo would take back their work, not ours.
        var inputRevision: Int
    }
    @ObservationIgnored private var lastDelivery: LastDelivery?
    /// The take is also hearing the computer's audio (toggled with its shortcut mid-dictation).
    private(set) var hearsComputer = false
    @ObservationIgnored private var computerAudio: ComputerAudioSlot?
    @ObservationIgnored private var takeRecording: TakeRecording?
    /// The emoji for a laugh heard right now; the island's dot shows it instead.
    private(set) var laughingEmoji: String?
    @ObservationIgnored private var laughDetector: LaughDetector?
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
        // Nothing was heard: just the crossed-out mic, no words and no panel on hover.
        case .done(.empty): return .compact
        case .done where showsFinalEdits: return isHovering ? .expanded : .peek
        case .done: return isHovering ? .expanded : (isPill ? .message : .compact)
        case .listening, .finishing:
            if isHovering { return .expanded }
            return transcript.isEmpty ? .compact : .peek
        }
    }

    /// Text for the `.message` row and for notch-style done/error states.
    var messageText: String? {
        switch phase {
        case .done(.pasted): return doneLabel ?? "Pasted"
        case .done(.copied): return doneLabel ?? "Copied to clipboard"
        case .done(.empty): return nil
        case .preparing(let fraction): return "Downloading speech model · \(Int(fraction * 100))%"
        case .error(let message): return message
        default: return nil
        }
    }

    /// Text the notch layout puts in the right wing, if any (see `IslandView.trailingWing`).
    var trailingLabel: String? {
        switch phase {
        case .done: return messageText
        case .preparing(let fraction): return "\(Int(fraction * 100))%"
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
        /// The notch's right-wing label ("Pasted", "No speech detected", "42%").
        static let wingLabelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

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
            // A label like "No speech detected" goes in the right wing, so that wing (and its
            // twin) grows to fit it; otherwise it would slide under the camera housing, which
            // screenshots don't show but your eyes do.
            var wing = Metrics.contentInset + Metrics.leadingWingWidth + 8
            // Nothing heard is just the crossed-out mic: a slim island that hugs it.
            if phase == .done(.empty) { wing = Metrics.contentInset + Metrics.glyphSize + 8 }
            if let label = trailingLabel {
                let width = ceil((label as NSString).size(withAttributes: [.font: Metrics.wingLabelFont]).width)
                wing = max(wing, Metrics.contentInset + width + 10)
            }
            return geometry.closedSize.width + 2 * (wing + cornerRadii.top)
        case .pill:
            if phase == .done(.empty) { return 2 * Metrics.contentInset + Metrics.glyphSize + 16 }
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
        default: text = transcript.isEmpty ? placeholder : transcript
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

    /// What the expanded panel says before there's any text.
    var placeholder: String {
        phase == .finishing ? finishingLabel + "…" : "Listening…"
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
        finishingLabel = "Transcribing"
        doneLabel = nil
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
        let laughs = settings.laughEmoji && !simulatesAudio ? LaughDetector() : nil
        laughs?.onLaughing = { [weak self] emoji in
            MainActor.assumeIsolated {
                guard let self, session == self.shownTake, self.phase == .listening else { return }
                withAnimation(Motion.content) { self.laughingEmoji = emoji }
            }
        }
        laughDetector = laughs
        let computer = ComputerAudioSlot()
        computerAudio = computer
        let recording = TakeRecording()
        takeRecording = recording
        hearsComputer = false
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
                    computer.mix(into: buffer)
                    recording.append(buffer)
                    gate.push(buffer)
                    laughs?.append(buffer)
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
        SoundCues.play(.stop)
        let take = generation
        let spoken = listeningStartedAt.map { Date().timeIntervalSince($0) }
        let transcriber = self.transcriber, setup = sessionSetup, fallback = activePartial
        let laughs = laughDetector
        laughDetector = nil
        laughingEmoji = nil
        let computer = computerAudio
        computerAudio = nil
        hearsComputer = false
        let recording = takeRecording, engine = activeEngine
        takeRecording = nil
        self.transcriber = nil
        gate = nil
        sessionSetup = nil
        isCapturing = false
        isCaptureRunning = false
        startTail(for: take)

        let tail = self.tail, previous = outputChain
        // The computer's audio keeps flowing through the release tail, then stops.
        Task { await tail?.value; computer?.set(nil) }
        outputChain = Task { [weak self] in
            await tail?.value
            // Where the text is going (app, window, text before the cursor), read off the main
            // thread with a short timeout. Used by the tidy-up and by Fix that.
            let context = await Task.detached { WritingContext.captureFocused() }.value
            var text = ""
            if await setup?.value == true, let transcriber {
                text = await Self.finish(transcriber, fallback: fallback)
            }
            // Formatting and the style rewrite run alongside earlier takes' pastes; only the
            // paste itself waits its turn.
            if let settings = self?.settings { text = await TextPipeline.process(text, settings: settings, context: context) }
            // After the rewrite, so the tidy-up can't drop the emoji. A take that was only a laugh
            // has no words (recognizers don't write laughter down), so the laugh is the message.
            if let laughs {
                let found = await laughs.finish()
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = found.map(\.emoji).joined()
                } else {
                    text = LaughDetector.insert(found, into: text, duration: spoken ?? 0)
                }
            }
            await previous?.value
            self?.deliver(text, take: take, seconds: spoken, context: context, recording: recording, engine: engine)
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
    private func deliver(_ text: String, take: Int, seconds: Double?, context: WritingContext?, recording: TakeRecording?, engine: SpeechEngine?) {
        if cancelledTakes.remove(take) != nil { return }
        settings.record(text, seconds: seconds)
        let result = TextInserter.insert(text, autoPaste: settings.autoPaste)
        if result != .empty {
            lastDelivery = LastDelivery(
                text: text, context: context, recording: recording, engine: engine,
                pasted: result == .pasted, inputRevision: AppStatus.shared.inputRevision
            )
        }
        guard take == shownTake, phase == .finishing else { return }
        if result != .empty { SoundCues.play(.done) }
        showFinal(text)
        setPhase(.done(result))
        scheduleDismiss(after: showsFinalEdits ? 2.2 : 1.4)
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

    // MARK: Computer audio

    /// Mid-dictation: start or stop mixing what the Mac is playing into this take. Ignored when
    /// not dictating, so a stray tap of the key does nothing.
    func toggleComputerAudio() {
        guard phase == .listening, let slot = computerAudio else { return }
        if slot.isOn {
            slot.set(nil)
            withAnimation(Motion.content) { hearsComputer = false }
            return
        }
        guard SystemAudioPermission.status == .authorized else {
            // First time: macOS asks; the next tap works once it's allowed.
            SystemAudioPermission.request()
            return
        }
        guard let capture = SystemAudioCapture() else { return }
        slot.set(capture)
        // You're capturing it, so you should hear it: no muffle for the rest of this take.
        MediaMuffler.shared.release()
        withAnimation(Motion.content) { hearsComputer = true }
    }

    // MARK: Fix that

    /// Fixes the last dictation. First it listens again: the same audio through a *different*
    /// engine (a misheard word can't be fixed from the text alone). Then Apple Intelligence tidies
    /// the result. The new version replaces the old one in place; if the person has typed or
    /// clicked since (or switched apps), undoing would take back their work, so it's copied.
    func fixLast() {
        switch phase {
        case .idle, .done, .error: break
        default: return
        }
        guard let last = lastDelivery else { return fail("Nothing to fix yet") }
        if last.recording == nil, StyleRewriter.availability != nil {
            return fail("Turn on Apple Intelligence to fix dictations")
        }
        dismissTask?.cancel()
        shownTake = -1
        finishingLabel = "Fixing"
        doneLabel = nil
        transcript = last.text
        listeningStartedAt = Date()
        listeningEndedAt = listeningStartedAt
        setPhase(.finishing)
        Task {
            var candidate = last.text
            if let recording = last.recording {
                let audio = recording.audio
                if let second = await SecondOpinion.transcribe(audio.samples, sampleRate: audio.sampleRate, firstEngine: last.engine, locale: settings.locale) {
                    candidate = second.text
                    if settings.spokenFormatting { candidate = SpokenFormatter.apply(to: candidate) }
                    candidate = settings.corrections.apply(to: candidate)
                }
            }
            if StyleRewriter.availability == nil {
                // The person asked and is watching: allow a cold model time to load.
                candidate = await StyleRewriter.rewrite(candidate, instructions: settings.styleInstructions, context: last.context, always: true, timeout: .seconds(10))
                candidate = settings.corrections.apply(to: candidate)
            }
            guard phase == .finishing, finishingLabel == "Fixing" else { return }
            if candidate == last.text {
                doneLabel = "No better version"
                setPhase(.done(.pasted))
                return scheduleDismiss(after: 1.6)
            }
            let fixed = candidate
            let sameApp = last.context.map { $0.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier } ?? true
            let untouched = last.pasted && sameApp && AppStatus.shared.inputRevision == last.inputRevision
            let result: InsertResult
            if untouched {
                TextInserter.undo()
                try? await Task.sleep(for: .milliseconds(120))
                result = TextInserter.insert(fixed, autoPaste: true)
            } else {
                result = TextInserter.insert(fixed, autoPaste: false)
            }
            settings.replaceLatest(with: fixed)
            var updated = last
            updated.text = fixed
            updated.pasted = result == .pasted
            updated.inputRevision = AppStatus.shared.inputRevision
            lastDelivery = updated
            showFinal(fixed)
            doneLabel = result == .pasted ? "Fixed" : "Fixed · copied"
            setPhase(.done(result))
            scheduleDismiss(after: showsFinalEdits ? 2.4 : 1.6)
        }
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
        laughDetector = nil
        laughingEmoji = nil
        computerAudio?.set(nil)
        computerAudio = nil
        takeRecording = nil
        hearsComputer = false
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
        transcriber.onPartial = { [weak self] heard in
            guard let self else { return }
            let text = self.settings.corrections.apply(to: heard)
            if take == self.generation { self.activePartial = text }
            guard take == self.shownTake, self.phase == .listening || self.phase == .finishing else { return }
            if self.settings.liveEdits {
                self.markNextChange = true
                if text != heard {
                    self.nextCorrections = LiveWordTrack.corrections(raw: LiveWordTrack.split(heard), corrected: LiveWordTrack.split(text))
                }
            }
            withAnimation(Motion.content) { self.transcript = text }
        }
        return transcriber
    }

    private func fail(_ message: String) {
        if !simulatesAudio { SoundCues.play(.error) }
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

    /// The finished text replaces the live one, showing what changed when live edits are on.
    private func showFinal(_ text: String) {
        markNextChange = settings.liveEdits
        withAnimation(Motion.content) { transcript = text }
        // Only worth holding the line open if a change is in the part it shows.
        showsFinalEdits = settings.liveEdits && wordTrack.words.suffix(LiveTranscriptLine.maxWords).contains { $0.mark != .plain }
    }

    /// Keeps `liveWords` in step with `transcript`.
    private func syncWords() {
        let mark = markNextChange && settings.liveEdits
        wordTrack.update(to: LiveWordTrack.split(transcript), mark: mark, corrections: mark ? nextCorrections : .none)
        markNextChange = false
        nextCorrections = .none
        liveWords = wordTrack.words
        schedulePrune()
    }

    /// Fades marks out when their time is up.
    private func schedulePrune() {
        pruneTask?.cancel()
        guard !freezesMarks, let next = wordTrack.nextExpiry else { return }
        pruneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            if self.wordTrack.prune() {
                withAnimation(Motion.content) { self.liveWords = self.wordTrack.words }
            }
            self.schedulePrune()
        }
    }

    private func setPhase(_ newPhase: DictationPhase) {
        if case .done = newPhase {} else { showsFinalEdits = false }
        if newPhase == .listening {
            listeningStartedAt = Date()
            listeningEndedAt = nil
            if !simulatesAudio {
                SoundCues.play(.start)
                MediaMuffler.shared.engage()
            }
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
        case "empty": phase = .done(.empty)
        case "edits", "edits-done":
            freezesMarks = true
            phase = state == "edits" ? .listening : .finishing
            transcript = "um so let's move the design review to Tuesday and loop in"
            markNextChange = true
            transcript = "um so let's move the design review to Thursday and loop in the platform team"
            if state == "edits-done" {
                showFinal("So let's move the design review to Thursday and loop in the platform team.")
                phase = .done(.pasted)
            }
        case "error": phase = .error("Microphone access denied")
        case "preparing": phase = .preparing(0.42)
        default: phase = .idle
        }
    }

    /// Walks through a full dictation (`--demo`).
    func runDemo() async {
        simulatesAudio = true
        let words = "um let's move the design review to Tuesday and loop in the platform team so they can weigh in on latency".split(separator: " ")
        let revised = 8  // "Tuesday" is heard again as "Thursday" a moment later
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.2))
            start()
            try? await Task.sleep(for: .seconds(1.2))
            for count in 1...words.count {
                var shown = words.prefix(count).map(String.init)
                if count > revised + 1 { shown[revised] = "Thursday" }
                markNextChange = true
                withAnimation(Motion.content) { transcript = shown.joined(separator: " ") }
                try? await Task.sleep(for: .milliseconds(220))
            }
            try? await Task.sleep(for: .seconds(0.6))
            stop()
            try? await Task.sleep(for: .seconds(1.0))
            showFinal("Let's move the design review to Thursday and loop in the platform team so they can weigh in on latency.")
            setPhase(.done(.pasted))
            try? await Task.sleep(for: .seconds(showsFinalEdits ? 2.2 : 1.4))
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
