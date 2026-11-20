// Renders AppIcon.iconset (the "K" from kmonad.svg on a rounded square).
// Usage: swift make-icon.swift <out.iconset>  then  iconutil -c icns <out.iconset>
import AppKit

let kSize = NSSize(width: 11.32044, height: 15.527696)
func kPath(in rect: NSRect) -> NSBezierPath {
    let s = min(rect.width / kSize.width, rect.height / kSize.height)
    let ox = rect.midX - kSize.width * s / 2, oy = rect.midY - kSize.height * s / 2
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + (kSize.height - y) * s) }
    let b = NSBezierPath()
    b.move(to: p(0, 0.05287657)); b.line(to: p(3.2150437, 0.05287657))
    b.line(to: p(3.2150437, 15.527696)); b.line(to: p(0, 15.527696)); b.close()
    b.move(to: p(2.3628634, 7.8096536)); b.line(to: p(7.4468934, 0.0335088))
    b.line(to: p(11.32044, 0.0335088)); b.line(to: p(6.2170423, 7.780602))
    b.line(to: p(11.301072, 15.527696)); b.line(to: p(7.4565772, 15.527696)); b.close()
    return b
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let S = CGFloat(px)
    // macOS icon grid: 824/1024 rounded square, centred
    let inset = S * 100 / 1024
    let box = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let bg = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    NSGradient(starting: NSColor(srgbRed: 0x7d/255.0, green: 0x6d/255.0, blue: 0xb0/255.0, alpha: 1),
               ending: NSColor(srgbRed: 0x55/255.0, green: 0x48/255.0, blue: 0x80/255.0, alpha: 1))!
        .draw(in: bg, angle: -90)
    NSColor.white.setFill()
    kPath(in: box.insetBy(dx: box.width * 0.27, dy: box.height * 0.22)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = sc == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try! render(pt * sc).write(to: out.appendingPathComponent(name))
    }
}
