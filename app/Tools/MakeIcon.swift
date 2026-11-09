// Renders the app icon into an .iconset folder:  swift Tools/MakeIcon.swift OUT.iconset
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824 pt body, centered, continuous corners
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // frosted glass body
    NSGradient(colors: [NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.0, alpha: 1),
                        NSColor(calibratedRed: 0.80, green: 0.85, blue: 0.93, alpha: 1)])!
        .draw(in: shape, angle: -90)
    // top highlight
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.75), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.9).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
    rim.lineWidth = 6
    rim.stroke()

    // printer glyph, drawn from plain shapes (SF Symbols may not be used in app icons)
    let ink = NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.28, alpha: 1)
    let accent = NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.95, alpha: 1)
    let paperStroke = NSColor(calibratedRed: 0.70, green: 0.75, blue: 0.84, alpha: 1)
    // sheet waiting in the input tray
    let sheetIn = NSBezierPath(roundedRect: NSRect(x: 352, y: 560, width: 320, height: 190), xRadius: 18, yRadius: 18)
    NSColor.white.setFill(); sheetIn.fill()
    paperStroke.setStroke(); sheetIn.lineWidth = 8; sheetIn.stroke()
    // body
    ink.setFill()
    NSBezierPath(roundedRect: NSRect(x: 232, y: 360, width: 560, height: 250), xRadius: 56, yRadius: 56).fill()
    // status light
    accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: 680, y: 530, width: 46, height: 46)).fill()
    // printed sheet coming out, with text lines
    let sheetOut = NSBezierPath(roundedRect: NSRect(x: 332, y: 250, width: 360, height: 200), xRadius: 18, yRadius: 18)
    NSColor.white.setFill(); sheetOut.fill()
    paperStroke.setStroke(); sheetOut.lineWidth = 8; sheetOut.stroke()
    accent.setFill()
    for (i, w) in [250, 210, 230].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 387, y: 380 - CGFloat(i) * 46, width: CGFloat(w), height: 20),
                     xRadius: 10, yRadius: 10).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        let png = render(pt * scale).representation(using: .png, properties: [:])!
        try! png.write(to: out.appendingPathComponent(name))
    }
}
