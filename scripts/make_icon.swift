// Renders the AirDoxx app icon into an .iconset folder.
// Usage: swift make_icon.swift <out.iconset> [preview.png]
//
// Design: a rounded tile in Android green -> teal, with a dark phone behind a frosted-glass phone
// (punch-hole camera + gesture bar) - one phone mirrored onto another.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
             blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linear(_ ctx: CGContext, _ path: CGPath, _ colors: [NSColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: colors.map(\.cgColor) as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let u = s / 1024 // design units: 1024 grid

    // ---- Tile (macOS grid: 824pt body, ~185pt continuous corner) ----
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = roundedRect(tile, 186 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 28 * u, color: color(0x000000, 0.30).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1BA77A).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, tilePath, [color(0x5CF0A8), color(0x22C08A), color(0x0B8C86)],
           from: CGPoint(x: tile.midX, y: tile.maxY), to: CGPoint(x: tile.midX, y: tile.minY))
    // soft top sheen + rim
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [color(0xFFFFFF, 0.28).cgColor, color(0xFFFFFF, 0).cgColor] as CFArray,
                           locations: nil)!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: tile.midX, y: tile.maxY + 40 * u), startRadius: 0,
                           endCenter: CGPoint(x: tile.midX, y: tile.maxY + 40 * u), endRadius: 560 * u, options: [])
    ctx.restoreGState()
    ctx.addPath(tilePath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.35).cgColor)
    ctx.setLineWidth(3 * u)
    ctx.strokePath()

    // ---- Back phone (dark, upper-left) ----
    let back = CGRect(x: 318 * u, y: 320 * u, width: 290 * u, height: 486 * u)
    let backPath = roundedRect(back, 62 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 18 * u, color: color(0x003322, 0.35).cgColor)
    linear(ctx, backPath, [color(0x0D5E4B), color(0x063A33)],
           from: CGPoint(x: back.midX, y: back.maxY), to: CGPoint(x: back.midX, y: back.minY))
    ctx.restoreGState()
    linear(ctx, backPath, [color(0x0F6B55), color(0x07403A)],
           from: CGPoint(x: back.midX, y: back.maxY), to: CGPoint(x: back.midX, y: back.minY))
    ctx.addPath(backPath)
    ctx.setStrokeColor(color(0x7CF5C0, 0.25).cgColor)
    ctx.setLineWidth(2.5 * u)
    ctx.strokePath()
    // camera dot on the back phone
    ctx.setFillColor(color(0x9BFFD6, 0.35).cgColor)
    ctx.fillEllipse(in: CGRect(x: back.midX - 9 * u, y: back.maxY - 40 * u, width: 18 * u, height: 18 * u))

    // ---- Front glass phone (lower-right) ----
    let front = CGRect(x: 416 * u, y: 206 * u, width: 292 * u, height: 488 * u)
    let frontPath = roundedRect(front, 62 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16 * u), blur: 40 * u, color: color(0x003B2A, 0.45).cgColor)
    ctx.addPath(frontPath)
    ctx.setFillColor(color(0x7FE9C0, 0.55).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    // glass body
    linear(ctx, frontPath, [color(0xD6FFF0, 0.80), color(0x8FEFD0, 0.70), color(0x4FD3C4, 0.78)],
           from: CGPoint(x: front.minX, y: front.maxY), to: CGPoint(x: front.maxX, y: front.minY))
    // the back phone seen through the glass (the "mirror")
    ctx.saveGState()
    ctx.addPath(frontPath); ctx.clip()
    ctx.addPath(backPath); ctx.clip()
    linear(ctx, backPath, [color(0x1F8F78, 0.55), color(0x0E5C55, 0.55)],
           from: CGPoint(x: back.midX, y: back.maxY), to: CGPoint(x: back.midX, y: back.minY))
    ctx.restoreGState()
    // screen glow
    ctx.saveGState()
    ctx.addPath(frontPath); ctx.clip()
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xFFFFFF, 0.55).cgColor, color(0xFFFFFF, 0).cgColor] as CFArray,
                          locations: nil)!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: front.maxX - 40 * u, y: front.maxY - 30 * u), startRadius: 0,
                           endCenter: CGPoint(x: front.maxX - 40 * u, y: front.maxY - 30 * u), endRadius: 330 * u,
                           options: [])
    ctx.restoreGState()
    // rim light
    ctx.addPath(frontPath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.85).cgColor)
    ctx.setLineWidth(4 * u)
    ctx.strokePath()
    ctx.addPath(roundedRect(front.insetBy(dx: 5 * u, dy: 5 * u), 57 * u))
    ctx.setStrokeColor(color(0x0B7F6A, 0.35).cgColor)
    ctx.setLineWidth(2 * u)
    ctx.strokePath()

    // Android cues: punch-hole camera and gesture bar
    ctx.setFillColor(color(0x053B33, 0.85).cgColor)
    ctx.fillEllipse(in: CGRect(x: front.midX - 13 * u, y: front.maxY - 50 * u, width: 26 * u, height: 26 * u))
    ctx.setFillColor(color(0x5DE0FF, 0.6).cgColor)
    ctx.fillEllipse(in: CGRect(x: front.midX - 5 * u, y: front.maxY - 42 * u, width: 8 * u, height: 8 * u))
    let pill = CGRect(x: front.midX - 52 * u, y: front.minY + 30 * u, width: 104 * u, height: 12 * u)
    ctx.addPath(roundedRect(pill, 6 * u))
    ctx.setFillColor(color(0xFFFFFF, 0.95).cgColor)
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
