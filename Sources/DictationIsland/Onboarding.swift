import AppKit
import SwiftUI

/// First run, after Hex's: Welcome → Setup → Try it → Done.
///
/// Setup is one card: the permissions dictation needs and the speech model, which starts
/// downloading as soon as the card appears. Rows go Allow → Waiting → ✓, and the card moves on by
/// itself a beat after the last one turns green. Try it is a real dictation into a text box. The
/// step is saved, so a restart macOS asks for picks up where it left off.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: String, CaseIterable {
        case welcome, setup, tryIt, done
    }

    enum ModelState: Equatable {
        case checking
        case ready
        case downloading(Double)
        case failed
    }

    var step: Step {
        didSet { UserDefaults.standard.set(step.rawValue, forKey: Keys.step) }
    }
    private(set) var micGranted = false
    private(set) var micDenied = false
    private(set) var accessibilityGranted = false
    /// Allow was clicked and we came back still untrusted: offer to reset the stale entry.
    private(set) var accessibilityStale = false
    /// Accessibility is on but the key listener still can't start: offer Input Monitoring / restart.
    private(set) var listenerBlocked = false
    private(set) var model: ModelState = .checking
    var practiceText = ""

    @ObservationIgnored private var askedAccessibilityAt: Date?
    @ObservationIgnored private var accessibilityGrantedAt: Date?
    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored let demo: IslandModel
    @ObservationIgnored private var demoTask: Task<Void, Never>?

    static var isComplete: Bool { UserDefaults.standard.bool(forKey: Keys.complete) }

    init() {
        step = UserDefaults.standard.string(forKey: Keys.step).flatMap(Step.init) ?? .welcome
        demo = IslandModel(geometry: NotchGeometry(
            style: .notch, closedSize: CGSize(width: 150, height: 30), topInset: 0, screenFrame: .zero
        ))
    }

    var setupReady: Bool { micGranted && accessibilityGranted && !listenerBlocked && model == .ready }

    func appear() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        stepChanged()
    }

    func disappear() {
        timer?.invalidate()
        timer = nil
        demoTask?.cancel()
        PermissionGuide.shared.close()
    }

    func go(to step: Step) {
        withAnimation(Motion.content) { self.step = step }
        stepChanged()
    }

    private func stepChanged() {
        demoTask?.cancel()
        if step == .welcome || step == .done {
            let demo = demo
            demoTask = Task { await demo.runDemo() }
        }
        if step == .setup { startModelIfNeeded() }
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Keys.complete)
        UserDefaults.standard.removeObject(forKey: Keys.step)
    }

    static func reset() {
        UserDefaults.standard.set(false, forKey: Keys.complete)
        UserDefaults.standard.removeObject(forKey: Keys.step)
    }

    // MARK: Actions

    func allowMicrophone() {
        Permission.microphone.request()
    }

    func allowAccessibility() {
        askedAccessibilityAt = Date()
        accessibilityStale = false
        Permission.accessibility.request()
    }

    /// The switch looks on in System Settings but macOS doesn't honour it, usually because it
    /// belongs to an older build. Clear it and ask again.
    func resetAccessibility() {
        Permission.accessibility.resetEntry()
        allowAccessibility()
    }

    func allowInputMonitoring() {
        Permission.inputMonitoring.request()
    }

    /// Quits and reopens the app; the saved step brings the person back here.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--onboarding"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func retryModel() {
        model = .checking
        modelTask = nil
        startModelIfNeeded()
    }

    // MARK: State

    /// `--setup-preview`: shows the setup card as a fresh install sees it, for screenshots.
    @ObservationIgnored private let previewsSetup = CommandLine.arguments.contains("--setup-preview")

    private func refresh() {
        if previewsSetup {
            micGranted = true
            accessibilityGranted = false
            accessibilityStale = CommandLine.arguments.contains("--stale")
            model = .downloading(0.42)
            return
        }
        micGranted = Permission.microphone.isGranted
        micDenied = Permission.microphone.isDenied
        let trusted = Permission.accessibility.isGranted
        if trusted, !accessibilityGranted { accessibilityGrantedAt = Date() }
        accessibilityGranted = trusted
        if trusted {
            accessibilityStale = false
            askedAccessibilityAt = nil
        } else if let asked = askedAccessibilityAt, Date().timeIntervalSince(asked) > 6, NSApp.isActive {
            // Back in our window a while after asking, and still not trusted.
            accessibilityStale = true
        }
        // The tap retries every 2 s; give it a moment after Accessibility lands.
        listenerBlocked = trusted && !AppStatus.shared.keyListenerRunning
            && Date().timeIntervalSince(accessibilityGrantedAt ?? .distantPast) > 4

        if step == .setup, setupReady, advanceTask == nil {
            advanceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, self.step == .setup, self.setupReady else { self?.advanceTask = nil; return }
                self.advanceTask = nil
                self.go(to: .tryIt)
            }
        }
    }

    private func startModelIfNeeded() {
        guard modelTask == nil, !previewsSetup else { return }
        let settings = AppSettings.shared
        modelTask = Task { [weak self] in
            let resolution = await SpeechModelCatalog.resolve(settings.speechEngine, locale: settings.locale)
            let status = await SpeechModelCatalog.status(of: resolution)
            guard let self else { return }
            if status != .downloadable {
                self.model = .ready
                return
            }
            self.model = .downloading(0)
            do {
                try await SpeechModelCatalog.install(resolution) { fraction in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.model { self?.model = .downloading(fraction) }
                    }
                }
                self.model = .ready
            } catch {
                self.model = .failed
                self.modelTask = nil
            }
        }
    }

    private enum Keys {
        static let step = "onboardingStep"
        static let complete = "onboardingComplete"
    }
}

// MARK: - Window

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: OnboardingModel?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let model = OnboardingModel()
            self.model = model
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 560, height: 600),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.contentViewController = NSHostingController(rootView: OnboardingView(model: model) { [weak self] in
                self?.close()
            })
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            window.center()
            window.delegate = self
            self.window = window
        }
        AppPresence.windowOpened()
        window?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in AppPresence.windowClosed() }
    }

    func close() {
        model?.finish()
        window?.close()
        window = nil
        model = nil
    }
}

// MARK: - Views

private struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: WelcomePage(model: model)
                case .setup: SetupPage(model: model)
                case .tryIt: TryItPage(model: model)
                case .done: DonePage(model: model, onFinish: onFinish)
                }
            }
            .transition(.blurFade)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StepDots(step: model.step).padding(.bottom, 22)
        }
        .frame(width: 560, height: 600)
        .background(.black)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }
}

private struct StepDots: View {
    let step: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(.white.opacity(item == step ? 0.9 : 0.2))
                    .frame(width: item == step ? 18 : 6, height: 6)
            }
        }
        .animation(Motion.content, value: step)
    }
}

/// The real island, running its demo, under a strip of fake menu bar.
private struct IslandHero: View {
    let model: IslandModel

    var body: some View {
        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 30) }
            // An overlay doesn't size its parent, so the island's wide canvas can't widen the page.
            .overlay(alignment: .top) {
                IslandView(model: model)
                    .frame(width: NotchGeometry.canvasSize.width, height: 132)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

private struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 220, height: 40)
                .background(Capsule().fill(.white.opacity(enabled ? 1 : 0.3)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }
}

private struct Headline: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
        }
    }
}

private struct WelcomePage: View {
    let model: OnboardingModel

    var body: some View {
        VStack(spacing: 28) {
            IslandHero(model: model.demo).padding(.horizontal, 28).padding(.top, 44)
            Headline(
                title: "Talk. It types.",
                subtitle: "Hold a key and speak. Your words show up in the notch as you go, and land wherever you're typing when you let go."
            )
            HStack(spacing: 12) {
                Feature(icon: "lock.fill", title: "On-device", detail: "Nothing leaves your Mac")
                Feature(icon: "text.cursor", title: "Any app", detail: "Pastes where you type")
                Feature(icon: "bolt.fill", title: "Instant", detail: "Words as you speak")
            }
            .padding(.horizontal, 36)
            Spacer()
            PrimaryButton(title: "Get started") { model.go(to: .setup) }
        }
        .padding(.bottom, 18)
    }
}

private struct Feature: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
    }
}

private struct SetupPage: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 26) {
            Headline(title: "Setting up", subtitle: "Two permissions and a speech model. The model downloads while you allow these.")
                .padding(.top, 60)
            VStack(spacing: 0) {
                SetupRow(
                    icon: "mic.fill", title: "Microphone", detail: "To hear you while you hold the key.",
                    state: model.micGranted ? .done : .todo(model.micDenied ? "Open Settings" : "Allow"),
                    action: model.allowMicrophone
                )
                Divider().overlay(.white.opacity(0.06))
                SetupRow(
                    icon: "keyboard", title: "Accessibility", detail: "To notice your dictation key and paste the text.",
                    state: model.accessibilityGranted ? .done : .todo(model.accessibilityStale ? "Try again" : "Allow"),
                    action: model.accessibilityStale ? model.resetAccessibility : model.allowAccessibility
                )
                if model.accessibilityStale {
                    Note(text: "Still off? An old entry from a previous version can block it. “Try again” clears it, then drag DictationIsland back in.")
                }
                if model.listenerBlocked {
                    Divider().overlay(.white.opacity(0.06))
                    SetupRow(
                        icon: "keyboard.badge.ellipsis", title: "Input Monitoring",
                        detail: "This Mac also wants this for the dictation key.",
                        state: Permission.inputMonitoring.isGranted ? .todo("Restart") : .todo("Allow"),
                        action: Permission.inputMonitoring.isGranted ? model.relaunch : model.allowInputMonitoring
                    )
                }
                Divider().overlay(.white.opacity(0.06))
                SetupRow(
                    icon: "waveform", title: "Speech model", detail: modelDetail,
                    state: modelState, action: model.retryModel
                )
            }
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.07)))
            .padding(.horizontal, 36)
            Spacer()
            PrimaryButton(title: "Continue", enabled: model.setupReady) { model.go(to: .tryIt) }
        }
        .padding(.bottom, 18)
        .animation(Motion.content, value: model.accessibilityStale)
        .animation(Motion.content, value: model.listenerBlocked)
    }

    private var modelDetail: String {
        switch model.model {
        case .checking: return "Checking what's installed…"
        case .ready: return "Installed. Works offline."
        case .downloading(let fraction): return "Downloading · \(Int(fraction * 100))%"
        case .failed: return "The download didn't finish."
        }
    }

    private var modelState: SetupRow.State {
        switch model.model {
        case .ready: return .done
        case .failed: return .todo("Retry")
        case .checking: return .working(nil)
        case .downloading(let fraction): return .working(fraction)
        }
    }
}

private struct SetupRow: View {
    enum State: Equatable {
        case todo(String)
        case working(Double?)
        case done
    }

    let icon: String
    let title: String
    let detail: String
    let state: State
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            switch state {
            case .done:
                Label("Allowed", systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.green))
                    .transition(.scale.combined(with: .opacity))
            case .working(let fraction):
                if let fraction {
                    ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .todo(let label):
                Button(action: action) {
                    Text(label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Capsule().fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .animation(Motion.content, value: state)
    }
}

private struct Note: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 64)
            .padding(.bottom, 10)
    }
}

private struct TryItPage: View {
    @Bindable var model: OnboardingModel
    @FocusState private var focused: Bool

    private var key: String { AppSettings.shared.suggestedKey?.name ?? "your dictation key" }
    private var succeeded: Bool { !model.practiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 26) {
            Headline(
                title: succeeded ? "That's it." : "Try it",
                subtitle: succeeded
                    ? "Hold to talk, let go to paste. It works in any app."
                    : "Hold \(key), say something, and let go. Watch the notch while you talk."
            )
            .padding(.top, 60)
            HStack(spacing: 10) {
                KeyCapLarge(name: key)
                Text("hold").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.practiceText)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(12)
                if !succeeded {
                    Text("Your words will appear here")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.25))
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(succeeded ? 0.25 : 0.08)))
            .padding(.horizontal, 36)
            Spacer()
            VStack(spacing: 10) {
                PrimaryButton(title: "Continue", enabled: succeeded) { model.go(to: .done) }
                Button("Skip for now") { model.go(to: .done) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.bottom, 10)
        .animation(Motion.content, value: succeeded)
        .onAppear { focused = true }
    }
}

private struct KeyCapLarge: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .padding(.horizontal, 16)
            .frame(minWidth: 52, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.5), radius: 0, y: 2)
    }
}

private struct DonePage: View {
    let model: OnboardingModel
    let onFinish: () -> Void

    private var key: String { AppSettings.shared.pushToTalkDescription ?? "your dictation key" }

    var body: some View {
        VStack(spacing: 26) {
            IslandHero(model: model.demo).padding(.horizontal, 28).padding(.top, 44)
            Headline(title: "You're ready", subtitle: "A few things worth knowing.")
            VStack(alignment: .leading, spacing: 12) {
                Tip(icon: "hand.tap", text: "Hold \(key) to talk. Tap it once for hands-free, tap again to finish.")
                Tip(icon: "text.badge.checkmark", text: "Teach it names and fixes in Settings → Writing. Say “bullet point” for lists.")
                Tip(icon: "waveform", text: "Settings live in the menu bar 〰 icon.")
            }
            .frame(maxWidth: 400, alignment: .leading)
            Spacer()
            PrimaryButton(title: "Start dictating", action: onFinish)
        }
        .padding(.bottom, 18)
    }
}

private struct Tip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.white.opacity(0.7))
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
        }
    }
}
