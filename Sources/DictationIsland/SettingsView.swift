import AppKit
import ServiceManagement
import Speech
import SwiftUI

// MARK: - General

struct GeneralSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach(settings.pushToTalkKeys) { key in
                    HStack {
                        KeyCap(name: key.name)
                        Spacer()
                        Button {
                            settings.pushToTalkKeys.removeAll { $0 == key }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                KeyRecorderRow { key in
                    if !settings.pushToTalkKeys.contains(key) { settings.pushToTalkKeys.append(key) }
                    // A key can't both start dictation and fix the last one.
                    if case .modifier(let code)? = settings.fixShortcut, code == key.keyCode { settings.fixShortcut = nil }
                }
                if settings.pushToTalkKeys.contains(.fn) {
                    GlobeKeyWarning()
                }
                Toggle("Also use \(HotKey.symbol)", isOn: $settings.fallbackShortcutEnabled)
                Picker("How the key works", selection: $settings.talkMode) {
                    ForEach(TalkMode.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Push-to-talk keys")
            } footer: {
                // Built as a String first: interpolating into the key itself passes the note as an
                // argument, and arguments aren't parsed as markdown.
                Text(LocalizedStringKey(String("\(talkModeNote) Any listed key works. Add fn for an external keyboard and right ⌥ for the laptop to use both setups without switching. \(HotKey.symbol) needs no permission; plain ⌥Space is left alone for Raycast.")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Fix last dictation") {
                    ShortcutRecorder(shortcut: $settings.fixShortcut)
                }
                LabeledContent("Annotate screen") {
                    ShortcutRecorder(shortcut: $settings.annotateShortcut)
                }
                .disabled(!settings.annotateEnabled)
                LabeledContent("Include computer audio") {
                    ShortcutRecorder(shortcut: $settings.computerAudioShortcut)
                }
            } header: {
                Text("More shortcuts")
            } footer: {
                Text("Click a shortcut, then press a key on its own (like right ⌘, used by tapping it) or a combination (like ⌃⌥A). **Fix last dictation** rewrites what you just dictated with Apple Intelligence and swaps it in place; if you've typed since, the fixed version is copied instead. **Include computer audio**: tap it while dictating and what your Mac is playing (a video, a call) is transcribed along with you; a speaker shows on the island. Tap again to stop. Needs System Audio Recording permission the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Island") {
                Picker("Position", selection: $settings.placement) {
                    ForEach(IslandPlacement.allCases) { Text($0.title).tag($0) }
                }
                Picker(selection: $settings.cameraCutout) {
                    ForEach(CameraCutout.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Camera cutout")
                    Text("Pick **Camera hole** on a MacBook Pro with a hole-punch camera instead of a notch: the island rests as a pill around it, like the Dynamic Island.")
                }
                Toggle("Show resting pill when idle", isOn: $settings.showIdlePill)
                    .disabled(settings.placement.resolved != .menuBar)
                Text(placementNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AppRulesSection()

            Section("Output") {
                Toggle("Paste into the active app", isOn: $settings.autoPaste)
                Text("Text is always copied to the clipboard. Pasting needs Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("While dictating") {
                Toggle(isOn: $settings.liveEdits) {
                    Text("Show edits live")
                    Text("Experimental. Words the recognizer or the clean-up fixes flash green; words it drops are struck through in red.")
                }
                Picker("Sound cues", selection: $settings.soundSet) {
                    ForEach(SoundSet.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.soundSet) { _, set in SoundCues.audition(set) }
                LabeledContent("Cue volume") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.soundVolume, in: 0.05...1).frame(width: 150)
                        Button { SoundCues.audition(settings.soundSet) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless)
                            .help("Play")
                    }
                }
                .disabled(settings.soundSet == .off)
                Toggle("Muffle music and videos", isOn: $settings.muffleMedia)
                LabeledContent("Muffled volume") {
                    Slider(value: $settings.muffleLevel, in: 0.02...0.6)
                        .frame(width: 180)
                }
                .disabled(!settings.muffleMedia)
                MuffleStyleRow()
                    .disabled(!settings.muffleMedia)
            }

            Section {
                LaunchAtLoginToggle()
                Button("Run setup again…") { NotificationCenter.default.post(name: .runOnboarding, object: nil) }
            } footer: {
                Text(Self.versionText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return "DictationIsland \(version)" + (build.map { " (\($0))" } ?? "")
    }

    private var talkModeNote: String {
        switch settings.talkMode {
        case .holdOrTap: return "**Hold or tap**: hold to talk and release to finish, or tap once for hands-free and tap again to finish."
        case .hold: return "**Hold to talk**: it only listens while the key is held; a quick tap does nothing."
        case .toggle: return "**Press to start and stop**: press once and it keeps listening, however long you talk, until you press again."
        }
    }

    private var placementNote: String {
        if settings.placement.resolved == .belowMenuBar {
            return "The island floats just under the menu bar, clear of the notch."
        }
        if settings.placement.resolved == .bottom {
            return "The island floats just above the Dock and grows upward while you dictate."
        }
        return IslandPlacement.notchAppIsRunning
            ? "Alcove is running: the island grows out of Alcove's pill and covers it while you dictate."
            : "The island grows out of the notch, or a pill in the menu bar on displays without one."
    }

}

/// Login item via `SMAppService`; state lives with the system, not in our preferences.
/// Apps the dictation keys stay out of, so an app's own dictation can have them.
private struct AppRulesSection: View {
    @Bindable private var settings = AppSettings.shared
    @State private var apps: [AppRules.Listed] = []
    @State private var addable: [AppRules.Listed] = []

    var body: some View {
        Section {
            if apps.isEmpty {
                Text("Dictation works in every app.")
                    .foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                HStack(spacing: 10) {
                    Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        if app.hasOwnDictation {
                            Text("Has its own dictation").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("Dictation in \(app.name)", isOn: binding(for: app))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    if !app.hasOwnDictation {
                        Button {
                            settings.appRules[app.bundleID] = nil
                            refresh()
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            }
            Menu("Turn off in an app…") {
                ForEach(addable) { app in
                    Button {
                        add(app.bundleID)
                    } label: {
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                    }
                }
                if !addable.isEmpty { Divider() }
                Button("Choose an app…", action: choose)
            }
            .onAppear(perform: refresh)
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refresh() }
        } header: {
            Text("Apps")
        } footer: {
            Text("Where it's off, the push-to-talk keys do nothing and pass straight to the app, so its own voice input can use them. Apps with their own dictation, like Lark and Feishu, start off. A dictation already running still finishes with the key; Fix that and Annotate work everywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for app: AppRules.Listed) -> Binding<Bool> {
        Binding {
            AppRules.isOn(bundleID: app.bundleID, name: app.name)
        } set: { on in
            settings.appRules[app.bundleID] = on
        }
    }

    private func add(_ bundleID: String) {
        settings.appRules[bundleID] = false
        refresh()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Turn Off"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return }
        add(id)
    }

    private func refresh() {
        apps = AppRules.listed()
        addable = AppRules.addable(excluding: apps)
    }
}

private struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at login", isOn: Binding(get: { isEnabled }, set: set))
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            note = SMAppService.mainApp.status == .requiresApproval
                ? "Approve DictationIsland in System Settings → General → Login Items."
                : nil
        } catch {
            note = "Couldn't change: \(error.localizedDescription). Install the app in Applications first."
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Key recording

private struct KeyCap: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.tertiary, lineWidth: 0.5))
    }
}

/// "Add Key…" → captures the next modifier or fn press in this window. No permission needed:
/// it's a local event monitor, so it also shows whether a keyboard sends fn to the Mac at all.
private struct KeyRecorderRow: View {
    let onRecord: (TriggerKey) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var note: String?
    @State private var startedAt = Date()

    var body: some View {
        HStack(spacing: 10) {
            Button(isRecording ? "Cancel" : "Add Key…") {
                isRecording ? stop() : start()
            }
            if isRecording {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let waited = context.date.timeIntervalSince(startedAt)
                    Text(waited > 5
                         ? "Nothing yet. Some keyboards (e.g. Keychron fn) handle the key internally and never send it to the Mac."
                         : "Press a modifier key or fn…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        note = nil
        startedAt = Date()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 {  // esc
                    stop()
                } else {
                    note = "Only modifier keys or fn can be push-to-talk keys, since they don't type anything."
                    stop()
                }
                return nil
            }
            guard let key = TriggerKey(supportedKeyCode: Int64(event.keyCode)),
                  key.isDown(flags: UInt64(event.modifierFlags.rawValue)) else { return event }
            onRecord(key)
            note = "Added \(key.name)."
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

/// macOS also acts on a bare fn/🌐 press (switch input source, emoji picker, dictation),
/// which would fire alongside push-to-talk.
private struct GlobeKeyWarning: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let action = Self.currentAction
            if let action {
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your 🌐 fn key is set to “\(action)”, so tapping fn will also do that. Set “Press 🌐 key to” → Do Nothing.")
                            .font(.caption)
                        Button("Open Keyboard Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                        .controlSize(.small)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }

    /// `AppleFnUsageType`: 0 Do Nothing, 1 Change Input Source, 2 Show Emoji & Symbols, 3 Start Dictation.
    private static var currentAction: String? {
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int ?? 2
        switch value {
        case 1: return "Change Input Source"
        case 2: return "Show Emoji & Symbols"
        case 3: return "Start Dictation"
        default: return nil
        }
    }
}

// MARK: - Speech

struct SpeechSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Speech") {
                Picker("Engine", selection: $settings.speechEngine) {
                    ForEach(SpeechEngine.allCases) { Text($0.title).tag($0) }
                }
                Picker("Language", selection: $settings.localeIdentifier) {
                    Text("System (\(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier))")
                        .tag(String?.none)
                    ForEach(Self.locales, id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(Optional(locale.identifier))
                    }
                }
                SpeechModelStatusRow(engine: settings.speechEngine, locale: settings.locale)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("**Apple Speech** is Apple's newest on-device model (macOS 26), the one behind Notes and Voice Memos transcription. Most accurate for longer dictation.")
                    Text("**Apple Dictation** is the model behind macOS keyboard dictation. It covers more languages and is tuned for short phrases.")
                    Text("**Underdog Bark 3.0** is Parakeet V3 post-trained for English by Conway Research: as accurate in a much smaller model, and better on conversational speech. English only. One-time \(BarkModel.downloadSize.formatted(.byteCount(style: .file))) download.")
                    Text("**NVIDIA Parakeet V3** is the open model Handy and Noi recommend. 25 European languages, detected automatically, so the language setting doesn't apply. One-time \(ParakeetModel.downloadSize.formatted(.byteCount(style: .file))) download.")
                    Text("All of them run on-device and work offline once downloaded.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private static let locales: [Locale] = SFSpeechRecognizer.supportedLocales().sorted {
        (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
            < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
    }
}

/// Which engine the current choice resolves to, and whether its on-device model is installed.
private struct SpeechModelStatusRow: View {
    let engine: SpeechEngine
    let locale: Locale

    @State private var resolution: SpeechModelCatalog.Resolution?
    @State private var status: SpeechModelCatalog.ModelStatus?
    @State private var downloadProgress: Double?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
            Spacer()
            if let downloadProgress {
                ProgressView(value: downloadProgress)
                    .frame(width: 80)
            } else if status == .downloadable {
                Button("Download", action: download)
            }
        }
        .task(id: "\(engine.rawValue)-\(locale.identifier)") { await refresh() }
    }

    private var title: String {
        guard let resolution else { return "Checking…" }
        if resolution.engine == .bark { return "Bark 3.0 · English" }
        if resolution.engine == .parakeet { return "Parakeet V3 · 25 languages, auto-detected" }
        let language = Locale.current.localizedString(forIdentifier: resolution.locale.identifier) ?? resolution.locale.identifier
        return "\(resolution.engine.shortName) · \(language)"
    }

    private var detail: String {
        if let error { return error }
        guard let resolution, let status else { return " " }
        if resolution.engine == .legacy {
            return engine == .legacy
                ? "Older model. Needs Speech Recognition permission."
                : "Apple's newer models don't support this language; using the legacy recognizer."
        }
        switch status {
        case .installed: return "On-device model installed. Works offline."
        case .downloadable:
            if downloadProgress != nil { return "Downloading…" }
            switch resolution.engine {
            case .bark: return "Not downloaded yet (\(BarkModel.downloadSize.formatted(.byteCount(style: .file)))). It also downloads on first use."
            case .parakeet: return "Not downloaded yet (\(ParakeetModel.downloadSize.formatted(.byteCount(style: .file)))). It also downloads on first use."
            default: return "Model not downloaded yet. It also downloads on first use."
            }
        case .unsupported: return "Not supported on this Mac."
        }
    }

    private var icon: String {
        if error != nil { return "exclamationmark.triangle.fill" }
        switch status {
        case .installed: return "checkmark.seal.fill"
        case .downloadable: return "arrow.down.circle"
        default: return "circle.dashed"
        }
    }

    private var iconColor: Color {
        if error != nil { return .orange }
        return status == .installed ? .green : .secondary
    }

    private func refresh() async {
        error = nil
        let resolved = await SpeechModelCatalog.resolve(engine, locale: locale)
        resolution = resolved
        status = await SpeechModelCatalog.status(of: resolved)
    }

    private func download() {
        guard let resolution else { return }
        downloadProgress = 0
        error = nil
        Task {
            do {
                try await SpeechModelCatalog.install(resolution) { fraction in
                    Task { @MainActor in downloadProgress = fraction }
                }
            } catch {
                self.error = "Download failed: \(error.localizedDescription)"
            }
            downloadProgress = nil
            await refresh()
        }
    }
}

// MARK: - Writing

struct WritingSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var sample = "um so for the launch we need to finish the onboarding update the readme and uh tell the testers"
    @State private var preview: String?
    @State private var previewing = false

    private static let presets: [(String, String)] = [
        ("Casual", "Casual and friendly, like a text to a friend. Short sentences. Lowercase is fine."),
        ("Professional", "Clear and professional, for work email and docs. Complete sentences, no slang."),
        ("Concise", "As short as possible while keeping every point. No filler."),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Spoken formatting", isOn: $settings.spokenFormatting)
                Toggle("Laughing adds an emoji", isOn: $settings.laughEmoji)
            } header: {
                Text("Formatting")
            } footer: {
                Text("Say **“new line”**, **“new paragraph”** or **“bullet point”** while dictating. Bullets paste as a real list in Notes, Mail, Docs and Slack, and as • lines everywhere else. Laugh while you talk and a 😂 lands where you laughed (🤣 for a big one, 😄 for a chuckle), heard on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Tidy with Apple Intelligence", isOn: $settings.styleRewrite)
                Toggle("Adapt to the app you're in", isOn: $settings.adaptToApp)
                    .disabled(!settings.styleRewrite)
                    .disabled(StyleRewriter.availability != nil && !settings.styleRewrite)
                if let reason = StyleRewriter.availability {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
                TextEditor(text: $settings.styleInstructions)
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if settings.styleInstructions.isEmpty {
                            Text("Describe how you want to sound, e.g. “casual, short sentences, no exclamation marks”")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(!settings.styleRewrite)
                HStack(spacing: 6) {
                    ForEach(Self.presets, id: \.0) { preset in
                        Button(preset.0) { settings.styleInstructions = preset.1 }
                            .controlSize(.small)
                    }
                    Spacer()
                }
                .disabled(!settings.styleRewrite)
            } header: {
                Text("Writing style")
            } footer: {
                Text("Removes ums and false starts, fixes punctuation, turns spoken lists into bullets, and follows your description. Adapting keeps chat messages casual, emails in full sentences, and leaves terminals untouched. Runs on this Mac; nothing is sent anywhere. Adds about a second before pasting. Fix last dictation (\(settings.fixShortcut?.display ?? "set it in Shortcuts & Island")) works even with this off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                TextField("Sample", text: $sample, prompt: Text("Type something you might say"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...4)
                HStack {
                    Button(previewing ? "Working…" : "Preview") { runPreview() }
                        .disabled(previewing || sample.isEmpty)
                    Spacer()
                }
                if let preview {
                    Text(preview)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                }
            }

            Section {
                TextEditor(text: $settings.correctionsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 96)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if settings.correctionsText.isEmpty {
                            Text("get hub -> GitHub\nParakeet")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("Words")
            } footer: {
                Text("One per line. Write **heard -> written** to fix something that keeps coming out wrong; it matches whole words in any case. A word on its own line is a hint: Apple Speech and Apple Dictation listen for it, and the fixes apply to every engine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    private func runPreview() {
        previewing = true
        let text = sample
        Task {
            preview = await TextPipeline.process(text, settings: settings)
            previewing = false
        }
    }
}

// MARK: - Microphone

struct MicrophoneSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var devices: [AudioInputDevice] = []
    @State private var defaultDevice: AudioInputDevice?
    @State private var tester = MicrophoneTester()

    var body: some View {
        Form {
            Section("Input") {
                Picker("Microphone", selection: $settings.microphoneUID) {
                    Text("System default (\(defaultDevice?.name ?? "none"))").tag(String?.none)
                    ForEach(devices) { device in
                        Text("\(device.name)  ·  \(device.channelCount) ch\(device.isHidden ? "  ·  hidden by a driver" : "")")
                            .tag(Optional(device.uid))
                    }
                    if let uid = settings.microphoneUID, !devices.contains(where: { $0.uid == uid }) {
                        Text("Disconnected device").tag(Optional(uid))
                    }
                }
                Toggle("Use the built-in mic instead of Bluetooth headsets", isOn: $settings.avoidBluetoothMic)
                    .disabled(devices.contains { $0.uid == settings.microphoneUID })
                Picker("Channel", selection: $settings.inputChannel) {
                    ForEach(InputChannel.allCases) { Text($0.title).tag($0) }
                }
                .disabled(selectedChannelCount < 2)
                Text("On the system default (or when your chosen mic is unplugged), AirPods and other headsets are skipped for the built-in mic: using a headset's mic switches it to low-quality call audio. The headset is still used when the lid is closed. Stereo mics like the Blue Yeti have two channels; use “Mix” unless only one side carries your voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Test") {
                HStack(spacing: 12) {
                    Button(tester.isRunning ? "Stop Test" : "Test Microphone") {
                        tester.isRunning ? tester.stop() : tester.start(uid: settings.resolvedMicrophoneUID, channel: settings.inputChannel)
                    }
                    WaveformView(meter: tester.meter, source: tester.isRunning ? .live : .suspended, color: .accentColor, barWidth: 4, spacing: 3,
                                 isPaused: !tester.isRunning)
                        .frame(width: 60, height: 22)
                    if let error = tester.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    } else if tester.isRunning {
                        Text("Speak. The bars should move.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Refresh Devices", action: refresh)
                if devices.contains(where: \.isHidden) {
                    Label {
                        Text("Mics marked “hidden by a driver” are hidden from other apps by a leftover driver, such as Logitech G HUB's “Blue Voice” extension. DictationIsland can still use them. To make them visible everywhere again, turn that extension off in System Settings → General → Login Items & Extensions → Driver Extensions.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onDisappear { tester.stop() }
        .onChange(of: settings.microphoneUID) { tester.stop() }
        .onChange(of: settings.inputChannel) { tester.stop() }
    }

    private var selectedChannelCount: Int {
        if let uid = settings.microphoneUID { return devices.first { $0.uid == uid }?.channelCount ?? 1 }
        return defaultDevice?.channelCount ?? 1
    }

    private func refresh() {
        devices = AudioDevices.inputs()
        defaultDevice = AudioDevices.defaultInput()
    }
}

/// Runs the same capture path as dictation, levels only, so device/channel problems show up here.
@MainActor
@Observable
private final class MicrophoneTester {
    private(set) var isRunning = false
    private(set) var error: String?
    @ObservationIgnored let meter = LevelMeter(bandCount: 6)
    @ObservationIgnored private lazy var capture = AudioCapture(meter: meter)

    func start(uid: String?, channel: InputChannel) {
        error = nil
        Task {
            guard await AudioCapture.requestPermission() else {
                error = "Microphone access denied"
                return
            }
            do {
                try capture.start(deviceUID: uid, channel: channel) { _ in }
                isRunning = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        capture.stop()
        isRunning = false
    }
}

/// Which muffle style is in effect, and the button to unlock the DJ filter.
private struct MuffleStyleRow: View {
    var body: some View {
        // The grant happens in a system prompt or System Settings, so poll while visible.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let authorized = SystemAudioPermission.status == .authorized
            HStack(alignment: .firstTextBaseline) {
                Text(authorized
                     ? "DJ filter: the music sweeps underwater while you talk and opens back up after."
                     : "Lowering the volume. Allow System Audio Recording for the DJ filter sweep instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !authorized {
                    Button("Allow…") { Permission.systemAudio.request() }
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Permissions

struct PermissionsSettings: View {
    /// Grants are tied to the code signature: stable for the locally signed install, not for ad-hoc builds.
    static let signingNote: String = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32
        else { return "" }
        let isAdHoc = flags & 0x2 != 0  // kSecCodeSignatureAdhoc
        return isAdHoc
            ? "This build is ad-hoc signed, so macOS may ask again after each rebuild. Install with make install for a stable signature."
            : "If a permission shows as on in System Settings but not here, remove DictationIsland from that list with − and grant it again."
    }()

    var body: some View {
        // Grants happen in System Settings, so poll while the tab is visible.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Form {
                Section {
                    ForEach(Permission.visible) { permission in
                        PermissionRow(permission: permission)
                    }
                } footer: {
                    Text(Self.signingNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.isGranted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(permission.isGranted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                    if !permission.isRequired {
                        Text("Optional").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(permission.purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !permission.isGranted {
                Button("Grant…") { permission.request() }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - History

struct HistorySettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            if settings.history.isEmpty {
                ContentUnavailableView("No dictations yet", systemImage: "waveform", description: Text("Your last 100 dictations will show up here."))
            } else {
                List(settings.history) { record in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.text).textSelection(.enabled).lineLimit(4)
                            Text(record.date, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.text, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Spacer()
                    Button("Clear History", role: .destructive) { settings.clearHistory() }
                }
                .padding(10)
            }
        }
    }
}

// MARK: - Annotate

struct AnnotateSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Annotate the screen", isOn: $settings.annotateEnabled)
                LabeledContent("Shortcut") {
                    ShortcutRecorder(shortcut: $settings.annotateShortcut)
                }
                .disabled(!settings.annotateEnabled)
                Button("Show Annotations Folder") {
                    try? FileManager.default.createDirectory(at: AnnotationController.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AnnotationController.folder)
                }
                .disabled(!settings.annotateEnabled)
            } header: {
                Text("Annotate for AI agents")
            } footer: {
                Text("Tap the shortcut, talk through what's on screen and hold ⇧ to draw on it, then tap it again. You get screenshots of each moment, a timestamped transcript and the video, with a message ready to paste into Claude Code or another agent. Needs Screen Recording permission the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }
}
