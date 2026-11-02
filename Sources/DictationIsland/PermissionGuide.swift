import AppKit
import SwiftUI

/// A small floating card that docks under System Settings while you grant a permission, with
/// the app's icon to drag into the list. macOS only adds an app to the Accessibility list when it
/// is dragged in (or after an alarming system prompt), so showing exactly what to drag, right
/// next to the list, is the difference between "where do I click?" and done. The idea is Hex's.
///
/// It follows the System Settings window while it moves and closes itself once the permission
/// is granted, System Settings quits, or after a few minutes.
@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()

    private var panel: NSPanel?
    private var timer: Timer?
    private var permission: Permission?
    private var openedAt = Date()

    private static let width: CGFloat = 380
    private static let height: CGFloat = 92

    func show(for permission: Permission) {
        close()
        self.permission = permission
        openedAt = Date()
        permission.openSettings()

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: PermissionGuideCard(permission: permission) { [weak self] in self?.close() })
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
        self.panel = panel
        position()
        panel.orderFrontRegardless()

        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        permission = nil
    }

    private func tick() {
        guard let permission else { return close() }
        let settingsRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").isEmpty
        let expired = Date().timeIntervalSince(openedAt) > 300
        // Give System Settings a moment to launch before treating "not running" as closed.
        // `--guide-preview` keeps it up on a Mac that already granted, for screenshots.
        let granted = permission.isGranted && !CommandLine.arguments.contains("--guide-preview")
        if granted || expired || (!settingsRunning && Date().timeIntervalSince(openedAt) > 4) {
            return close()
        }
        position()
    }

    /// Just below the System Settings window, or tucked inside its bottom edge when there's no
    /// room below. Bottom-centre of the screen until the window appears.
    private func position() {
        guard let panel else { return }
        let size = CGSize(width: Self.width, height: Self.height)
        if let window = Self.systemSettingsFrame() {
            var origin = CGPoint(x: window.midX - size.width / 2, y: window.minY - size.height - 10)
            let screen = NSScreen.screens.first { $0.frame.intersects(window) } ?? NSScreen.main
            if let visible = screen?.visibleFrame, origin.y < visible.minY + 8 {
                origin.y = window.minY + 16
            }
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
        } else if let visible = NSScreen.main?.visibleFrame {
            panel.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.minY + 80, width: size.width, height: size.height), display: true)
        }
    }

    /// System Settings' main window in Cocoa coordinates. Window bounds are readable without
    /// Screen Recording permission (titles aren't, so match by owning process).
    private static func systemSettingsFrame() -> CGRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let windows = list.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        guard let bounds = windows.compactMap({ $0[kCGWindowBounds as String] as? [String: CGFloat] })
            .map({ CGRect(x: $0["X"] ?? 0, y: $0["Y"] ?? 0, width: $0["Width"] ?? 0, height: $0["Height"] ?? 0) })
            .max(by: { $0.width * $0.height < $1.width * $1.height }),
            bounds.width > 200
        else { return nil }
        // Quartz window coordinates start at the top-left of the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

private struct PermissionGuideCard: View {
    let permission: Permission
    let onClose: () -> Void

    private var appIcon: NSImage { NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) }

    private var instructions: (title: String, detail: String) {
        switch permission {
        case .microphone:
            return ("Turn on DictationIsland", "Flip its switch in the Microphone list above.")
        default:
            return ("Drag DictationIsland into the list", "Then make sure its switch is on. Already listed? Just turn it on.")
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            if permission == .microphone {
                Image(nsImage: appIcon).resizable().frame(width: 44, height: 44)
            } else {
                // A real file drag of the app bundle: System Settings' privacy lists accept it.
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                    .help("Drag into the list above")
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                    Text(instructions.title).font(.system(size: 13, weight: .semibold))
                }
                Text(instructions.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(14)
        .frame(width: 380, height: 92)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}
