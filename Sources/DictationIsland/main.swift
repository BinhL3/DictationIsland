import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandWindowController?
    private let settings = AppSettings.shared
    private let mainWindow = MainWindowController()
    private let onboarding = OnboardingWindowController()
    private var hotKey: HotKey?
    private var annotateListener: ShortcutListener?
    private var fixListener: ShortcutListener?
    private var computerAudioListener: ShortcutListener?
    private lazy var pushToTalk = ModifierKeyTrigger(keys: Set(settings.pushToTalkKeys))
    private var pushToTalkRetry: Timer?
    private var holdStartedSession = false
    private var statusItem: NSStatusItem?
    private var pressStartedAt: Date?
    private var startedOnThisPress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.preferredIslandScreen else { return }
        let island = IslandWindowController(screen: screen)
        self.island = island
        mainWindow.liveIsland = island.model
        if AppSettings.shared.speechEngine == .bark { BarkModels.preload() }
        if AppSettings.shared.speechEngine == .parakeet { ParakeetModels.preload() }
        if AppSettings.shared.styleRewrite { StyleRewriter.prewarm() }
        SoundCues.preload()

        let arguments = CommandLine.arguments
        let isDemo = arguments.contains("--demo") || arguments.contains("--state") || arguments.contains("--record")
        if let index = arguments.firstIndex(of: "--state"), index + 1 < arguments.count {
            island.model.pin(arguments[index + 1])
        } else if let index = arguments.firstIndex(of: "--record"), index + 1 < arguments.count {
            let text = arguments[index + 1]
            Task { await island.model.runRecording(text) }
        } else if arguments.contains("--demo") {
            Task { await island.model.runDemo() }
        }

        if arguments.contains("--annotate-test") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                await AnnotationController.shared.runSelfTest()
            }
        }
        if arguments.contains("--guide-preview") { PermissionGuide.shared.show(for: .accessibility) }
        installPushToTalk(model: island.model)
        updateHotKey(model: island.model)
        updateShortcutListeners(model: island.model)
        observeShortcutSettings(model: island.model)
        if !isDemo { observeAudioSettings(model: island.model) }
        installStatusItem()
        installMainMenu()
        if !isDemo { UpdateChecker.shared.start() }

        if arguments.contains("--onboarding") || (!isDemo && (!OnboardingModel.isComplete || Permission.requiredMissing)) {
            onboarding.show()
        } else if arguments.contains("--settings") || (!isDemo && !Self.launchedAtLogin && !arguments.contains("--background")) {
            // Opened by a person (Finder, Spotlight, Dock): show the window. At login, stay quiet.
            mainWindow.show()
        }
        NotificationCenter.default.addObserver(forName: .runOnboarding, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                OnboardingModel.reset()
                self?.onboarding.show()
            }
        }
    }

    /// Clicking the app (Finder, Spotlight, Dock) while it runs brings up its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboarding.isVisible { onboarding.show() } else { mainWindow.show() }
        return false
    }

    /// Closing the window doesn't quit: dictation keeps running from the menu bar and notch.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Launched by "Open at login" rather than by a person.
    private static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Shown while the window is open (the app is a regular app then). The Edit menu also makes
    /// ⌘C/⌘V/⌘A work in text fields like Words.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DictationIsland", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DictationIsland", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DictationIsland", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        // ⌘1…⌘8 jump between the sidebar's pages, in sidebar order.
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        let pages = MainWindowController.Section.groups.flatMap(\.sections)
        for (index, section) in pages.enumerated() where index < 9 {
            let item = NSMenuItem(title: section.title, action: #selector(showSection(_:)), keyEquivalent: "\(index + 1)")
            item.representedObject = section.rawValue
            item.target = self
            view.addItem(item)
        }
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    /// Primary trigger, per `TalkMode`: by default hold the push-to-talk key to talk and release to
    /// finish, or tap it alone to start hands-free mode and tap again to finish. Using it in a
    /// shortcut or to type a character is ignored.
    private func installPushToTalk(model: IslandModel) {
        // In an app that's off (see AppRules) the key belongs to the app, unless it's ending a
        // dictation that's already running.
        pushToTalk.ignoresPress = {
            MainActor.assumeIsolated { model.phase != .listening && !AppRules.isOnInFrontmostApp }
        }
        // The mic starts on key-down, hidden, so the first words aren't lost to the hold delay.
        pushToTalk.onPress = { MainActor.assumeIsolated { model.arm() } }
        pushToTalk.onKeyState = { key in MainActor.assumeIsolated { AppStatus.shared.heldKey = key } }
        pushToTalk.onUserInput = { MainActor.assumeIsolated { AppStatus.shared.inputRevision += 1 } }
        pushToTalk.onChordBeforeHold = { MainActor.assumeIsolated { model.disarm() } }
        pushToTalk.onTap = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.settings.talkMode == .hold {
                    // Hold only: a tap starts nothing, but still ends a session started another
                    // way (the menu, a click on the island).
                    if model.phase == .listening, !model.isArmed { model.stop() } else { model.disarm() }
                } else {
                    model.toggle()
                }
            }
        }
        pushToTalk.onHoldStart = { [weak self] in
            MainActor.assumeIsolated {
                self?.holdStartedSession = model.phase != .listening || model.isArmed
                model.start()
            }
        }
        pushToTalk.onHoldEnd = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let started = self.holdStartedSession
                self.holdStartedSession = false
                // Press to start and stop: letting go of the press that started it leaves it
                // running, and the next press finishes. Otherwise a release finishes (a hold
                // during a hands-free session too).
                if self.settings.talkMode == .toggle, started { return }
                model.stop()
            }
        }
        pushToTalk.onChordAfterHold = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.holdStartedSession else { return }
                self.holdStartedSession = false
                model.cancel()
            }
        }

        if pushToTalk.start() {
            AppStatus.shared.keyListenerRunning = true
            return
        }
        // Accessibility (or Input Monitoring) is granted out-of-process in System Settings; keep
        // trying until it lands.
        pushToTalkRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                if self?.pushToTalk.start() == true {
                    AppStatus.shared.keyListenerRunning = true
                    timer.invalidate()
                }
            }
        }
    }

    /// Keeps the next dictation's mic and speech model ready for the current settings.
    private func observeAudioSettings(model: IslandModel) {
        model.prepare()
        withObservationTracking {
            _ = settings.microphoneUID
            _ = settings.avoidBluetoothMic
            _ = settings.inputChannel
            _ = settings.speechEngine
            _ = settings.locale
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observeAudioSettings(model: model) }
            }
        }
    }

    private func observeShortcutSettings(model: IslandModel) {
        withObservationTracking {
            _ = settings.pushToTalkKeys
            _ = settings.fallbackShortcutEnabled
            _ = settings.annotateEnabled
            _ = settings.annotateShortcut
            _ = settings.fixShortcut
            _ = settings.computerAudioShortcut
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pushToTalk.keys = Set(self.settings.pushToTalkKeys)
                    self.updateHotKey(model: model)
                    self.updateShortcutListeners(model: model)
                    self.observeShortcutSettings(model: model)
                }
            }
        }
    }

    /// Optional backup shortcut that needs no permission. Hold to talk; release to finish.
    /// A quick tap latches hands-free mode instead, and the next tap finishes.
    private func updateHotKey(model: IslandModel) {
        guard settings.fallbackShortcutEnabled else {
            hotKey = nil
            return
        }
        guard hotKey == nil else { return }
        hotKey = HotKey()
        if hotKey == nil {
            NSLog("DictationIsland: \(HotKey.symbol) is taken by another app.")
        }
        hotKey?.onPress = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pressStartedAt = Date()
                self.startedOnThisPress = false
                if model.phase != .listening, !AppRules.isOnInFrontmostApp { return }
                if model.phase == .listening {
                    self.startedOnThisPress = false
                    model.stop()
                } else {
                    self.startedOnThisPress = true
                    model.start()
                }
            }
        }
        hotKey?.onRelease = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.startedOnThisPress, let started = self.pressStartedAt else { return }
                switch self.settings.talkMode {
                case .holdOrTap: if Date().timeIntervalSince(started) > 0.35 { model.stop() }
                case .hold: model.stop()
                case .toggle: break
                }
            }
        }
    }

    /// Annotate (tap to start, tap again to finish) and Fix that, on whatever shortcuts are set.
    private func updateShortcutListeners(model: IslandModel) {
        let annotate = settings.annotateEnabled ? settings.annotateShortcut : nil
        if annotateListener?.shortcut != annotate {
            annotateListener = nil  // release the old hot key before registering a new one
            annotateListener = annotate.flatMap { ShortcutListener($0, id: 2) { AnnotationController.shared.toggle() } }
            if annotate != nil, annotateListener == nil { NSLog("DictationIsland: the annotate shortcut is taken by another app.") }
        }
        let computer = settings.computerAudioShortcut
        if computerAudioListener?.shortcut != computer {
            computerAudioListener = nil
            computerAudioListener = computer.flatMap { ShortcutListener($0, id: 4) { model.toggleComputerAudio() } }
        }
        // Tapping it while holding the dictation key mustn't count as a shortcut chord.
        if case .modifier(let code)? = computer {
            pushToTalk.passThroughKeys = [TriggerKey(keyCode: code)]
        } else {
            pushToTalk.passThroughKeys = []
        }
        let fix = settings.fixShortcut
        if fixListener?.shortcut != fix {
            fixListener = nil
            fixListener = fix.flatMap { ShortcutListener($0, id: 3) { model.fixLast() } }
            if fix != nil, fixListener == nil { NSLog("DictationIsland: the Fix that shortcut is taken by another app.") }
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Dictation")
        let menu = NSMenu()
        menu.addItem(withTitle: "Start / Stop Dictation", action: #selector(toggleDictation), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Fix Last Dictation", action: #selector(fixLast), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Annotate Screen", action: #selector(toggleAnnotation), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open DictationIsland…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit DictationIsland", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleDictation() {
        island?.model.toggle()
    }

    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkInteractively()
    }

    @objc private func fixLast() {
        island?.model.fixLast()
    }

    @objc private func toggleAnnotation() {
        AnnotationController.shared.toggle()
    }

    @objc private func showSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let section = MainWindowController.Section(rawValue: raw) else { return }
        mainWindow.show(section)
    }

    @objc private func openSettings() {
        mainWindow.show()
    }
}

extension Notification.Name {
    static let runOnboarding = Notification.Name("DictationIsland.runOnboarding")
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
