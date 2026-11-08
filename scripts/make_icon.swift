// Renders the app icon into an .iconset folder. Usage: swift make_icon.swift <out.iconset>
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

    // macOS icon grid: 824/1024 body with continuous corners.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    bodyPath.fill()
    ctx.restoreGState()

    bodyPath.addClip()
    let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.86, blue: 0.52, alpha: 1),
                                       NSColor(calibratedRed: 0.02, green: 0.48, blue: 0.36, alpha: 1)])!
    gradient.draw(in: body, angle: -90)

    // Phone
    let pw = body.width * 0.36, ph = pw * 2.0
    let phone = CGRect(x: body.midX - pw / 2 - body.width * 0.08, y: body.midY - ph / 2, width: pw, height: ph)
    let phonePath = NSBezierPath(roundedRect: phone, xRadius: pw * 0.18, yRadius: pw * 0.18)
    NSColor(white: 0.08, alpha: 1).setFill()
    phonePath.fill()
    let screen = phone.insetBy(dx: pw * 0.07, dy: pw * 0.07)
    let screenGradient = NSGradient(colors: [NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.75, alpha: 1),
                                             NSColor(calibratedRed: 0.15, green: 0.65, blue: 0.85, alpha: 1)])!
    screenGradient.draw(in: NSBezierPath(roundedRect: screen, xRadius: pw * 0.12, yRadius: pw * 0.12), angle: -60)

    // Mirroring waves
    NSColor.white.setStroke()
    for i in 0..<3 {
        let r = body.width * (0.16 + CGFloat(i) * 0.1)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: CGPoint(x: phone.maxX + body.width * 0.02, y: phone.midY), radius: r,
                      startAngle: -38, endAngle: 38)
        arc.lineWidth = body.width * 0.035
        arc.lineCapStyle = .round
        NSColor.white.withAlphaComponent(1 - CGFloat(i) * 0.25).setStroke()
        arc.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
