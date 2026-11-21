// Renders the Hermes app icon into an .iconset: swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

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
    if let sym = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: s * 0.36, weight: .semibold)) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        let w = tinted.size.width, h = tinted.size.height
        tinted.draw(in: NSRect(x: (s - w) / 2 - s * 0.01, y: (s - h) / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
