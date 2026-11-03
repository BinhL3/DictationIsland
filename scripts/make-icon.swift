// Renders the app icon: white audio waves on a squircle fading from black to blue.
// Usage: swift scripts/make-icon.swift <output.iconset dir>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
/// "christmas" adds snowflakes behind the waves; "standard" is the plain icon.
let theme = ProcessInfo.processInfo.environment["ICON_THEME"] ?? "christmas"
let festive = theme == "christmas"
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // macOS icon grid: 824pt body inset 100pt, continuous corners.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    squircle.fill()
    ctx.restoreGState()

    squircle.addClip()
    // Black at the top fading to blue at the bottom.
    NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.01, green: 0.01, blue: 0.03, alpha: 1), 0.0),
        (NSColor(calibratedRed: 0.02, green: 0.07, blue: 0.24, alpha: 1), 0.45),
        (NSColor(calibratedRed: 0.08, green: 0.36, blue: 0.98, alpha: 1), 1.0)
    )!.draw(in: body, angle: -90)

    // A faint blue glow under the waves.
    NSGradient(colors: [
        NSColor(calibratedRed: 0.25, green: 0.55, blue: 1, alpha: 0.35),
        NSColor(calibratedRed: 0.25, green: 0.55, blue: 1, alpha: 0),
    ])!.draw(fromCenter: CGPoint(x: 512 * s, y: 470 * s), radius: 0,
             toCenter: CGPoint(x: 512 * s, y: 470 * s), radius: 380 * s, options: [])

    if festive {
        // Snowflakes behind the waves: six arms with little side branches, in the open space.
        let flakes: [(x: CGFloat, y: CGFloat, size: CGFloat, alpha: CGFloat)] = [
            (190, 820, 46, 0.85), (330, 760, 26, 0.6), (560, 860, 30, 0.7), (735, 800, 40, 0.8),
            (860, 700, 24, 0.55), (165, 600, 22, 0.5), (882, 430, 30, 0.7), (160, 330, 34, 0.7),
            (300, 200, 28, 0.6), (470, 165, 22, 0.5), (650, 215, 36, 0.75), (820, 250, 24, 0.55),
            (125, 470, 16, 0.4),
        ]
        for flake in flakes {
            let path = NSBezierPath()
            let arm = flake.size * s, center = CGPoint(x: flake.x * s, y: flake.y * s)
            for i in 0..<6 {
                let angle = CGFloat(i) * .pi / 3 + .pi / 2
                let tip = CGPoint(x: center.x + arm * cos(angle), y: center.y + arm * sin(angle))
                path.move(to: center)
                path.line(to: tip)
                // Two short branches two-thirds of the way out.
                let mid = CGPoint(x: center.x + arm * 0.62 * cos(angle), y: center.y + arm * 0.62 * sin(angle))
                for side in [-1.0, 1.0] as [CGFloat] {
                    let branch = angle + side * .pi / 4
                    path.move(to: mid)
                    path.line(to: CGPoint(x: mid.x + arm * 0.32 * cos(branch), y: mid.y + arm * 0.32 * sin(branch)))
                }
            }
            path.lineWidth = max(1, flake.size * 0.13 * s)
            path.lineCapStyle = .round
            NSColor.white.withAlphaComponent(flake.alpha).setStroke()
            path.stroke()
        }
    }

    // Audio waves: rounded bars with an uneven, speech-like rhythm (not a symmetric pyramid).
    // Few and thick so they still read at 16 px.
    let heights: [CGFloat] = [170, 390, 250, 610, 330, 480, 200]
    let barWidth: CGFloat = 62, gap: CGFloat = 34
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = (512 - total / 2) * s
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 36 * s, color: NSColor(calibratedRed: 0.35, green: 0.65, blue: 1, alpha: 0.8).cgColor)
    for h in heights {
        let bar = CGRect(x: x, y: (512 - h / 2) * s, width: barWidth * s, height: h * s)
        let path = NSBezierPath(roundedRect: bar, xRadius: barWidth / 2 * s, yRadius: barWidth / 2 * s)
        NSGradient(colors: [NSColor.white, NSColor(calibratedRed: 0.82, green: 0.9, blue: 1, alpha: 1)])!
            .draw(in: path, angle: -90)
        x += (barWidth + gap) * s
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: pixels).representation(using: .png, properties: [:])!
        try data.write(to: output.appendingPathComponent(name))
    }
}
print("Wrote \(output.path)")
