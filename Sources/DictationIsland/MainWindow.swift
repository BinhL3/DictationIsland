import AppKit
import SwiftUI

/// The app's window: Home plus every setting in a sidebar. Clicking the app opens it, with a
/// Dock icon; closing it sends the app back to living in the menu bar and the notch.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    enum Section: String, CaseIterable, Identifiable {
        case home, shortcuts, speech, writing, microphone, annotate, history, permissions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "Home"
            case .shortcuts: return "Shortcuts & Island"
            case .speech: return "Speech"
            case .writing: return "Writing"
            case .microphone: return "Microphone"
            case .annotate: return "Annotate"
            case .history: return "History"
            case .permissions: return "Permissions"
            }
        }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .shortcuts: return "keyboard.fill"
            case .speech: return "waveform"
            case .writing: return "text.quote"
            case .microphone: return "mic.fill"
            case .annotate: return "pencil.tip"
            case .history: return "clock.fill"
            case .permissions: return "hand.raised.fill"
            }
        }

        /// Tile colour, System Settings style: each page gets its own.
        var tint: Color {
            switch self {
            case .home: return Color(red: 0.20, green: 0.48, blue: 0.98)
            case .shortcuts: return Color(white: 0.45)
            case .speech: return Color(red: 0.58, green: 0.36, blue: 0.95)
            case .writing: return Color(red: 0.98, green: 0.58, blue: 0.16)
            case .microphone: return Color(red: 0.96, green: 0.27, blue: 0.33)
            case .annotate: return Color(red: 0.94, green: 0.30, blue: 0.62)
            case .history: return Color(red: 0.18, green: 0.72, blue: 0.62)
            case .permissions: return Color(red: 0.16, green: 0.52, blue: 0.96)
            }
        }

        /// Sidebar groups, with a small heading over each (none over Home).
        static let groups: [(title: String?, sections: [Section])] = [
            (nil, [.home]),
            ("Dictation", [.shortcuts, .speech, .writing, .microphone]),
            ("Tools", [.annotate]),
            ("App", [.history, .permissions]),
        ]
    }

    private var window: NSWindow?
    private let navigation = MainNavigation()
    /// Watches ⌘ while the window is in front, to show the ⌘1…⌘8 hints in the sidebar.
    private var commandMonitor: Any?
    /// The real island, so Home can play it in place of the notch.
    var liveIsland: IslandModel?

    func show(_ section: Section? = nil) {
        if let section { navigation.section = section }
        if window == nil {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 880, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            let host = NSHostingController(rootView: MainView(navigation: navigation, liveIsland: liveIsland))
            // Don't let SwiftUI's ideal size shrink the window to fit.
            host.sizingOptions = []
            window.contentViewController = host
            window.setContentSize(CGSize(width: 880, height: 620))
            window.title = "DictationIsland"
            window.titlebarAppearsTransparent = true
            // Each page draws its own icon + title header, like System Settings.
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.minSize = CGSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.setFrameAutosaveName("MainWindow")
            if !window.setFrameUsingName("MainWindow") { window.center() }
            window.delegate = self
            self.window = window
            trackTitle()
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateInAppPreview()
                        // A ⌘ released in another app never reaches us.
                        self?.navigation.showsShortcutHints = false
                    }
                }
            }
            // Only ⌘ on its own: ⌘ with ⇧, ⌥ or ⌃ is some other shortcut.
            commandMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return }
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
                    let shows = flags == .command
                    if self.navigation.showsShortcutHints != shows {
                        withAnimation(.easeOut(duration: 0.15)) { self.navigation.showsShortcutHints = shows }
                    }
                }
                return event
            }
        }
        AppPresence.windowOpened()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Home in the key window plays the live island itself; anywhere else, the notch does.
    private func updateInAppPreview() {
        let shown = window?.isKeyWindow == true && window?.isVisible == true && navigation.section == .home && liveIsland != nil
        if AppStatus.shared.islandShownInApp != shown { AppStatus.shared.islandShownInApp = shown }
    }

    /// The window title follows the sidebar.
    private func trackTitle() {
        updateInAppPreview()
        window?.title = navigation.section == .home ? "DictationIsland" : navigation.section.title
        withObservationTracking { _ = navigation.section } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackTitle() } }
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            AppStatus.shared.islandShownInApp = false
            AppPresence.windowClosed()
        }
    }
}

/// A Dock icon (and a menu bar) only while one of the app's windows is open.
@MainActor
enum AppPresence {
    static func windowOpened() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func windowClosed() {
        // The closing window is still listed for a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let anyOpen = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
            if !anyOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

extension Notification.Name {
    static let showShortcuts = Notification.Name("DictationIsland.showShortcuts")
}

@MainActor
@Observable
final class MainNavigation {
    var section: MainWindowController.Section {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: "mainSection") }
    }
    /// ⌘ is held: the sidebar shows each page's ⌘-number.
    var showsShortcutHints = false

    init() {
        section = UserDefaults.standard.string(forKey: "mainSection").flatMap(MainWindowController.Section.init) ?? .home
        NotificationCenter.default.addObserver(forName: .showShortcuts, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.section = .shortcuts }
        }
    }
}

private struct MainView: View {
    @Bindable var navigation: MainNavigation
    let liveIsland: IslandModel?

    /// Matches the View menu: pages in sidebar order get ⌘1…⌘9.
    static func shortcutNumber(_ section: MainWindowController.Section) -> Int? {
        let pages = MainWindowController.Section.groups.flatMap(\.sections)
        return pages.firstIndex(of: section).map { $0 + 1 }.flatMap { $0 <= 9 ? $0 : nil }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { navigation.section },
                set: { if let new = $0 { navigation.section = new } }
            )) {
                ForEach(MainWindowController.Section.groups, id: \.sections) { group in
                    Section {
                        ForEach(group.sections) { section in
                            HStack(spacing: 10) {
                                IconTile(section: section, size: 24)
                                Text(section.title).font(.system(size: 13.5))
                                Spacer(minLength: 4)
                                if navigation.showsShortcutHints, let number = Self.shortcutNumber(section) {
                                    Text("⌘\(number)")
                                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .transition(.opacity)
                                }
                            }
                            .padding(.vertical, 2)
                            .tag(section)
                        }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 250)
        } detail: {
            Group {
                switch navigation.section {
                case .home: HomeView(navigation: navigation, liveIsland: liveIsland)
                default:
                    VStack(spacing: 0) {
                        PageHeader(section: navigation.section)
                        switch navigation.section {
                        case .shortcuts: GeneralSettings()
                        case .speech: SpeechSettings()
                        case .writing: WritingSettings()
                        case .microphone: MicrophoneSettings()
                        case .annotate: AnnotateSettings()
                        case .history: HistorySettings()
                        default: PermissionsSettings()
                        }
                    }
                }
            }
            // Settings forms sit on the same island black as Home.
            .scrollContentBackground(.hidden)
            .background(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .focusEffectDisabled()
        .frame(minWidth: 760, minHeight: 520)
        .environment(\.colorScheme, .dark)
    }
}

/// A rounded colour tile with a white symbol, like System Settings' sidebar.
private struct IconTile: View {
    let section: MainWindowController.Section
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [section.tint.opacity(0.92), section.tint], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .overlay(
                Image(systemName: section.icon)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }
}

/// The page's tile and name above its settings.
private struct PageHeader: View {
    let section: MainWindowController.Section

    var body: some View {
        HStack(spacing: 10) {
            IconTile(section: section, size: 28)
            Text(section.title).font(.system(size: 20, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 2)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Home

private struct HomeView: View {
    let navigation: MainNavigation
    let liveIsland: IslandModel?
    @Bindable private var settings = AppSettings.shared
    @State private var island = IslandModel(geometry: NotchGeometry(
        style: .notch, closedSize: CGSize(width: 150, height: 30), topInset: 0, screenFrame: .zero
    ))
    @State private var demoTask: Task<Void, Never>?

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var keyHint: String {
        settings.pushToTalkDescription.map { settings.talkMode.howTo($0) } ?? "Add a push-to-talk key in Shortcuts & Island."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let release = UpdateChecker.shared.available { UpdateBanner(release: release) }
                hero
                TryItCard()
                stats
                recent
                shortcutsRow
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.black)
        .onAppear {
            let island = island
            demoTask = Task { await island.runDemo() }
        }
        .onDisappear { demoTask?.cancel() }
    }

    /// The real island while a dictation is under way, otherwise the demo.
    private var shownIsland: IslandModel {
        if let liveIsland, liveIsland.phase != .idle { return liveIsland }
        return island
    }

    private var placement: Binding<IslandPlacement> {
        Binding(
            get: { settings.placement.resolved == .menuBar ? .automatic : settings.placement.resolved },
            set: { settings.placement = $0 }
        )
    }

    /// Copies the real island's size and position onto the demo.
    private func syncDemo() {
        guard let liveIsland else { return }
        // The preview moves itself when dragged; anything else (opening Home, a change made in
        // Settings) just puts the island in place, without flying it there.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { island.updateGeometry(liveIsland.geometry) }
        if island.showsIdleIsland != liveIsland.showsIdleIsland {
            withAnimation(Motion.content) { island.showsIdleIsland = liveIsland.showsIdleIsland }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            // While Home is in front this *is* the island: dictations play here, not in the notch.
            PlacementScreen(island: shownIsland, isDemo: shownIsland !== liveIsland, placement: placement)
                .onAppear(perform: syncDemo)
                .onChange(of: liveIsland?.geometry) { _, _ in syncDemo() }
                .onChange(of: liveIsland?.showsIdleIsland) { _, _ in syncDemo() }
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting).font(.system(size: 28, weight: .bold))
                HStack(spacing: 7) {
                    Circle().fill(Permission.requiredMissing ? .orange : .green).frame(width: 7, height: 7)
                    Text(Permission.requiredMissing ? "A permission is missing. Open Permissions to fix it." : keyHint)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 12) {
            StatTile(value: settings.stats.words.formatted(), label: "words dictated")
            StatTile(value: settings.stats.dictations.formatted(), label: "dictations")
            StatTile(value: Self.duration(minutes: settings.stats.minutesSaved), label: "saved vs typing")
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent").font(.system(size: 15, weight: .semibold))
                Spacer()
                if !settings.history.isEmpty {
                    Button("See all") { navigation.section = .history }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            if settings.history.isEmpty {
                Text("Your dictations will show up here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.04)))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(settings.history.prefix(5).enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider().overlay(.white.opacity(0.05)) }
                        RecentRow(record: record)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.06)))
            }
        }
    }

    private var shortcutsRow: some View {
        HStack(spacing: 12) {
            QuickCard(
                icon: "text.badge.checkmark", title: "Writing style",
                detail: settings.styleRewrite ? "Tidying with Apple Intelligence" : "Off · say “bullet point” for lists"
            ) { navigation.section = .writing }
            QuickCard(
                icon: "pencil.tip.crop.circle", title: "Annotate",
                detail: settings.annotateEnabled ? "\(settings.annotateShortcut?.display ?? "Menu bar") to record your screen for an agent" : "Off"
            ) { navigation.section = .annotate }
        }
    }

    private static func duration(minutes: Double) -> String {
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(Int(minutes.rounded())) min" }
        return String(format: "%.1f h", minutes / 60)
    }
}

/// Try the real thing without leaving the app: the keys light up while held, and the dictation
/// pastes into the box below, exactly as it would anywhere else.
private struct TryItCard: View {
    @Bindable private var settings = AppSettings.shared
    private let status = AppStatus.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    private var tryItHint: String {
        switch settings.talkMode {
        case .holdOrTap: return "Hold to talk, let go and it lands here. Tap once for hands-free, tap again to finish."
        case .hold: return "Hold to talk, let go and it lands here."
        case .toggle: return "Press once to start, press again and it lands here."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Try it").font(.system(size: 15, weight: .semibold))
                Spacer()
                ForEach(settings.pushToTalkKeys) { key in
                    HomeKeyCap(name: key.name, held: status.heldKey == key)
                }
                if settings.pushToTalkKeys.isEmpty {
                    Text("No push-to-talk key yet").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                }
                Button("Change") { NotificationCenter.default.post(name: .showShortcuts, object: nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(10)
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(status.heldKey != nil ? Color.white.opacity(0.35) : Color.white.opacity(0.07))
            )
            HStack {
                Text(tryItHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                if !text.isEmpty {
                    Button("Clear") { text = "" }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .animation(.easeOut(duration: 0.12), value: status.heldKey)
        // Pressing the key while the window is in front aims the paste at this box.
        .onChange(of: status.heldKey) { _, key in if key != nil { focused = true } }
    }

    private var placeholder: String {
        settings.suggestedKey.map { "Hold \($0.name) and say something…" } ?? "Add a key in Shortcuts & Island first."
    }
}

private struct HomeKeyCap: View {
    let name: String
    let held: Bool

    var body: some View {
        Text(name)
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(held ? .black : .white)
            .padding(.horizontal, 10)
            .frame(minWidth: 38, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(held ? Color.white : Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(held ? 0 : 0.16)))
            .shadow(color: .black.opacity(held ? 0 : 0.5), radius: 0, y: held ? 0 : 2)
            .offset(y: held ? 2 : 0)
            .scaleEffect(held ? 0.96 : 1)
    }
}

private struct UpdateBanner: View {
    let release: UpdateChecker.Release
    private var updater: UpdateChecker { .shared }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 20)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("DictationIsland \(release.version) is available").font(.system(size: 13.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            Button("What's new") { NSWorkspace.shared.open(release.page) }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.7))
            Button {
                if case .failed = updater.installState {
                    updater.download()
                } else {
                    Task { await updater.update() }
                }
            } label: {
                Text(buttonTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 84)
                    .frame(height: 28)
                    .background(Capsule().fill(.white.opacity(isBusy ? 0.7 : 1)))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .animation(Motion.content, value: updater.installState)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5)))
    }

    private var isBusy: Bool {
        switch updater.installState {
        case .downloading, .installing: return true
        case .idle, .failed: return false
        }
    }

    private var buttonTitle: String {
        switch updater.installState {
        case .idle: return updater.installsInPlace ? "Update" : "Download"
        case .downloading(let fraction): return "\(Int(fraction * 100))%"
        case .installing: return "Installing…"
        case .failed: return "Download"
        }
    }

    private var detail: String {
        switch updater.installState {
        case .failed(let reason): return "\(reason) Download it and drag it into Applications instead."
        case .downloading, .installing: return "DictationIsland reopens when it's done."
        case .idle:
            return updater.installsInPlace
                ? "You have \(UpdateChecker.currentVersion). One click, and settings and permissions carry over."
                : "You have \(UpdateChecker.currentVersion). Drag the new one into Applications; settings and permissions carry over."
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}

private struct RecentRow: View {
    let record: DictationRecord
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(record.text)
                .font(.system(size: 13.5))
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(record.date, format: .relative(presentation: .named))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.4))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))
            .help("Copy")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct QuickCard: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.3))
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
