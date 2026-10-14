import SwiftUI

/// Animation vocabulary recovered from Alcove's binary (see research/alcove/REPORT.md §Motion).
///
/// Alcove splits motion in two families:
/// - Shape/geometry morphs use `Spring(duration:bounce:)` with visible bounce (0.3–0.4),
///   and an overdamped spring (bounce -0.2) when collapsing.
/// - Content (labels, icons, opacity) uses critically damped springs
///   (`dampingFraction: 1.0`, response 0.2–0.5) plus very short ease-outs (0.1s).
enum Motion {
    /// Most common shape spring in Alcove (17 call sites): small widen/HUD morphs.
    static let widen = Animation.spring(Spring(duration: 0.35, bounce: 0.3))
    /// Larger open/expand morphs (Alcove: 0.5/0.375, 0.6/0.35, 0.6/0.4).
    static let open = Animation.spring(Spring(duration: 0.5, bounce: 0.375))
    /// Collapse: overdamped so the island settles back into the notch without wobble.
    static let close = Animation.spring(Spring(duration: 0.35, bounce: -0.2))

    /// Content swaps: critically damped (Alcove's dominant pair, 61 call sites).
    static let content = Animation.spring(response: 0.2, dampingFraction: 1.0)
    static let contentSlow = Animation.spring(response: 0.4, dampingFraction: 1.0)
    /// Quick fades (Alcove: easeOut(0.1), 29 call sites).
    static let fade = Animation.easeOut(duration: 0.1)
}

/// Alcove's `SlideBlurScaleModifier` / `DelayedBlurFadeModifier`: content enters by
/// un-blurring, fading in, and scaling up from slightly smaller.
struct BlurFade: ViewModifier {
    var opacity: Double
    var blur: CGFloat
    var scale: CGFloat
    var offsetY: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blur)
            .scaleEffect(scale)
            .offset(y: offsetY)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(
            active: BlurFade(opacity: 0, blur: 6, scale: 0.85),
            identity: BlurFade(opacity: 1, blur: 0, scale: 1)
        )
    }

    /// Words entering the live transcript rise slightly while un-blurring.
    static var wordIn: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: BlurFade(opacity: 0, blur: 4, scale: 0.96, offsetY: 4),
                identity: BlurFade(opacity: 1, blur: 0, scale: 1)
            ),
            removal: .opacity
        )
    }
}

/// Alcove's `ShakeEffect`: horizontal shake for errors.
struct ShakeEffect: GeometryEffect {
    var position: CGFloat
    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: sin(position * .pi * 6) * 6, y: 0))
    }
}
