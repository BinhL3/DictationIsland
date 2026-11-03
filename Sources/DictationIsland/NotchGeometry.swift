import AppKit
import SwiftUI

/// On screens with a camera housing the island grows out of the hardware notch; elsewhere it is a
/// floating pill inside the menu bar.
enum IslandStyle {
    case notch
    case pill
}

/// Screen-derived measurements for one display.
struct NotchGeometry: Equatable {
    var style: IslandStyle
    /// Size of the resting island; equals the hardware notch on notched screens.
    var closedSize: CGSize
    /// Gap between the screen's top edge and the island (0 when attached to a hardware notch).
    var topInset: CGFloat
    var screenFrame: CGRect
    /// Which screen edge the island hangs from. At the bottom it sits above the Dock and grows
    /// upward.
    var edge: VerticalEdge = .top
    /// Gap between the screen's bottom edge and the island, for `edge == .bottom`.
    var bottomInset: CGFloat = 0

    /// The panel is a fixed transparent canvas; the island morphs inside it, so the window itself
    /// never resizes mid-animation.
    static let canvasSize = CGSize(width: 640, height: 300)

    /// macOS reports a notch (a top safe-area inset with menu bar areas either side).
    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    /// Size of the pill that rests around a hole-punch camera, Dynamic Island style.
    static func cameraPillSize(menuBarHeight: CGFloat) -> CGSize {
        CGSize(width: 92, height: min(28, menuBarHeight - 4))
    }

    @MainActor
    static func forScreen(_ screen: NSScreen, placement: IslandPlacement) -> NotchGeometry {
        let cutout = AppSettings.shared.cameraCutout.resolved(for: screen)
        let frame = screen.frame
        // Debug: lay out as if this screen had a 185×32 notch.
        if CommandLine.arguments.contains("--simulate-notch") {
            return NotchGeometry(
                style: .notch,
                closedSize: CGSize(width: 185, height: 32),
                topInset: 0,
                screenFrame: frame
            )
        }

        let menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)

        // Floating pill just above the Dock (or the screen's bottom edge when the Dock hides or
        // sits at the side).
        if placement == .bottom {
            return NotchGeometry(
                style: .pill,
                closedSize: CGSize(width: 76, height: 24),
                topInset: 0,
                screenFrame: frame,
                edge: .bottom,
                bottomInset: dockHeight(screen) + 10
            )
        }

        // Floating pill just under the menu bar, clear of whatever owns the notch.
        if placement == .belowMenuBar {
            return NotchGeometry(
                style: .pill,
                closedSize: CGSize(width: 76, height: 24),
                topInset: menuBarHeight + 6,
                screenFrame: frame
            )
        }

        // A hole-punch camera: a pill in the menu bar that frames it.
        if cutout == .hole {
            let size = cameraPillSize(menuBarHeight: menuBarHeight)
            return NotchGeometry(
                style: .pill,
                closedSize: size,
                topInset: (menuBarHeight - size.height) / 2,
                screenFrame: frame
            )
        }

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            return NotchGeometry(
                style: .notch,
                closedSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                topInset: 0,
                screenFrame: frame
            )
        }

        // Notch chosen for a screen macOS doesn't report one on: the usual MacBook notch size.
        if cutout == .notch {
            return NotchGeometry(
                style: .notch,
                closedSize: CGSize(width: 185, height: menuBarHeight),
                topInset: 0,
                screenFrame: frame
            )
        }

        let pillHeight = min(24, menuBarHeight - 4)
        return NotchGeometry(
            style: .pill,
            closedSize: CGSize(width: 76, height: pillHeight),
            topInset: (menuBarHeight - pillHeight) / 2,
            screenFrame: frame
        )
    }

    /// Height the Dock takes at the bottom of `screen` (0 when it hides or sits at a side).
    static func dockHeight(_ screen: NSScreen) -> CGFloat {
        max(0, screen.visibleFrame.minY - screen.frame.minY)
    }

    var canvasFrame: CGRect {
        CGRect(
            x: screenFrame.midX - Self.canvasSize.width / 2,
            y: edge == .top ? screenFrame.maxY - Self.canvasSize.height : screenFrame.minY,
            width: Self.canvasSize.width,
            height: Self.canvasSize.height
        )
    }

    /// Island rect in screen coordinates (AppKit, bottom-left origin) for hit testing.
    func islandScreenRect(size: CGSize) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2,
            y: edge == .top ? screenFrame.maxY - topInset - size.height : screenFrame.minY + bottomInset,
            width: size.width,
            height: size.height
        )
    }
}

/// The island's outline.
///
/// Notch (`pillness` 0): flat top flush with the screen edge, concave "ears" (topCornerRadius)
/// that blend into the menu bar, and convex bottom corners. Pill (`pillness` 1): a continuous
/// rounded rectangle. In between, the ears fold into rounded top corners, so moving the island
/// out of the notch morphs it rather than swapping shapes.
struct NotchShape: Shape {
    var pillness: CGFloat
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(style: IslandStyle, topCornerRadius: CGFloat, bottomCornerRadius: CGFloat) {
        self.init(pillness: style == .pill ? 1 : 0, topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
    }

    init(pillness: CGFloat, topCornerRadius: CGFloat, bottomCornerRadius: CGFloat) {
        self.pillness = pillness
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(pillness, AnimatablePair(topCornerRadius, bottomCornerRadius)) }
        set {
            pillness = newValue.first
            topCornerRadius = newValue.second.first
            bottomCornerRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(pillness, 0), 1)
        let lerp = { (a: CGFloat, b: CGFloat) in a + (b - a) * p }
        // Notch: concave ears of `ear`. Pill: every corner rounded by `round`.
        let ear = min(topCornerRadius, rect.width / 4)
        let round = min(bottomCornerRadius, rect.height / 2, rect.width / 2)
        let notchBottom = max(0, min(bottomCornerRadius, rect.height - ear, (rect.width - 2 * ear) / 2))
        let bottom = lerp(notchBottom, round)
        // Each top corner runs from a point on the top edge (a) to the side (b) around a control
        // point (c); the notch and pill versions of those points are blended.
        let side = (1 - p) * ear
        let a = p * round
        let bY = (1 - p) * ear + p * round

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + a, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + side, y: rect.minY + bY),
            control: CGPoint(x: rect.minX + side, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + side, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + side + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + side, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - side - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - side, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - side, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - side, y: rect.minY + bY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - a, y: rect.minY),
            control: CGPoint(x: rect.maxX - side, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct IslandPillnessKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// Overrides how pill-like the island is drawn (0 notch, 1 pill), for Home's drag preview.
    var islandPillness: CGFloat? {
        get { self[IslandPillnessKey.self] }
        set { self[IslandPillnessKey.self] = newValue }
    }
}
