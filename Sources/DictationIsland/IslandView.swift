import SwiftUI

/// Root view inside the fixed transparent canvas. The island is a black `NotchShape` anchored to
/// the top edge whose size and radii are derived from `IslandModel.presentation`.
struct IslandView: View {
    @Bindable var model: IslandModel

    var body: some View {
        let size = model.islandSize
        let radii = model.cornerRadii

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(style: model.geometry.style, topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
                    .fill(.black)
                content
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipShape(NotchShape(style: model.geometry.style, topCornerRadius: radii.top, bottomCornerRadius: radii.bottom))
            }
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(model.presentation == .closed ? 0 : 0.35), radius: 12, y: 4)
            // A hidden idle island shrinks into nothing and grows back out when dictation starts.
            .opacity(isHiddenIdle ? 0 : 1)
            .scaleEffect(isHiddenIdle ? 0.6 : 1, anchor: .top)
            .modifier(ShakeEffect(position: model.shakeTrigger))
            .animation(model.shapeAnimation, value: model.presentation)
            .animation(model.shapeAnimation, value: model.geometry)
            .contentShape(Rectangle())
            // Expanded has explicit buttons; elsewhere a click toggles dictation.
            .onTapGesture { if model.presentation != .expanded { model.toggle() } }
        }
        .padding(.top, model.geometry.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var isHiddenIdle: Bool {
        model.presentation == .closed && !model.showsIdleIsland
    }

    private typealias Metrics = IslandModel.Metrics

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.presentation {
            case .closed:
                EmptyView()
            case .message:
                MessageRow(model: model)
                    .frame(height: model.headerHeight)
                    .transition(.blurFade)
            case .compact, .peek, .expanded:
                header
                    .frame(height: model.headerHeight)
                    .transition(.blurFade)
            }

            switch model.presentation {
            case .peek:
                peekLine
                    .frame(height: Metrics.transcriptLineHeight)
                    .padding(.horizontal, model.horizontalInset)
                    .transition(.blurFade)
            case .expanded:
                ExpandedBody(model: model)
                    .transition(.blurFade)
            default:
                EmptyView()
            }
        }
    }

    /// Leading wing: status glyph + elapsed time. Trailing wing: waveform. On a notch the middle
    /// stays empty so nothing sits under the camera.
    private var header: some View {
        HStack(spacing: 0) {
            leadingWing
            Spacer(minLength: model.geometry.style == .notch ? model.geometry.closedSize.width : Metrics.wingGap)
            trailingWing
        }
        .padding(.horizontal, model.horizontalInset)
        .animation(Motion.content, value: model.phase)
    }

    private var leadingWing: some View {
        HStack(spacing: Metrics.glyphSpacing) {
            statusGlyph
                .frame(width: Metrics.glyphSize, height: Metrics.glyphSize)
                .id(glyphKey)
                .transition(.blurFade)
            if model.phase == .listening || model.phase == .finishing {
                ElapsedTime(start: model.listeningStartedAt, end: model.listeningEndedAt)
                    .frame(width: Metrics.timerWidth, alignment: .leading)
                    .transition(.blurFade)
            }
        }
    }

    private var glyphKey: String {
        switch model.phase {
        case .listening: return "rec"
        case .finishing, .preparing: return "spin"
        case .done: return "done"
        case .error: return "error"
        case .idle: return "idle"
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch model.phase {
        case .listening:
            RecordingDot(meter: model.meter, simulated: model.simulatesAudio)
        case .finishing, .preparing:
            Spinner()
        case .done(let result):
            StatusIcon(result: result)
        case .error:
            StatusIcon(isError: true)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailingWing: some View {
        switch model.phase {
        case .listening:
            WaveformView(meter: model.meter, source: model.simulatesAudio ? .simulated : .live)
                .frame(width: Metrics.waveformWidth, height: Metrics.glyphSize)
                .transition(.blurFade)
        case .finishing:
            WaveformView(meter: model.meter, source: .suspended, color: .white.opacity(0.45))
                .frame(width: Metrics.waveformWidth, height: Metrics.glyphSize)
                .transition(.blurFade)
        case .preparing(let fraction):
            // Notch only: the camera sits where the message would go, so show progress.
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .contentTransition(.numericText())
        case .done:
            // Notch only (pill uses `MessageRow`): the label goes in the trailing wing.
            Text(model.messageText ?? "")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize()
                .transition(.blurFade)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var peekLine: some View {
        if case .error(let message) = model.phase {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LiveTranscriptLine(text: model.transcript, isFinishing: model.phase == .finishing)
        }
    }
}

/// Pill-style done/error: icon and text centred together as one row.
private struct MessageRow: View {
    @Bindable var model: IslandModel

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch model.phase {
                case .done(let result): StatusIcon(result: result)
                case .preparing: Spinner()
                default: StatusIcon(isError: true)
                }
            }
            .frame(width: IslandModel.Metrics.glyphSize, height: IslandModel.Metrics.glyphSize)
            Text(model.messageText ?? "")
                .font(Font(IslandModel.Metrics.messageFont).monospacedDigit())
                .foregroundStyle(isError ? Color.orange : Color.white.opacity(0.92))
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, IslandModel.Metrics.contentInset)
        .frame(maxWidth: .infinity)
    }

    private var isError: Bool {
        if case .error = model.phase { return true }
        return false
    }
}

private struct StatusIcon: View {
    var result: InsertResult?
    var isError = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
    }

    private var symbol: String {
        if isError { return "exclamationmark.triangle.fill" }
        return result == .empty ? "mic.slash.fill" : "checkmark.circle.fill"
    }

    private var color: Color {
        if isError { return .orange }
        return result == .empty ? .white.opacity(0.5) : .green
    }
}

/// m:ss since listening began; frozen once it ends.
private struct ElapsedTime: View {
    let start: Date?
    let end: Date?

    var body: some View {
        TimelineView(.periodic(from: start ?? .now, by: 1)) { context in
            let seconds = max(0, Int((end ?? context.date).timeIntervalSince(start ?? context.date)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(end == nil ? 0.85 : 0.5))
        }
    }
}

/// Single line that keeps the newest words visible. Text starts leading-aligned; once it overflows
/// it pins to the trailing edge and fades out on the left with a gradient mask.
struct LiveTranscriptLine: View {
    let text: String
    var isFinishing: Bool
    @State private var contentWidth: CGFloat = 0

    /// Words keyed by absolute position so trimming old words never re-animates the rest.
    private var words: [(index: Int, word: String)] {
        let all = text.split(separator: " ").map(String.init)
        return Array(all.enumerated().map { ($0.offset, $0.element) }.suffix(40))
    }

    var body: some View {
        GeometryReader { geo in
            let overflows = contentWidth > geo.size.width
            HStack(spacing: 4) {
                ForEach(words, id: \.index) { item in
                    Text(item.word).transition(.wordIn)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(isFinishing ? 0.6 : 0.92))
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .frame(width: geo.size.width, height: geo.size.height, alignment: overflows ? .trailing : .leading)
            .shimmer(isFinishing)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: overflows ? .clear : .black, location: 0),
                        .init(color: .black, location: min(0.5, 28 / max(geo.size.width, 1))),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .clipped()
    }
}

/// Hover state: the full transcript plus explicit controls. Text shares the header's inset;
/// the footer controls are inset by `controlInset` to sit concentric with the bottom corners.
struct ExpandedBody: View {
    @Bindable var model: IslandModel
    private typealias Metrics = IslandModel.Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if case .error(let message) = model.phase {
                    Text(message).foregroundStyle(.orange)
                } else if model.transcript.isEmpty {
                    Text("Listening…").foregroundStyle(.white.opacity(0.4))
                } else {
                    Text(tail(of: model.transcript)).foregroundStyle(.white.opacity(0.92))
                }
            }
            .font(Font(Metrics.transcriptFont))
            .lineSpacing(Metrics.transcriptLineSpacing)
            .lineLimit(Metrics.maxTranscriptLines)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .shimmer(model.phase == .finishing)
            .padding(.horizontal, model.horizontalInset)
            .padding(.top, 2)
            .padding(.bottom, 10)

            HStack(spacing: 6) {
                Text(hint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if model.phase == .listening {
                    IslandButton(title: "Cancel", systemImage: "xmark", role: .secondary) { model.cancel() }
                    IslandButton(title: "Done", systemImage: "checkmark", role: .primary) { model.stop() }
                } else if case .error = model.phase {
                    IslandButton(title: "Dismiss", systemImage: "xmark", role: .secondary) { model.cancel() }
                }
            }
            .frame(height: Metrics.controlHeight)
            .padding(.leading, model.horizontalInset)
            .padding(.trailing, Metrics.controlInset + model.earInset)
            .padding(.bottom, Metrics.controlInset)
        }
    }

    private var hint: String {
        switch model.phase {
        case .listening: return finishHint
        case .finishing: return "Transcribing…"
        case .done(.pasted): return "Pasted into the active app"
        case .done(.copied): return "Copied · grant Accessibility to auto-paste"
        case .done(.empty): return "Nothing was heard"
        default: return ""
        }
    }

    private var finishHint: String {
        if let keys = model.settings.pushToTalkDescription { return "Press \(keys) to finish" }
        return model.settings.fallbackShortcutEnabled ? "Press \(HotKey.symbol) to finish" : "Click Done to finish"
    }

    private func tail(of text: String) -> String {
        text.count > 260 ? "…" + text.suffix(260) : text
    }
}

struct IslandButton: View {
    enum Role { case primary, secondary }

    let title: String
    let systemImage: String
    var role: Role
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .labelStyle(TightLabelStyle())
                .padding(.horizontal, 11)
                .frame(height: IslandModel.Metrics.controlHeight)
                .background(
                    Capsule().fill(role == .primary ? Color.white.opacity(isHovered ? 1 : 0.9) : Color.white.opacity(isHovered ? 0.2 : 0.12))
                )
                .foregroundStyle(role == .primary ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.fade, value: isHovered)
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9.5, weight: .bold))
            configuration.title
        }
    }
}

/// Thin white arc; the system `ProgressView` is nearly invisible on the black island.
struct Spinner: View {
    @State private var isRotating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { isRotating = true }
            }
    }
}
