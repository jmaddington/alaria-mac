// Renders the Talaria app icon into an .iconset: swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// The Talaria mark: four tapered feathers sweeping up and back from a heel pivot, longest on top (a winged-sandal
/// wing). Unit coordinates (y up) inside `r`. Keep in sync with WingMark in Theme.swift.
func wingFeathers(in r: NSRect) -> [NSBezierPath] {
    let pivot = NSPoint(x: r.minX + 0.80 * r.width, y: r.minY + 0.10 * r.height)
    // (angle in degrees, length, width) back (lowest) to front (leading edge on top).
    let specs: [(CGFloat, CGFloat, CGFloat)] = [(170, 0.50, 0.15), (150, 0.66, 0.16), (129, 0.80, 0.17), (108, 0.90, 0.18)]
    return specs.map { deg, len, w in
        let L = len * r.width, W = w * r.width, h = W / 2
        // Points along +x; rounded root, tip tapering and curling toward +y (which ends up "up" after rotation).
        let f = NSBezierPath()
        f.move(to: NSPoint(x: 0, y: -h))
        f.line(to: NSPoint(x: L * 0.62, y: -h))
        f.curve(to: NSPoint(x: L, y: h * 0.55), controlPoint1: NSPoint(x: L * 0.9, y: -h), controlPoint2: NSPoint(x: L, y: -h * 0.2))
        f.curve(to: NSPoint(x: L * 0.55, y: h), controlPoint1: NSPoint(x: L * 0.97, y: h), controlPoint2: NSPoint(x: L * 0.8, y: h))
        f.line(to: NSPoint(x: 0, y: h))
        f.appendArc(withCenter: .zero, radius: h, startAngle: 90, endAngle: 270)
        f.close()
        var t = AffineTransform(translationByX: pivot.x, byY: pivot.y)
        t.rotate(byDegrees: deg)
        t.scale(x: 1, y: -1) // curl the tips upward-back for feathers pointing left
        f.transform(using: t)
        return f
    }
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let shadow = NSShadow(); shadow.shadowBlurRadius = s * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.set()
    NSGradient(colors: [NSColor(red: 0.45, green: 0.48, blue: 1.0, alpha: 1), NSColor(red: 0.20, green: 0.17, blue: 0.55, alpha: 1)])!
        .draw(in: path, angle: -60)
    NSShadow().set()
    // Soft orb glow in the lower right: a nod to voice mode.
    NSGraphicsContext.current!.saveGraphicsState()
    path.addClip()
    let glow = NSPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY + rect.height * 0.12)
    NSGradient(colors: [NSColor(red: 0.35, green: 0.9, blue: 0.95, alpha: 0.6), NSColor(red: 0.35, green: 0.9, blue: 0.95, alpha: 0)])!
        .draw(fromCenter: glow, radius: 0, toCenter: glow, radius: rect.width * 0.62, options: [])
    NSGraphicsContext.current!.restoreGraphicsState()
    // The mark: a three-feather wing (Talaria, Hermes' winged sandals). Unit coords, y up; keep in sync with WingShape.
    // Draw back to front; each nearer feather first cuts a thin gap (destinationOut) so the three read as separate.
    let feathers = wingFeathers(in: NSRect(x: s * 0.215, y: s * 0.24, width: s * 0.52, height: s * 0.52))
    let ctx = NSGraphicsContext.current!
    ctx.saveGraphicsState()
    let layer = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        for (i, f) in feathers.enumerated().reversed() {
            if i < feathers.count - 1 {
                NSGraphicsContext.current!.compositingOperation = .destinationOut
                f.lineWidth = max(1, s * 0.03); NSColor.black.setStroke(); f.stroke()
                NSGraphicsContext.current!.compositingOperation = .sourceOver
            }
            NSColor.white.setFill(); f.fill()
        }
        return true
    }
    layer.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    ctx.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
