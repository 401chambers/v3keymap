// Draws the app icon (a keycap on a light rounded square lit by pink, cyan and violet colour, with a glass shine) and writes Resources/AppIcon.icns.
// usage: swiftc scripts/make-icon.swift -o make-icon && ./make-icon <output.icns> [preview.png]
import AppKit

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

func drawIcon(into rect: NSRect) {
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 184, yRadius: 184)
    NSGraphicsContext.saveGraphicsState()
    body.addClip()

    // Background
    NSGradient(colors: [color(0.95, 0.95, 1.0), color(0.78, 0.80, 0.97)])!.draw(in: body.bounds, angle: -90)

    // Coloured light pooling in the corners of the squircle
    func glow(_ c: NSColor, _ center: NSPoint, _ radius: CGFloat) {
        NSGradient(colors: [c, c.withAlphaComponent(0)])!.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
    glow(color(0.95, 0.20, 0.68, 0.80), NSPoint(x: 290, y: 320), 460)
    glow(color(0.05, 0.72, 1.00, 0.80), NSPoint(x: 740, y: 320), 460)
    glow(color(0.50, 0.30, 1.00, 0.70), NSPoint(x: 512, y: 660), 480)

    // Glass shine: a soft white sheen over the top and a bright inner edge
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0)])!.draw(in: NSRect(x: 100, y: 540, width: 824, height: 384), angle: -90)
    let inner = NSBezierPath(roundedRect: NSRect(x: 106, y: 106, width: 812, height: 812), xRadius: 178, yRadius: 178)
    NSColor.white.withAlphaComponent(0.55).setStroke(); inner.lineWidth = 4; inner.stroke()

    // Keycap
    let cap = NSRect(x: 297, y: 300, width: 430, height: 420)
    let capPath = NSBezierPath(roundedRect: cap, xRadius: 84, yRadius: 84)
    for (c, off) in [(color(0.93, 0.25, 0.70, 0.95), NSSize(width: -34, height: -40)), (color(0.10, 0.80, 1.0, 0.95), NSSize(width: 34, height: -40))] {
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow(); s.shadowColor = c; s.shadowBlurRadius = 80; s.shadowOffset = off; s.set()
        color(0.1, 0.1, 0.16).setFill(); capPath.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow(); drop.shadowColor = NSColor.black.withAlphaComponent(0.55); drop.shadowBlurRadius = 36; drop.shadowOffset = NSSize(width: 0, height: -22); drop.set()
    NSGradient(colors: [color(0.20, 0.20, 0.28), color(0.09, 0.09, 0.14)])!.draw(in: capPath, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Lit top face
    let face = NSRect(x: cap.minX + 38, y: cap.minY + 84, width: cap.width - 76, height: cap.height - 112)
    let facePath = NSBezierPath(roundedRect: face, xRadius: 64, yRadius: 64)
    NSGradient(colors: [color(0.40, 0.41, 0.52), color(0.21, 0.22, 0.31)])!.draw(in: facePath, angle: -90)
    color(1, 1, 1, 0.22).setStroke(); facePath.lineWidth = 3; facePath.stroke()
    let sheen = NSBezierPath(roundedRect: NSRect(x: face.minX + 26, y: face.maxY - 70, width: face.width - 52, height: 36), xRadius: 18, yRadius: 18)
    color(1, 1, 1, 0.10).setFill(); sheen.fill()

    // Legend
    let base = NSFont.systemFont(ofSize: 190, weight: .heavy)
    let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 190) } ?? base
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.45); shadow.shadowBlurRadius = 6; shadow.shadowOffset = NSSize(width: 0, height: -4)
    let text = NSAttributedString(string: "V3", attributes: [.font: font, .foregroundColor: color(1, 1, 1, 0.96), .shadow: shadow, .kern: -4])
    let size = text.size()
    text.draw(at: NSPoint(x: face.midX - size.width / 2, y: face.midY - size.height / 2 + 4))

    NSGraphicsContext.restoreGraphicsState()

    // Rim light on the squircle's edge
    color(0, 0, 0, 0.12).setStroke(); body.lineWidth = 3; body.stroke()
}

func bitmap(_ pixels: Int, from master: NSBitmapImageRep) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(size: NSSize(width: 1024, height: 1024)).lockFocus(); NSImage(size: NSSize(width: 1024, height: 1024)).unlockFocus()
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: make-icon <output.icns> [preview.png]"); exit(2) }

let master = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: master)
drawIcon(into: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()

if args.count >= 3 { try! master.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2])) }

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! bitmap(px, from: master).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", args[1]]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "wrote \(args[1])" : "iconutil failed")
