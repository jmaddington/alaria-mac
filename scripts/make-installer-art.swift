// Renders the DMG window background for Talaria: swift scripts/make-installer-art.swift build/art
// Adapted from Murmur's installer art. Window is 660x420; icons sit at (178,196) and (482,196) from top-left.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func png(_ w: Int, _ h: Int, scale: Int, _ draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [.compressionFactor: 1])!
}

// Talaria palette (matches the app icon gradient and Theme.accent).
let indigo = NSColor(srgbRed: 0.36, green: 0.39, blue: 0.96, alpha: 1)
let deep = NSColor(srgbRed: 0.20, green: 0.17, blue: 0.55, alpha: 1)
let teal = NSColor(srgbRed: 0.35, green: 0.90, blue: 0.95, alpha: 1)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, center: CGPoint) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
    let a = NSAttributedString(string: s, attributes: attrs)
    let sz = a.size()
    a.draw(in: CGRect(x: center.x - 300, y: center.y - sz.height / 2, width: 600, height: sz.height))
}

func dmg(_ r: CGRect) {
    NSColor(srgbRed: 0.985, green: 0.985, blue: 1.0, alpha: 1).setFill(); r.fill()
    // Soft indigo-to-teal aurora along the top.
    NSGradient(colors: [indigo.withAlphaComponent(0.18), deep.withAlphaComponent(0.10), teal.withAlphaComponent(0.16)])!
        .draw(in: NSBezierPath(ovalIn: CGRect(x: -120, y: r.height - 170, width: r.width + 240, height: 300)), angle: 0)
    text("Install Talaria", size: 22, weight: .bold, color: NSColor(white: 0.1, alpha: 1), center: CGPoint(x: r.midX, y: r.height - 58))
    text("Drag the icon into Applications", size: 13, weight: .regular, color: NSColor(white: 0.45, alpha: 1), center: CGPoint(x: r.midX, y: r.height - 84))
    let y = r.height - 196
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: 262, y: y)); arrow.line(to: CGPoint(x: 392, y: y))
    arrow.lineWidth = 3; arrow.lineCapStyle = .round
    let dash: [CGFloat] = [0.1, 9]; arrow.setLineDash(dash, count: 2, phase: 0)
    indigo.withAlphaComponent(0.55).setStroke(); arrow.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: 386, y: y + 9)); head.line(to: CGPoint(x: 398, y: y)); head.line(to: CGPoint(x: 386, y: y - 9))
    head.lineWidth = 3; head.lineCapStyle = .round; head.lineJoinStyle = .round; head.stroke()
    text("A Mac client for Hermes Agent", size: 11.5, weight: .medium, color: NSColor(white: 0.55, alpha: 1), center: CGPoint(x: r.midX, y: 38))
}

try! png(660, 420, scale: 1, dmg).write(to: URL(fileURLWithPath: "\(out)/dmg-background.png"))
try! png(660, 420, scale: 2, dmg).write(to: URL(fileURLWithPath: "\(out)/dmg-background@2x.png"))
