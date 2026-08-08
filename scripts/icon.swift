// Generates Resources/AppIcon.icns: a bell on a rounded blue gradient. No badge
// dot here: the app icon is static, and the dot means "an alarm is scheduled" —
// that state lives on the status bar icon, which swaps symbols to show it.
import AppKit

func render(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixels)
    let inset = size * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let background = NSBezierPath(roundedRect: rect, xRadius: rect.width * 232 / 824, yRadius: rect.width * 232 / 824)
    NSGradient(starting: NSColor(calibratedRed: 0.15, green: 0.56, blue: 0.92, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.24, blue: 0.67, alpha: 1))!.draw(in: background, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.47, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let target = rect.width * 0.62
        let scale = target / max(symbol.size.width, symbol.size.height)
        let width = symbol.size.width * scale
        let height = symbol.size.height * scale
        tinted.draw(in: NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: "/tmp/Relarm.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let data = render(size * scale).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
