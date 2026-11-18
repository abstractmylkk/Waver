// Renders Waver's app icon into an .iconset folder. Usage: swift make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with continuous corners
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    NSColor(red: 0.07, green: 0.075, blue: 0.085, alpha: 1).setFill()
    shape.fill()
    ctx.restoreGState()

    ctx.saveGState()
    shape.addClip()
    NSGradient(colors: [NSColor(red: 0.16, green: 0.17, blue: 0.19, alpha: 1),
                        NSColor(red: 0.06, green: 0.065, blue: 0.075, alpha: 1)])!.draw(in: body, angle: -90)

    // Waveform
    let low = NSColor(red: 1.00, green: 0.33, blue: 0.28, alpha: 1)
    let mid = NSColor(red: 0.98, green: 0.80, blue: 0.30, alpha: 1)
    let high = NSColor(red: 0.33, green: 0.70, blue: 1.00, alpha: 1)
    let bars = 26
    let area = body.insetBy(dx: body.width * 0.13, dy: body.height * 0.2)
    let w = area.width / CGFloat(bars)
    let centre = body.midY
    for i in 0..<bars {
        let t = Double(i) / Double(bars - 1)
        let env = 0.25 + 0.75 * pow(sin(.pi * t), 0.8) * (0.62 + 0.38 * sin(t * 19.0 + 1.3) * cos(t * 7.0))
        let h = area.height / 2 * CGFloat(min(1, max(0.12, env)))
        let color: NSColor = t < 0.4 ? low.blended(withFraction: CGFloat(t / 0.4), of: mid)!
                                     : mid.blended(withFraction: CGFloat((t - 0.4) / 0.6), of: high)!
        let rect = CGRect(x: area.minX + CGFloat(i) * w + w * 0.18, y: centre - h, width: w * 0.64, height: 2 * h)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: w * 0.32, yRadius: w * 0.32).fill()
    }
    // Target line
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(rect: CGRect(x: area.minX - w * 0.2, y: centre - s * 0.003, width: area.width + w * 0.4, height: s * 0.006)).fill()

    // Top sheen + hairline
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    ctx.restoreGState()
    NSColor.white.withAlphaComponent(0.1).setStroke()
    shape.lineWidth = max(1, s / 512)
    shape.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
