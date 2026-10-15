import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandWindowController?
    private let settings = AppSettings.shared
    private let settingsWindow = SettingsWindowController()
    private var hotKey: HotKey?
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
        if AppSettings.shared.speechEngine == .parakeet { ParakeetModels.preload() }

        let arguments = CommandLine.arguments
        let isDemo = arguments.contains("--demo") || arguments.contains("--state")
        if let index = arguments.firstIndex(of: "--state"), index + 1 < arguments.count {
            island.model.pin(arguments[index + 1])
        } else if arguments.contains("--demo") {
            Task { await island.model.runDemo() }
        }

        installPushToTalk(model: island.model)
        updateHotKey(model: island.model)
        observeShortcutSettings(model: island.model)
        if !isDemo { observeAudioSettings(model: island.model) }
        installStatusItem()

        if arguments.contains("--settings") || (!isDemo && Permission.allCases.contains { $0.isRequired && !$0.isGranted }) {
            settingsWindow.show()
        }
    }

    /// Opening the app again from Finder/Spotlight shows Settings, since there's no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    /// Primary trigger. Hold the push-to-talk key to talk and release to finish; tap it alone to
    /// start hands-free mode, tap again to finish. Using it in a shortcut or to type a character is ignored.
    private func installPushToTalk(model: IslandModel) {
        pushToTalk.onTap = { model.toggle() }
        pushToTalk.onHoldStart = { [weak self] in
            MainActor.assumeIsolated {
                self?.holdStartedSession = model.phase != .listening
                model.start()
            }
        }
        pushToTalk.onHoldEnd = { [weak self] in
            MainActor.assumeIsolated {
                // A hold during a hands-free session finishes it too.
                self?.holdStartedSession = false
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

        if pushToTalk.start() { return }
        // Input Monitoring is granted out-of-process in System Settings; keep trying until it lands.
        pushToTalkRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                if self?.pushToTalk.start() == true { timer.invalidate() }
            }
        }
    }

    /// Keeps the next dictation's mic and speech model ready for the current settings.
    private func observeAudioSettings(model: IslandModel) {
        model.prepare()
        withObservationTracking {
            _ = settings.microphoneUID
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
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pushToTalk.keys = Set(self.settings.pushToTalkKeys)
                    self.updateHotKey(model: model)
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
                if Date().timeIntervalSince(started) > 0.35 { model.stop() }
            }
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Dictation")
        let menu = NSMenu()
        menu.addItem(withTitle: "Start / Stop Dictation", action: #selector(toggleDictation), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit DictationIsland", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleDictation() {
        island?.model.toggle()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
