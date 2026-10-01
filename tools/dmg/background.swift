import AppKit

// Draws the DMG window background (640x400 points) at 1x and 2x.
// Usage: swift tools/dmg/background.swift <outdir>
// Icon centres must match tools/dmg/settings.py: Perch (160, 200), Applications (480, 200).

let W: CGFloat = 640, H: CGFloat = 400
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func draw() {
    let ctx = NSGraphicsContext.current!.cgContext
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!

    // Ground
    let ground = CGGradient(colorsSpace: cs, colors: [rgb(0x15111c).cgColor, rgb(0x09080c).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ground, start: .zero, end: CGPoint(x: 0, y: H), options: [])

    // Soft light behind the icons, same coral/violet as the site
    func glow(_ c: NSColor, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        let g = CGGradient(colorsSpace: cs, colors: [c.cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
    }
    glow(rgb(0xb58cff, 0.16), 320, 210, 300)
    glow(rgb(0xff8a6b, 0.12), 170, 230, 200)
    glow(rgb(0x608cff, 0.08), 500, 190, 200)

    // Title
    let para = NSMutableParagraphStyle(); para.alignment = .center
    func text(_ s: String, _ y: CGFloat, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para, .kern: kern]
        NSAttributedString(string: s, attributes: attrs).draw(in: CGRect(x: 0, y: y, width: W, height: 40))
    }
    text("Install Perch", 34, .systemFont(ofSize: 24, weight: .semibold), rgb(0xf4f4f6), kern: -0.4)
    text("Drag Perch into your Applications folder.", 68, .systemFont(ofSize: 13.5, weight: .regular), rgb(0xa4a4ae))

    // Name plates behind the Finder labels, mid-tone so black (light mode) and white (dark mode) labels both read
    // Finder centres a 13pt label at y = 270 for icons centred at y = 200 (measured on macOS 26)
    for (cx, w) in [(CGFloat(160), CGFloat(66)), (480, 108)] {
        let plate = NSBezierPath(roundedRect: CGRect(x: cx - w / 2, y: 259, width: w, height: 22), xRadius: 11, yRadius: 11)
        rgb(0x7a7488).setFill()
        plate.fill()
    }

    // Arrow from the app to Applications
    let grad = CGGradient(colorsSpace: cs, colors: [rgb(0xffc49e).cgColor, rgb(0xff8a6b).cgColor, rgb(0xb58cff).cgColor] as CFArray, locations: [0, 0.5, 1])!
    ctx.saveGState()
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 252, y: 200))
    path.addLine(to: CGPoint(x: 380, y: 200))
    ctx.addPath(path)
    ctx.setLineWidth(3); ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [1, 9])
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(grad, start: CGPoint(x: 252, y: 0), end: CGPoint(x: 392, y: 0), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 378, y: 189))
    head.addLine(to: CGPoint(x: 390, y: 200))
    head.addLine(to: CGPoint(x: 378, y: 211))
    ctx.addPath(head)
    ctx.setLineWidth(3); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(grad, start: CGPoint(x: 252, y: 0), end: CGPoint(x: 392, y: 0), options: [])
    ctx.restoreGState()

    // First-launch note
    let rule = NSBezierPath(rect: CGRect(x: 160, y: 322, width: 320, height: 1))
    rgb(0xffffff, 0.08).setFill(); rule.fill()
    text("First launch: open Perch once, then choose", 336, .systemFont(ofSize: 11.5), rgb(0x8a8a94))
    text("System Settings › Privacy & Security › Open Anyway.", 353, .systemFont(ofSize: 11.5, weight: .medium), rgb(0xc8c8d0))
}

for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W) * scale, pixelsHigh: Int(H) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    // flip so y grows downward, matching Finder window coordinates
    g.cgContext.translateBy(x: 0, y: H)
    g.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: g.cgContext, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    print("wrote", name)
}
