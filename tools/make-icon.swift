// Renders the Perch app icon (1024px master) and builds Resources/AppIcon.icns.
// Usage: swift tools/make-icon.swift <repo> [island|monogram|aurora|orb|glass|eclipse|stack|neon]
//        swift tools/make-icon.swift <repo> sheet   -> build/icon-options.png (all variants side by side)
import AppKit

let S: CGFloat = 1024
var variant = "island"
func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)
    switch variant {
    case "monogram": drawMonogram(ctx)
    case "aurora": drawAurora(ctx)
    case "orb": drawOrb(ctx)
    case "glass": drawGlass(ctx)
    case "eclipse": drawEclipse(ctx)
    case "stack": drawStack(ctx)
    case "neon": drawNeon(ctx)
    default: draw(ctx)
    }
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


    // Top sheen.
    let sheen = CGGradient(colorsSpace: rgb, colors: [color(0xffffff, 0.10), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 700), options: [])
    ctx.restoreGState()
}


let rgbSpace = CGColorSpaceCreateDeviceRGB()
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
var tileCG: CGPath { NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185).cgPath }
func grad(_ hexes: [UInt32], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: rgbSpace, colors: hexes.map { color($0) } as CFArray, locations: locs)!
}
/// Shadowed tile, then `body` clipped to it, then a soft top sheen.
func tile(_ ctx: CGContext, _ top: UInt32, _ bottom: UInt32, _ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tileCG); ctx.setFillColor(color(bottom)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tileCG); ctx.clip()
    ctx.drawLinearGradient(grad([top, bottom], [0, 1]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    body()
    let sheen = CGGradient(colorsSpace: rgbSpace, colors: [color(0xffffff, 0.10), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 680), options: [])
    ctx.restoreGState()
}

/// B. Bold "P" whose bowl is a notch island with a glowing activity inside.
func drawMonogram(_ ctx: CGContext) {
    tile(ctx, 0xff8a3d, 0xe0306f) {
        let white = color(0xffffff)
        // Stem.
        ctx.addPath(NSBezierPath(roundedRect: CGRect(x: 300, y: 230, width: 130, height: 560), xRadius: 65, yRadius: 65).cgPath)
        ctx.setFillColor(white); ctx.fillPath()
        // Bowl: a thick rounded ring.
        let outer = CGRect(x: 300, y: 450, width: 440, height: 340)
        ctx.addPath(NSBezierPath(roundedRect: outer, xRadius: 170, yRadius: 170).cgPath)
        ctx.setFillColor(white); ctx.fillPath()
        // Counter = black notch island.
        let island = CGRect(x: 405, y: 545, width: 240, height: 150)
        ctx.addPath(NSBezierPath(roundedRect: island, xRadius: 75, yRadius: 75).cgPath)
        ctx.setFillColor(color(0x0b0c16)); ctx.fillPath()
        // Live dot inside.
        ctx.addEllipse(in: CGRect(x: 565, y: 595, width: 50, height: 50))
        ctx.setFillColor(color(0x3ddc84)); ctx.fillPath()
    }
}

/// C. Screen top edge: the notch expanding into a live activity, aurora light spilling below.
func drawAurora(_ ctx: CGContext) {
    tile(ctx, 0x0e1020, 0x05060c) {
        // Aurora bands.
        for (hex, cx, cy, r, a) in [(0x7b5cff as UInt32, 380.0, 520.0, 360.0, 0.55), (0x2de2e6, 640.0, 470.0, 320.0, 0.45),
                                    (0xff3d7f, 520.0, 360.0, 300.0, 0.35)] {
            let g = CGGradient(colorsSpace: rgbSpace, colors: [color(hex, a), color(hex, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                                   endCenter: CGPoint(x: cx, y: cy), endRadius: r, options: [])
        }
        // Menu-bar edge and the expanded notch hanging from it (flat top, round bottom).
        let w: CGFloat = 470, h: CGFloat = 230, top: CGFloat = 924
        let x = 512 - w / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x - 40, y: top))
        path.addQuadCurve(to: CGPoint(x: x, y: top - 40), control: CGPoint(x: x, y: top))
        path.addLine(to: CGPoint(x: x, y: top - h + 80))
        path.addQuadCurve(to: CGPoint(x: x + 80, y: top - h), control: CGPoint(x: x, y: top - h))
        path.addLine(to: CGPoint(x: x + w - 80, y: top - h))
        path.addQuadCurve(to: CGPoint(x: x + w, y: top - h + 80), control: CGPoint(x: x + w, y: top - h))
        path.addLine(to: CGPoint(x: x + w, y: top - 40))
        path.addQuadCurve(to: CGPoint(x: x + w + 40, y: top), control: CGPoint(x: x + w, y: top))
        path.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 50, color: color(0x000000, 0.7))
        ctx.addPath(path); ctx.setFillColor(color(0x000000)); ctx.fillPath()
        ctx.restoreGState()
        // Inside: artwork tile + progress bar.
        let art = CGRect(x: x + 50, y: top - 170, width: 100, height: 100)
        ctx.saveGState()
        ctx.addPath(NSBezierPath(roundedRect: art, xRadius: 26, yRadius: 26).cgPath); ctx.clip()
        ctx.drawLinearGradient(grad([0x2de2e6, 0x7b5cff, 0xff3d7f], [0, 0.5, 1]),
                               start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: [])
        ctx.restoreGState()
        ctx.addPath(NSBezierPath(roundedRect: CGRect(x: x + 180, y: top - 105, width: 230, height: 22), xRadius: 11, yRadius: 11).cgPath)
        ctx.setFillColor(color(0xffffff, 0.9)); ctx.fillPath()
        ctx.addPath(NSBezierPath(roundedRect: CGRect(x: x + 180, y: top - 150, width: 150, height: 18), xRadius: 9, yRadius: 9).cgPath)
        ctx.setFillColor(color(0xffffff, 0.45)); ctx.fillPath()
    }
}

/// D. Minimal perch: a glowing orb resting on a thin line — the "bird" as pure light.
func drawOrb(_ ctx: CGContext) {
    tile(ctx, 0x1c1e2e, 0x08090f) {
        let c = CGPoint(x: 512, y: 560)
        let halo = CGGradient(colorsSpace: rgbSpace, colors: [color(0xffb347, 0.55), color(0xff3d7f, 0.18), color(0xff3d7f, 0)] as CFArray,
                              locations: [0, 0.5, 1])!
        ctx.drawRadialGradient(halo, startCenter: c, startRadius: 0, endCenter: c, endRadius: 360, options: [])
        // The perch line.
        ctx.addPath(NSBezierPath(roundedRect: CGRect(x: 230, y: 400, width: 564, height: 26), xRadius: 13, yRadius: 13).cgPath)
        ctx.setFillColor(color(0xffffff, 0.92)); ctx.fillPath()
        // Orb sitting on it.
        let orb = CGRect(x: c.x - 150, y: 426, width: 300, height: 300)
        ctx.saveGState()
        ctx.addEllipse(in: orb); ctx.clip()
        ctx.drawLinearGradient(grad([0xffd166, 0xff7a45, 0xff3d7f], [0, 0.5, 1]),
                               start: CGPoint(x: orb.minX, y: orb.maxY), end: CGPoint(x: orb.maxX, y: orb.minY), options: [])
        let spec = CGGradient(colorsSpace: rgbSpace, colors: [color(0xffffff, 0.55), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(spec, startCenter: CGPoint(x: orb.midX - 60, y: orb.maxY - 70), startRadius: 0,
                               endCenter: CGPoint(x: orb.midX - 60, y: orb.maxY - 70), endRadius: 130, options: [])
        ctx.restoreGState()
    }
}

func pill(_ r: CGRect) -> CGPath { NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).cgPath }
func blob(_ ctx: CGContext, _ hex: UInt32, _ c: CGPoint, _ r: CGFloat, _ a: CGFloat) {
    let g = CGGradient(colorsSpace: rgbSpace, colors: [color(hex, a), color(hex, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}

/// E. Liquid glass: light frosted tile, color blobs behind, a black notch pill on top.
func drawGlass(_ ctx: CGContext) {
    tile(ctx, 0xf4f1ff, 0xd9d4f2) {
        blob(ctx, 0xff7a45, CGPoint(x: 360, y: 420), 330, 0.85)
        blob(ctx, 0x7b5cff, CGPoint(x: 680, y: 380), 330, 0.8)
        blob(ctx, 0x2de2e6, CGPoint(x: 520, y: 250), 260, 0.6)
        // Frosted pane.
        let pane = CGRect(x: 170, y: 170, width: 684, height: 460)
        ctx.addPath(NSBezierPath(roundedRect: pane, xRadius: 120, yRadius: 120).cgPath)
        ctx.setFillColor(color(0xffffff, 0.35)); ctx.fillPath()
        ctx.addPath(NSBezierPath(roundedRect: pane.insetBy(dx: 2, dy: 2), xRadius: 118, yRadius: 118).cgPath)
        ctx.setStrokeColor(color(0xffffff, 0.8)); ctx.setLineWidth(4); ctx.strokePath()
        // Notch pill.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.35))
        ctx.addPath(pill(CGRect(x: 292, y: 690, width: 440, height: 130))); ctx.setFillColor(color(0x000000)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addEllipse(in: CGRect(x: 640, y: 730, width: 50, height: 50)); ctx.setFillColor(color(0x3ddc84)); ctx.fillPath()
    }
}

/// F. Eclipse: black notch pill with a corona of colored light around its rim.
func drawEclipse(_ ctx: CGContext) {
    tile(ctx, 0x0a0a12, 0x000000) {
        let r = CGRect(x: 212, y: 412, width: 600, height: 200)
        for (hex, blur, a) in [(0xff3d7f as UInt32, 90.0, 0.9), (0xffb347, 45.0, 0.9), (0xffffff, 12.0, 0.9)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: blur, color: color(hex, a))
            ctx.addPath(pill(r)); ctx.setFillColor(color(0x000000)); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.addPath(pill(r)); ctx.setFillColor(color(0x000000)); ctx.fillPath()
    }
}

/// G. Stack: live activities stacked like cards, the top one is the notch.
func drawStack(_ ctx: CGContext) {
    tile(ctx, 0x3a2d7a, 0x120e2a) {
        let cards: [(CGRect, UInt32, CGFloat)] = [
            (CGRect(x: 312, y: 250, width: 400, height: 110), 0xff3d7f, 0.55),
            (CGRect(x: 262, y: 350, width: 500, height: 130), 0xff7a45, 0.8),
            (CGRect(x: 212, y: 470, width: 600, height: 170), 0x000000, 1),
        ]
        for (r, hex, a) in cards {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.45))
            ctx.addPath(pill(r)); ctx.setFillColor(color(hex, a)); ctx.fillPath()
            ctx.restoreGState()
        }
        // Content on the top card.
        let art = CGRect(x: 262, y: 505, width: 100, height: 100)
        ctx.saveGState()
        ctx.addPath(NSBezierPath(roundedRect: art, xRadius: 50, yRadius: 50).cgPath); ctx.clip()
        ctx.drawLinearGradient(grad([0xffd166, 0xff3d7f], [0, 1]), start: CGPoint(x: art.minX, y: art.maxY),
                               end: CGPoint(x: art.maxX, y: art.minY), options: [])
        ctx.restoreGState()
        ctx.addPath(pill(CGRect(x: 395, y: 565, width: 300, height: 26))); ctx.setFillColor(color(0xffffff, 0.92)); ctx.fillPath()
        ctx.addPath(pill(CGRect(x: 395, y: 520, width: 190, height: 22))); ctx.setFillColor(color(0xffffff, 0.45)); ctx.fillPath()
    }
}

/// H. Neon: the P as a glowing line, its bowl shaped like the notch.
func drawNeon(_ ctx: CGContext) {
    tile(ctx, 0x14102a, 0x06050e) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 360, y: 250))
        p.addLine(to: CGPoint(x: 360, y: 770))
        p.addLine(to: CGPoint(x: 560, y: 770))
        p.addArc(center: CGPoint(x: 560, y: 650), radius: 120, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: 360, y: 530))
        for (hex, blur, w) in [(0xff3d7f as UInt32, 60.0, 34.0), (0xff7a45, 26.0, 26.0), (0xffffff, 6.0, 16.0)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: blur, color: color(hex, 1))
            ctx.addPath(p); ctx.setStrokeColor(color(hex == 0xffffff ? 0xfff4ec : hex)); ctx.setLineWidth(w)
            ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.addEllipse(in: CGRect(x: 530, y: 620, width: 60, height: 60)); ctx.setFillColor(color(0x3ddc84)); ctx.fillPath()
    }
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

let args = CommandLine.arguments
let root = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let choice = args.count > 2 ? args[2] : "island"
if choice == "sheet" || choice == "sheet2" {
    let names = choice == "sheet" ? ["island", "monogram", "aurora", "orb"] : ["glass", "eclipse", "stack", "neon"]
    let letters = choice == "sheet" ? ["A", "B", "C", "D"] : ["E", "F", "G", "H"]
    let cell = 512, pad = 40
    let sheet = NSImage(size: NSSize(width: names.count * (cell + pad) + pad, height: cell + 2 * pad + 40))
    sheet.lockFocus()
    NSColor(white: 0.93, alpha: 1).setFill(); NSRect(origin: .zero, size: sheet.size).fill()
    for (i, n) in names.enumerated() {
        variant = n
        let img = NSImage(size: NSSize(width: cell, height: cell)); img.addRepresentation(render(cell))
        let x = CGFloat(pad + i * (cell + pad))
        img.draw(in: NSRect(x: x, y: CGFloat(pad + 40), width: CGFloat(cell), height: CGFloat(cell)))
        let label = "\(letters[i]). \(n.capitalized)" as NSString
        label.draw(at: NSPoint(x: x + 20, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold)])
    }
    sheet.unlockFocus()
    let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("build/icon-\(choice).png"))
    print("wrote build/icon-\(choice).png")
    exit(0)
}
variant = choice
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
