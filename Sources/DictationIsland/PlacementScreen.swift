import AppKit
import SwiftUI

/// Home's hero: a little MacBook showing this Mac's menu bar, notch and Dock at their real sizes,
/// with the island playing on it. Drag the island (or click a spot) to move it: it snaps to the
/// notch, just below the menu bar, or just above the Dock.
struct PlacementScreen: View {
    let island: IslandModel
    /// The island is Home's demo (not a live dictation), so it can move in step with the drag.
    var isDemo = true
    @Binding var placement: IslandPlacement

    static let screenHeight: CGFloat = 280

    /// How far the island is dragged from its spot.
    @State private var dragOffset: CGFloat = 0
    /// This Mac's desktop picture, scaled down; nil until loaded or if it can't be read.
    @State private var desktopPicture: CGImage? = DesktopPicture.cached
    @State private var dragTarget: Slot?
    /// From the first drag until the new spot is committed: the shape follows the drag.
    @State private var moving = false
    /// The spot the island is latched onto mid-drag, for one haptic tick per latch.
    @State private var latched: Slot?
    /// Within this distance of a spot the island is pulled onto it.
    private static let magnetRange: CGFloat = 44

    /// Where the island draws for a pointer `distance` from a spot: stuck to it close in,
    /// easing back to the pointer by the edge of the range. Continuous, so it never jumps.
    private static func magnet(_ distance: CGFloat, range: CGFloat = magnetRange) -> CGFloat {
        let reach = abs(distance)
        guard range > 0, reach < range else { return distance }
        let t = reach / range
        // Follows a growing share of the pointer's distance: almost none near the spot, all of
        // it (and at the pointer's pace) by the edge, so there's no jump or jolt leaving it.
        let share = t * t * t * (t * (6 * t - 15) + 10)
        return distance * share
    }

    private enum Slot: CaseIterable {
        case top, belowMenuBar, bottom

        var placement: IslandPlacement {
            switch self {
            case .top: return .automatic
            case .belowMenuBar: return .belowMenuBar
            case .bottom: return .bottom
            }
        }
    }

    private var screen: NSScreen? { NSScreen.preferredIslandScreen }

    private var cutout: CameraCutout {
        screen.map { AppSettings.shared.cameraCutout.resolved(for: $0) } ?? .automatic
    }

    /// The island resting at the top spot, as the real one would on this screen.
    private var topGeometry: NotchGeometry? {
        screen.map { NotchGeometry.forScreen($0, placement: .menuBar) }
    }

    private var notchSize: CGSize? {
        cutout == .notch ? topGeometry?.closedSize : nil
    }

    private var menuBarHeight: CGFloat {
        guard let screen else { return 28 }
        return max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
    }

    private var dockHeight: CGFloat {
        screen.map(NotchGeometry.dockHeight) ?? 0
    }

    private var current: Slot {
        switch placement.resolved {
        case .belowMenuBar: return .belowMenuBar
        case .bottom: return .bottom
        default: return .top
        }
    }

    private func title(_ slot: Slot) -> String {
        switch slot {
        case .top:
            switch cutout {
            case .notch: return "In the notch"
            case .hole: return "Around the camera"
            case .automatic: return "In the menu bar"
            }
        case .belowMenuBar: return "Below the menu bar"
        case .bottom: return dockHeight > 0 ? "Above the Dock" : "At the bottom"
        }
    }

    /// Where each spot's resting pill sits on the preview (centre y, size).
    private func rect(_ slot: Slot, in size: CGSize) -> CGRect {
        let pill = CGSize(width: 76, height: 24)
        let center: CGPoint
        var box = pill
        switch slot {
        case .top:
            if let top = topGeometry {
                box = top.closedSize
                center = CGPoint(x: size.width / 2, y: top.topInset + box.height / 2)
            } else {
                box.height = min(24, menuBarHeight - 4)
                center = CGPoint(x: size.width / 2, y: menuBarHeight / 2)
            }
        case .belowMenuBar:
            center = CGPoint(x: size.width / 2, y: menuBarHeight + 6 + pill.height / 2)
        case .bottom:
            center = CGPoint(x: size.width / 2, y: size.height - dockHeight - 10 - pill.height / 2)
        }
        return CGRect(x: center.x - box.width / 2, y: center.y - box.height / 2, width: box.width, height: box.height)
    }

    /// Where the island draws for a pointer at `y`. Each spot pulls within its range, but never
    /// past halfway to the next spot (the notch and below-the-menu-bar spots sit close), so the
    /// pulls hand over at the midpoint without a jump.
    private func magnetized(_ y: CGFloat, in size: CGSize) -> CGFloat {
        let spots = Slot.allCases.map { rect($0, in: size).midY }.sorted()
        for (index, spot) in spots.enumerated() {
            let previous = index > 0 ? spots[index - 1] : nil
            let next = index + 1 < spots.count ? spots[index + 1] : nil
            let above = previous.map { min(Self.magnetRange, (spot - $0) / 2) } ?? Self.magnetRange
            let below = next.map { min(Self.magnetRange, ($0 - spot) / 2) } ?? Self.magnetRange
            if y < spot, spot - y < above { return spot + Self.magnet(y - spot, range: above) }
            if y >= spot, y - spot < below { return spot + Self.magnet(y - spot, range: below) }
        }
        return y
    }

    /// How pill-like the island looks at `y` while it's moved: the notch shape in the notch,
    /// folding into a pill on the way to the next spot. nil leaves it to the island's setting.
    private func pillness(in size: CGSize) -> CGFloat? {
        guard moving else { return nil }
        guard notchSize != nil else { return 1 }
        let y = rect(current, in: size).midY + dragOffset
        let notch = rect(.top, in: size).midY, next = rect(.belowMenuBar, in: size).midY
        return min(max((y - notch) / max(next - notch, 1), 0), 1)
    }

    private func nearest(to y: CGFloat, in size: CGSize) -> Slot {
        Slot.allCases.min { abs(rect($0, in: size).midY - y) < abs(rect($1, in: size).midY - y) } ?? current
    }

    var body: some View {
        VStack(spacing: 0) {
            // Lid: a thin black bezel around the screen.
            screenView
                .frame(height: Self.screenHeight)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 4, bottomTrailingRadius: 4, topTrailingRadius: 10, style: .continuous))
                .padding(.horizontal, 9)
                .padding(.top, 9)
                .padding(.bottom, 14)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous)
                        .fill(Color(white: 0.035))
                        .overlay(
                            UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous)
                                .strokeBorder(Color(white: 0.32), lineWidth: 1.5)
                        )
                )
                .padding(.horizontal, 22)
            base
            caption.padding(.top, 12)
        }
    }

    /// Says where the island is, or where it will land while dragging.
    private var caption: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
            Text("Drag the island to move it.")
            Spacer()
            Text(dragTarget.map { "Drop: \(title($0))" } ?? title(current))
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(dragTarget == nil ? 0.7 : 0.95))
                .contentTransition(.opacity)
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.45))
        .animation(.easeOut(duration: 0.15), value: dragTarget)
    }

    /// The keyboard deck's front edge, with the opening notch.
    private var base: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 2, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.62), Color(white: 0.34), Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
                .frame(height: 13)
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 0, style: .continuous)
                .fill(Color(white: 0.28))
                .frame(width: 96, height: 5)
        }
        .shadow(color: .black.opacity(0.6), radius: 10, y: 6)
    }

    private var screenView: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .top) {
                wallpaper
                menuBar
                if let notchSize {
                    NotchShape(style: .notch, topCornerRadius: 6, bottomCornerRadius: 10)
                        .fill(.black)
                        .frame(width: notchSize.width, height: notchSize.height)
                }
                if cutout == .hole {
                    // The hole-punch camera, centred in the menu bar.
                    Circle()
                        .fill(.black)
                        .overlay(Circle().fill(Color(red: 0.12, green: 0.16, blue: 0.3)).frame(width: 4, height: 4).offset(x: -1, y: -1))
                        .frame(width: 10, height: 10)
                        .padding(.top, menuBarHeight / 2 - 5)
                }
                if dockHeight > 0 {
                    dock.frame(maxHeight: .infinity, alignment: .bottom)
                }

                // The island itself, at its real size, playing demo or live dictations. Dragging
                // moves it; near a spot it latches on like a magnet.
                IslandView(model: island)
                    .frame(width: NotchGeometry.canvasSize.width, height: size.height)
                    .frame(width: size.width)
                    .environment(\.islandPillness, pillness(in: size))
                    .offset(y: dragOffset)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            // One element for assistive apps (and the demo-recording skill, which finds it by id).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Island position")
            .accessibilityValue(title(current))
            .accessibilityIdentifier("placement-screen")
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard abs(value.translation.height) > 3 || dragTarget != nil else { return }
                        let home = rect(current, in: size).midY
                        let wanted = min(max(home + value.translation.height, 12), size.height - 12)
                        let slot = nearest(to: wanted, in: size)
                        let spot = rect(slot, in: size).midY
                        let isLatched = abs(wanted - spot) < 12
                        let y = magnetized(wanted, in: size)
                        if isLatched, latched != slot {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        }
                        latched = isLatched ? slot : nil
                        moving = true
                        withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.9)) {
                            dragTarget = slot
                            dragOffset = y - home
                        }
                    }
                    .onEnded { value in
                        // A click (no drag) moves it to the spot nearest the click.
                        let slot = dragTarget ?? nearest(to: value.location.y, in: size)
                        let travel = rect(slot, in: size).midY - rect(current, in: size).midY
                        latched = nil
                        moving = true
                        // Glide onto the spot without overshoot, then hand over to the real
                        // setting once it's there, so the swap is invisible.
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.88), completionCriteria: .logicallyComplete) {
                            dragOffset = travel
                            dragTarget = nil
                        } completion: {
                            moving = false
                            placement = slot.placement
                            guard isDemo, let screen = NSScreen.preferredIslandScreen else {
                                // A live dictation follows the real island's own move.
                                var instant = Transaction()
                                instant.disablesAnimations = true
                                withTransaction(instant) { dragOffset = 0 }
                                return
                            }
                            // The island eases its size and shape to the new spot's with its own
                            // spring, which also carries its position from the old spot to the new
                            // one. Unwinding the drag offset on that same spring cancels the move
                            // exactly, so it stays put while it reshapes.
                            island.updateGeometry(NotchGeometry.forScreen(screen, placement: slot.placement.resolved))
                            withAnimation(island.shapeAnimation) { dragOffset = 0 }
                        }
                    }
            )
            .pointerStyle(dragTarget == nil ? .grabIdle : .grabActive)
        }
    }

    private var wallpaper: some View {
        // The viewer's own desktop picture, so the little screen looks like theirs. A flat colour
        // stands in until it loads, or when it can't be read (a moving aerial, say).
        Color(red: 0.17, green: 0.16, blue: 0.36)
            .overlay {
                if let desktopPicture {
                    Image(decorative: desktopPicture, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                }
            }
            .clipped()
            .task {
                guard desktopPicture == nil, let picture = await DesktopPicture.load() else { return }
                withAnimation(.easeOut(duration: 0.3)) { desktopPicture = picture }
            }
    }

    private var menuBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo").font(.system(size: 12))
            Text("DictationIsland").fontWeight(.bold)
            Text("File")
            Text("Edit")
            Text("View")
            Spacer(minLength: (notchSize?.width ?? topGeometry?.closedSize.width ?? 0) + 20)
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.weekday(.abbreviated).hour().minute())
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.88))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: menuBarHeight)
        .background(.black.opacity(0.2))
    }

    private var dock: some View {
        let icon = max(18, min(48, dockHeight - 22))
        let colors: [(Color, Color)] = [
            (.blue, .cyan), (.green, .mint), (.orange, .yellow), (.pink, .red),
            (.indigo, .purple), (Color(white: 0.75), Color(white: 0.45)), (.teal, .blue), (.yellow, .orange),
        ]
        return HStack(spacing: 6) {
            ForEach(colors.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: icon * 0.24, style: .continuous)
                    .fill(LinearGradient(colors: [colors[index].0, colors[index].1], startPoint: .top, endPoint: .bottom))
                    .frame(width: icon, height: icon)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.2)))
        .padding(.bottom, max(2, (dockHeight - icon - 14) / 2))
    }
}

/// The desktop picture of the screen the island is on, decoded once at preview size. Desktop
/// pictures are often 20+ MB HEICs, so it's downsampled off the main thread.
enum DesktopPicture {
    @MainActor static var cached: CGImage?

    @MainActor
    static func load() async -> CGImage? {
        if let cached { return cached }
        guard let screen = NSScreen.preferredIslandScreen ?? NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let image = await Task.detached(priority: .utility) { decode(url) }.value
        cached = image
        return image
    }

    private nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1400,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
