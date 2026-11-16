import AppKit
// Renders the app icon: dark rounded square with a terminal glyph and green status dot.
let out = CommandLine.arguments[1]
let sizes = [16, 32, 64, 128, 256, 512, 1024]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for s in sizes {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let r = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: CGFloat(s) * 0.09, dy: CGFloat(s) * 0.09)
    let path = NSBezierPath(roundedRect: r, xRadius: CGFloat(s) * 0.18, yRadius: CGFloat(s) * 0.18)
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1), NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 1)])!.draw(in: path, angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(s) * 0.42, weight: .semibold).applying(.init(paletteColors: [NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.6, alpha: 1)]))
    if let sym = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (CGFloat(s) - sz.width) / 2, y: (CGFloat(s) - sz.height) / 2, width: sz.width, height: sz.height))
    }
    let d = CGFloat(s) * 0.13
    NSColor.systemOrange.setFill()
    NSBezierPath(ovalIn: NSRect(x: r.maxX - d * 1.5, y: r.maxY - d * 1.5, width: d, height: d)).fill()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let png = rep.representation(using: .png, properties: [:])!
    for (scale, name) in [(1, "icon_\(s)x\(s).png"), (2, "icon_\(s/2)x\(s/2)@2x.png")] where !(scale == 2 && s == 16) {
        if scale == 1 && s == 1024 { continue }
        try! png.write(to: URL(fileURLWithPath: out + "/" + name))
    }
}
