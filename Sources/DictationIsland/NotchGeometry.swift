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

    /// The panel is a fixed transparent canvas; the island morphs inside it, so the window itself
    /// never resizes mid-animation.
    static let canvasSize = CGSize(width: 640, height: 300)

    static func forScreen(_ screen: NSScreen, placement: IslandPlacement) -> NotchGeometry {
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

        // Floating pill just under the menu bar, clear of whatever owns the notch.
        if placement == .belowMenuBar {
            return NotchGeometry(
                style: .pill,
                closedSize: CGSize(width: 76, height: 24),
                topInset: menuBarHeight + 6,
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

        let pillHeight = min(24, menuBarHeight - 4)
        return NotchGeometry(
            style: .pill,
            closedSize: CGSize(width: 76, height: pillHeight),
            topInset: (menuBarHeight - pillHeight) / 2,
            screenFrame: frame
        )
    }

    var canvasFrame: CGRect {
        CGRect(
            x: screenFrame.midX - Self.canvasSize.width / 2,
            y: screenFrame.maxY - Self.canvasSize.height,
            width: Self.canvasSize.width,
            height: Self.canvasSize.height
        )
    }

    /// Island rect in screen coordinates (AppKit, bottom-left origin) for hit testing.
    func islandScreenRect(size: CGSize) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - topInset - size.height,
            width: size.width,
            height: size.height
        )
    }
}

/// The island's outline.
///
/// `.notch`: flat top flush with the screen edge, concave "ears" (topCornerRadius) that blend into
/// the menu bar, and convex bottom corners. `.pill`: a continuous rounded rectangle.
struct NotchShape: Shape {
    var style: IslandStyle
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        switch style {
        case .pill:
            let radius = min(bottomCornerRadius, rect.height / 2, rect.width / 2)
            return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        case .notch:
            let top = min(topCornerRadius, rect.width / 4)
            let bottom = min(bottomCornerRadius, (rect.height - top), (rect.width - 2 * top) / 2)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                control: CGPoint(x: rect.minX + top, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                control: CGPoint(x: rect.minX + top, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                control: CGPoint(x: rect.maxX - top, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control: CGPoint(x: rect.maxX - top, y: rect.minY)
            )
            path.closeSubpath()
            return path
        }
    }
}
