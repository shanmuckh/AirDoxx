// Renders the DMG window background (660x400 pt, 1x + 2x) for the drag-to-Applications installer.
// Usage: swift make_dmg_background.swift <out-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(scale: CGFloat) -> Data {
    let w = 660 * scale, h = 400 * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)

    // Soft white -> light grey backdrop
    NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: 0.93, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: 660, height: 400), angle: -90)

    // Title
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let title: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.black, .paragraphStyle: para, .kern: -0.3]
    ("Drag AirDoxx to Applications" as NSString).draw(in: NSRect(x: 0, y: 318, width: 660, height: 34), withAttributes: title)
    let sub: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor(white: 0.45, alpha: 1), .paragraphStyle: para]
    ("Then open it from Launchpad or Spotlight." as NSString).draw(in: NSRect(x: 0, y: 296, width: 660, height: 20), withAttributes: sub)

    // Arrow between the two icon slots (icons sit at y=190 from top -> 210 from bottom)
    let y: CGFloat = 400 - 190
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 258, y: y))
    arrow.line(to: NSPoint(x: 388, y: y))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    NSColor.black.setStroke()
    let dash: [CGFloat] = [0.5, 9]
    arrow.setLineDash(dash, count: 2, phase: 0)
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 381, y: y + 9))
    head.line(to: NSPoint(x: 392, y: y))
    head.line(to: NSPoint(x: 381, y: y - 9))
    head.lineWidth = 2.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Footer
    let foot: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(white: 0.55, alpha: 1),
        .paragraphStyle: para, .kern: 1.2]
    ("AIRDOXX · YOUR ANDROID, ON YOUR MAC" as NSString).draw(in: NSRect(x: 0, y: 26, width: 660, height: 16), withAttributes: foot)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: outDir.appendingPathComponent("background.png"))
try render(scale: 2).write(to: outDir.appendingPathComponent("background@2x.png"))
