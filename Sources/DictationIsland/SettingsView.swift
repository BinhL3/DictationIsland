import AppKit
import ServiceManagement
import Speech
import SwiftUI

struct SettingsView: View {
    /// Reopens on the tab you last used.
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            SpeechSettings()
                .tabItem { Label("Speech", systemImage: "waveform") }
                .tag("speech")
            MicrophoneSettings()
                .tabItem { Label("Microphone", systemImage: "mic") }
                .tag("microphone")
            PermissionsSettings()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag("permissions")
            HistorySettings()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag("history")
        }
        .frame(width: 520, height: 520)
    }
}

// MARK: - General

private struct GeneralSettings: View {
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
                }
                if settings.pushToTalkKeys.contains(.fn) {
                    GlobeKeyWarning()
                }
                Toggle("Also use \(HotKey.symbol)", isOn: $settings.fallbackShortcutEnabled)
            } header: {
                Text("Push-to-talk keys")
            } footer: {
                Text("Any listed key works: hold to talk and release to finish, or tap once for hands-free and tap again to finish. Add fn for an external keyboard and right ⌥ for the laptop to use both setups without switching. \(HotKey.symbol) needs no permission; plain ⌥Space is left alone for Raycast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Island") {
                Picker("Position", selection: $settings.placement) {
                    ForEach(IslandPlacement.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show resting pill when idle", isOn: $settings.showIdlePill)
                    .disabled(settings.placement.resolved != .menuBar)
                Text(placementNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                Toggle("Paste into the active app", isOn: $settings.autoPaste)
                Text("Text is always copied to the clipboard. Pasting needs Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("While dictating") {
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

    private var placementNote: String {
        if settings.placement.resolved == .belowMenuBar {
            return "The island floats just under the menu bar, clear of the notch."
        }
        return IslandPlacement.notchAppIsRunning
            ? "Alcove is running: the island grows out of Alcove's pill and covers it while you dictate."
            : "The island grows out of the notch, or a pill in the menu bar on displays without one."
    }

}

/// Login item via `SMAppService`; state lives with the system, not in our preferences.
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

private struct SpeechSettings: View {
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
            return resolution.engine == .parakeet
                ? "Not downloaded yet (\(ParakeetModel.downloadSize.formatted(.byteCount(style: .file)))). It also downloads on first use."
                : "Model not downloaded yet. It also downloads on first use."
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

// MARK: - Microphone

private struct MicrophoneSettings: View {
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
                Picker("Channel", selection: $settings.inputChannel) {
                    ForEach(InputChannel.allCases) { Text($0.title).tag($0) }
                }
                .disabled(selectedChannelCount < 2)
                Text("Stereo mics like the Blue Yeti have two channels. Use “Mix” unless only one side carries your voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Test") {
                HStack(spacing: 12) {
                    Button(tester.isRunning ? "Stop Test" : "Test Microphone") {
                        tester.isRunning ? tester.stop() : tester.start(uid: settings.microphoneUID, channel: settings.inputChannel)
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

private struct PermissionsSettings: View {
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
                    ForEach(Permission.allCases) { permission in
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

private struct HistorySettings: View {
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

// MARK: - Window

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "DictationIsland Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
