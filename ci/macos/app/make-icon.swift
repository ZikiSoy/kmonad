// Renders AppIcon.iconset: K.svg (the "K" of kmonad.svg, as is) on a white
// rounded square.
// Usage: swift make-icon.swift K.svg|K.png <out.iconset>  then  iconutil -c icns <out.iconset>
import AppKit

guard let k = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    FileHandle.standardError.write("cannot load \(CommandLine.arguments[1])\n".data(using: .utf8)!)
    exit(1)
}
let kAspect = 11.32044 / 15.527696

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let S = CGFloat(px)
    let inset = S * 100 / 1024          // macOS icon grid: 824/1024 square
    let box = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225).fill()
    let h = box.height * 0.56, w = h * kAspect
    k.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for sc in [1, 2] {
        let name = sc == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try! render(pt * sc).write(to: out.appendingPathComponent(name))
    }
}
