// Draws the app icon and writes Resources/AppIcon.icns. Run: swift scripts/make-icon.swift (from mac/).
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: an 824 pt rounded square centered on a 1024 pt canvas.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.30, green: 0.43, blue: 0.96, alpha: 1), ending: NSColor(red: 0.16, green: 0.24, blue: 0.70, alpha: 1))!
        .draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: 460 * s, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = sym.size
        sym.draw(in: NSRect(x: (CGFloat(px) - size.width) / 2, y: (CGFloat(px) - size.height) / 2, width: size.width, height: size.height))
    }
    // The urgency dot.
    NSColor(red: 0.91, green: 0.26, blue: 0.42, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 690 * s, y: 690 * s, width: 150 * s, height: 150 * s)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
