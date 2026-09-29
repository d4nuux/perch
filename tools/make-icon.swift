// Renders the Perch app icon (1024px master) and builds Resources/AppIcon.icns.
// Usage: swift tools/make-icon.swift
import AppKit

let S: CGFloat = 1024
func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func draw(_ ctx: CGContext) {
    let rgb = CGColorSpaceCreateDeviceRGB()
    // macOS icon grid: 824pt tile centered in 1024 with continuous corners.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).cgPath

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(color(0x10121f)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    // Background: deep night gradient.
    let bg = CGGradient(colorsSpace: rgb, colors: [color(0x2a2f5c), color(0x0b0c16)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Island geometry: hangs from the tile's top edge.
    let island = CGRect(x: 232, y: 465, width: 560, height: 190)
    // Warm glow beneath the island.
    let glow = CGGradient(colorsSpace: rgb, colors: [color(0xff7a45, 0.75), color(0xff3d7f, 0.35), color(0xff3d7f, 0)] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 465), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 405), endRadius: 430, options: [])
    // Island body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 40, color: color(0x000000, 0.6))
    ctx.addPath(NSBezierPath(roundedRect: island, xRadius: 95, yRadius: 95).cgPath)
    ctx.setFillColor(color(0x000000)); ctx.fillPath()
    ctx.restoreGState()
    // Faint rim so it reads on the dark tile.
    ctx.addPath(NSBezierPath(roundedRect: island.insetBy(dx: 1.5, dy: 1.5), xRadius: 94, yRadius: 94).cgPath)
    ctx.setStrokeColor(color(0xffffff, 0.10)); ctx.setLineWidth(3); ctx.strokePath()

    // Album dot (left).
    let dot = CGRect(x: 292, y: 500, width: 120, height: 120)
    ctx.saveGState()
    ctx.addPath(NSBezierPath(roundedRect: dot, xRadius: 34, yRadius: 34).cgPath); ctx.clip()
    let art = CGGradient(colorsSpace: rgb, colors: [color(0xffb347), color(0xff3d7f), color(0x7b5cff)] as CFArray,
                         locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(art, start: CGPoint(x: dot.minX, y: dot.maxY), end: CGPoint(x: dot.maxX, y: dot.minY), options: [])
    ctx.restoreGState()

    // Waveform (right).
    let heights: [CGFloat] = [46, 92, 128, 74, 108, 56]
    for (i, h) in heights.enumerated() {
        let x = 540 + CGFloat(i) * 36
        let r = CGRect(x: x, y: 560 - h / 2, width: 20, height: h)
        ctx.addPath(NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).cgPath)
    }
    ctx.setFillColor(color(0xffffff, 0.92)); ctx.fillPath()

    // The perched bird: a small round bird sitting on the island's top-right shoulder.
    drawBird(ctx, at: CGPoint(x: 700, y: 655))

    // Top sheen.
    let sheen = CGGradient(colorsSpace: rgb, colors: [color(0xffffff, 0.10), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 700), options: [])
    ctx.restoreGState()
}

func drawBird(_ ctx: CGContext, at foot: CGPoint) {
    let body = color(0xffffff)
    ctx.saveGState()
    ctx.translateBy(x: foot.x, y: foot.y)
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: color(0x000000, 0.4))
    // Tail.
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: -38, y: 34)); tail.addLine(to: CGPoint(x: -92, y: 22)); tail.addLine(to: CGPoint(x: -44, y: 62))
    tail.closeSubpath()
    ctx.addPath(tail)
    // Body (egg) and head.
    ctx.addEllipse(in: CGRect(x: -58, y: 8, width: 104, height: 84))
    ctx.addEllipse(in: CGRect(x: 4, y: 58, width: 62, height: 62))
    ctx.setFillColor(body); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.translateBy(x: foot.x, y: foot.y)
    // Beak.
    let beak = CGMutablePath()
    beak.move(to: CGPoint(x: 62, y: 96)); beak.addLine(to: CGPoint(x: 90, y: 88)); beak.addLine(to: CGPoint(x: 62, y: 80))
    beak.closeSubpath()
    ctx.addPath(beak); ctx.setFillColor(color(0xffa53d)); ctx.fillPath()
    // Eye.
    ctx.addEllipse(in: CGRect(x: 38, y: 88, width: 12, height: 12))
    ctx.setFillColor(color(0x0b0c16)); ctx.fillPath()
    // Wing.
    ctx.addEllipse(in: CGRect(x: -34, y: 26, width: 58, height: 36))
    ctx.setFillColor(color(0xdfe3f0)); ctx.fillPath()
    // Legs down to the island edge.
    ctx.setStrokeColor(color(0xffa53d)); ctx.setLineWidth(6); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: -10, y: 12)); ctx.addLine(to: CGPoint(x: -14, y: 0))
    ctx.move(to: CGPoint(x: 12, y: 12)); ctx.addLine(to: CGPoint(x: 14, y: 0))
    ctx.strokePath()
    ctx.restoreGState()
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try! render(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
