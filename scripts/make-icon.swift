// Renders the app icon: the island itself (red dot + waveform) on a dark macOS squircle.
// Usage: swift scripts/make-icon.swift <output.iconset dir>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
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
    NSGradient(colors: [
        NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.19, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 1),
    ])!.draw(in: body, angle: -90)

    // Soft glow behind the island.
    let glow = NSGradient(colors: [
        NSColor(calibratedRed: 1, green: 0.3, blue: 0.25, alpha: 0.22),
        NSColor(calibratedRed: 1, green: 0.3, blue: 0.25, alpha: 0),
    ])!
    glow.draw(fromCenter: CGPoint(x: 512 * s, y: 512 * s), radius: 0,
              toCenter: CGPoint(x: 512 * s, y: 512 * s), radius: 420 * s, options: [])

    // The island: a black capsule with a hairline edge.
    let island = CGRect(x: 212 * s, y: 432 * s, width: 600 * s, height: 160 * s)
    let capsule = NSBezierPath(roundedRect: island, xRadius: 80 * s, yRadius: 80 * s)
    NSColor.black.setFill()
    capsule.fill()
    NSColor.white.withAlphaComponent(0.12).setStroke()
    capsule.lineWidth = 3 * s
    capsule.stroke()

    // Recording dot (concentric with the capsule's left end).
    let dot = CGRect(x: (292 - 30) * s, y: (512 - 30) * s, width: 60 * s, height: 60 * s)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30 * s, color: NSColor(calibratedRed: 1, green: 0.27, blue: 0.23, alpha: 0.9).cgColor)
    NSColor(calibratedRed: 1, green: 0.27, blue: 0.23, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot).fill()
    ctx.restoreGState()

    // Waveform bars.
    let heights: [CGFloat] = [44, 84, 64, 104, 56, 76]
    let barWidth: CGFloat = 22, gap: CGFloat = 18
    var x = (732 - (CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap)) * s
    NSColor.white.setFill()
    for h in heights {
        let bar = CGRect(x: x, y: (512 - h / 2) * s, width: barWidth * s, height: h * s)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2 * s, yRadius: barWidth / 2 * s).fill()
        x += (barWidth + gap) * s
    }

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
