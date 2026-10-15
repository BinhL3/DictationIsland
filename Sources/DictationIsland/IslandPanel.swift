import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats over the menu bar on every Space.
/// It sits at `CGShieldingWindowLevel() + 2` and inside a level-401 `WindowSpace`, above notch apps
/// such as Alcove, so it grows out of the notch *over* their pill while dictating. Idle, it steps
/// back below them (see `IslandWindowController.updateLayering`).
final class IslandPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
    }

    // Never steal focus: the dictated text must land in the app the user was typing in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view with no safe area: on notched screens the top of the window overlaps the camera
/// housing, and SwiftUI would otherwise inset content below it.
final class SafeAreaFreeHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}

/// Owns the panel for one screen and uses global mouse monitors for hover detection plus
/// click-through outside the island.
@MainActor
final class IslandWindowController {
    let model: IslandModel
    private let panel: IslandPanel
    private let space = WindowSpace()
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    private var lowerTask: Task<Void, Never>?
    /// Cached from `relayout`, which reruns when a notch app launches or quits; checking running
    /// apps on every mouse move would be wasteful.
    private var notchAppRunning = IslandPlacement.notchAppIsRunning

    init(screen: NSScreen) {
        let geometry = NotchGeometry.forScreen(screen, placement: AppSettings.shared.placement.resolved)
        model = IslandModel(geometry: geometry)
        panel = IslandPanel(frame: geometry.canvasFrame)
        panel.contentView = SafeAreaFreeHostingView(rootView: IslandView(model: model))
        panel.orderFrontRegardless()
        space?.add(panel)

        // A global mouse-moved monitor needs no permissions. The local one covers events
        // delivered to our own panel once it starts accepting the mouse.
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.updateHover() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
        // Automatic placement depends on whether a notch app like Alcove is running.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard IslandPlacement.notchAppBundleIDs.contains(app?.bundleIdentifier ?? "") else { return }
                MainActor.assumeIsolated { self?.relayout() }
            }
        }
        relayout()
        observeSettings()
        observePhase()
    }

    private func observePhase() {
        withObservationTracking {
            _ = model.phase
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.updateLayering()
                    self?.observePhase()
                }
            }
        }
    }

    /// While dictating, the island sits in its own window-server space above notch apps like
    /// Alcove. Idle, if one is running, it leaves that space so it falls below the app's window
    /// and the app keeps its hover and clicks. Leaving waits for the collapse animation to finish.
    private func updateLayering() {
        lowerTask?.cancel()
        guard model.phase == .idle, notchAppRunning else {
            space?.add(panel)
            return
        }
        lowerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, self.model.phase == .idle else { return }
            self.space?.remove(self.panel)
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = AppSettings.shared.placement
            _ = AppSettings.shared.showIdlePill
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.relayout()
                    self?.observeSettings()
                }
            }
        }
    }

    private func relayout() {
        guard let screen = NSScreen.preferredIslandScreen else { return }
        let settings = AppSettings.shared
        let placement = settings.placement.resolved
        let geometry = NotchGeometry.forScreen(screen, placement: placement)
        notchAppRunning = IslandPlacement.notchAppIsRunning
        updateLayering()
        model.updateGeometry(geometry)
        // On a notch the resting island is the black camera housing itself, so it's always "shown".
        // In the menu bar, a running notch app already draws its own resting pill in the same spot.
        model.showsIdleIsland = geometry.style == .notch
            || (placement == .menuBar && settings.showIdlePill && !IslandPlacement.notchAppIsRunning)
        panel.setFrame(geometry.canvasFrame, display: true)
    }

    private func updateHover() {
        let mouse = NSEvent.mouseLocation
        let rect = model.geometry.islandScreenRect(size: model.islandSize).insetBy(dx: -6, dy: -6)
        // Idle, a notch app owns the notch: its hover and clicks must reach it, not us.
        let inside = rect.contains(mouse)
            && (model.phase != .idle || (model.showsIdleIsland && !notchAppRunning))

        // Outside the island the canvas is click-through, so the menu bar below stays usable.
        panel.ignoresMouseEvents = !inside

        // Small dwell before expanding so passing the cursor over doesn't open it; leaving is immediate.
        hoverTask?.cancel()
        if inside, !model.isHovering, model.phase != .idle {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.model.isHovering = true
            }
        } else if !inside, model.isHovering {
            model.isHovering = false
        }
    }
}

extension NSScreen {
    /// Prefer the built-in notched display, falling back to the main screen.
    static var preferredIslandScreen: NSScreen? {
        screens.first { $0.safeAreaInsets.top > 0 } ?? main ?? screens.first
    }
}
