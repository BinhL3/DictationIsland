import SwiftUI

/// Bar waveform: a fixed number of rounded bars, a shared animation clock, and two sources: `live`
/// (spectrum bands) and `simulated` (synthesized motion).
/// `suspended` holds a low resting line while transcription finishes.
struct WaveformView: View {
    enum Source {
        case live
        case simulated
        case suspended
    }

    let meter: LevelMeter
    var source: Source
    var color: Color = .white
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5
    /// Stops redrawing; an idle 60 fps timeline costs real CPU and WindowServer time.
    var isPaused = false

    @State private var smoother = Smoother()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: isPaused)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let levels = smoother.step(targets: targets(at: t))
                let count = levels.count
                let total = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing
                var x = (size.width - total) / 2
                for level in levels {
                    let height = max(barWidth, CGFloat(level) * size.height)
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                    x += barWidth + spacing
                }
            }
        }
    }

    private func targets(at t: TimeInterval) -> [Float] {
        switch source {
        case .live:
            return meter.read()
        case .simulated:
            return (0..<meter.bandCount).map { i in
                let phase = Double(i) * 1.7
                let speech = 0.5 + 0.5 * sin(t * 2.1 + phase) * sin(t * 5.3 + phase * 0.6)
                return Float(0.2 + 0.75 * speech)
            }
        case .suspended:
            return (0..<meter.bandCount).map { i in Float(0.18 + 0.06 * sin(t * 3 + Double(i) * 0.9)) }
        }
    }

    /// Fast attack, slow release, the usual meter ballistics.
    final class Smoother {
        private var values: [Float] = []

        func step(targets: [Float]) -> [Float] {
            if values.count != targets.count { values = targets.map { _ in 0 } }
            for i in values.indices {
                let k: Float = targets[i] > values[i] ? 0.45 : 0.12
                values[i] += (targets[i] - values[i]) * k
            }
            return values
        }
    }
}

/// Recording indicator: red dot whose glow breathes with input loudness.
struct RecordingDot: View {
    let meter: LevelMeter
    var simulated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { timeline in
            let level = currentLevel(at: timeline.date.timeIntervalSinceReferenceDate)
            Circle()
                .fill(Color(red: 1, green: 0.27, blue: 0.23))
                .frame(width: 8, height: 8)
                .shadow(color: .red.opacity(0.5 + Double(level) * 0.5), radius: 2 + CGFloat(level) * 6)
                .scaleEffect(1 + CGFloat(level) * 0.35)
                .animation(Motion.content, value: level)
        }
    }

    private func currentLevel(at t: TimeInterval) -> Float {
        if simulated { return Float(0.5 + 0.5 * sin(t * 4)) }
        let levels = meter.read()
        return levels.max() ?? 0
    }
}

/// Moving highlight across text while the final transcript resolves.
struct ShimmerModifier: ViewModifier {
    var isActive: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.55), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase * geo.size.width * 1.5)
                        .blendMode(.plusLighter)
                    }
                    .mask(content)
                    .onAppear {
                        phase = -0.5
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
                    }
                }
            }
    }
}

extension View {
    func shimmer(_ isActive: Bool) -> some View { modifier(ShimmerModifier(isActive: isActive)) }
}
