import AppKit

// 1200x630 social preview: icon + "Perch" + tagline over the Home screenshot, on near-black.
// Usage: swift og.swift <icon.png> <home.png> <out.png>
let a = CommandLine.arguments
let icon = NSImage(contentsOfFile: a[1])!
let shot = NSImage(contentsOfFile: a[2])!
let W = 1200, H = 630

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background: black with a faint warm glow behind the screenshot.
NSColor.black.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
let glow = NSGradient(colors: [NSColor(red: 0.55, green: 0.30, blue: 0.75, alpha: 0.35), .clear])!
glow.draw(fromCenter: NSPoint(x: 600, y: 170), radius: 0, toCenter: NSPoint(x: 600, y: 170), radius: 520, options: [])

// Header: icon + wordmark + tagline, centered as a group.
let title = NSAttributedString(string: "Perch", attributes: [
    .font: NSFont.systemFont(ofSize: 76, weight: .bold), .foregroundColor: NSColor.white])
let tag = NSAttributedString(string: "Your notch, alive.", attributes: [
    .font: NSFont.systemFont(ofSize: 34, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.62)])
let iconSide: CGFloat = 112, gap: CGFloat = 28
let textW = max(title.size().width, tag.size().width)
let groupW = iconSide + gap + textW
let x0 = (CGFloat(W) - groupW) / 2
let top: CGFloat = CGFloat(H) - 56
icon.draw(in: NSRect(x: x0, y: top - iconSide, width: iconSide, height: iconSide))
title.draw(at: NSPoint(x: x0 + iconSide + gap, y: top - 82))
tag.draw(at: NSPoint(x: x0 + iconSide + gap + 3, y: top - 124))

// Screenshot (2000x480 → 1000x240), rounded, with a hairline border.
let sw: CGFloat = 1040, sh = sw * shot.size.height / shot.size.width
let sr = NSRect(x: (CGFloat(W) - sw) / 2, y: 48, width: sw, height: sh)
ctx.saveGState()
let clip = NSBezierPath(roundedRect: sr, xRadius: 18, yRadius: 18)
clip.addClip()
shot.draw(in: sr)
ctx.restoreGState()
NSColor(white: 1, alpha: 0.14).setStroke()
let border = NSBezierPath(roundedRect: sr.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18)
border.lineWidth = 1; border.stroke()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
print("wrote", a[3], W, "x", H)
