// Renders the README screenshots in docs/ from the app's real window code.
// Run ./scripts/screenshots.sh, which compiles this with the app sources.
//
// Windows are drawn offscreen with cacheDisplay instead of captured with
// screencapture, which macOS blocks for shells without Screen Recording access.
// The binary runs under its own name, so its prefs never touch the real Relarm's.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Draw as the active app without stealing focus: a sheet is key and its parent
// stays main, as on screen.
extension NSWindow {
    @objc var shotsIsKey: Bool { isSheet || attachedSheet == nil }
    @objc var shotsIsMain: Bool { !isSheet }
}
extension NSApplication { @objc var shotsIsActive: Bool { true } }
func swap(_ cls: AnyClass, _ a: Selector, _ b: Selector) {
    method_exchangeImplementations(class_getInstanceMethod(cls, a)!, class_getInstanceMethod(cls, b)!)
}
swap(NSWindow.self, #selector(getter: NSWindow.isKeyWindow), #selector(getter: NSWindow.shotsIsKey))
swap(NSWindow.self, #selector(getter: NSWindow.isMainWindow), #selector(getter: NSWindow.shotsIsMain))
swap(NSApplication.self, #selector(getter: NSApplication.isActive), #selector(getter: NSApplication.shotsIsActive))

func at(_ h: Int, _ m: Int) -> Int { h * 3600 + m * 60 }
// The Next column counts down from the real clock, so fire dates are relative to now.
let now = Date().addingTimeInterval(-1)
let alarms = [
    AlarmConfiguration(name: "Stretch", secondsSinceMidnight: at(9, 0), interval: 45 * 60,
                       nextFireDate: now.addingTimeInterval(5 * 60)),
    AlarmConfiguration(name: "Drink water", secondsSinceMidnight: at(9, 30), interval: 60 * 60,
                       nextFireDate: now.addingTimeInterval(20 * 60)),
    AlarmConfiguration(name: "Look away from the screen", secondsSinceMidnight: at(9, 10), interval: 20 * 60,
                       nextFireDate: now.addingTimeInterval(20 * 60)),
    AlarmConfiguration(name: "Stand-up meeting", isEnabled: false, secondsSinceMidnight: at(11, 0),
                       interval: 24 * 60 * 60, nextFireDate: now),
]

let outputDirectory = CommandLine.arguments[1]
let scale: CGFloat = 2
let margin: CGFloat = 40
// Tall enough for the Edit Alarm sheet; all four shots share it so they match.
let windowContentSize = NSSize(width: 660, height: 334)
let titlebarHeight: CGFloat = 52

// Offscreen windows report a 1x backing, so ask for 2x pixels explicitly.
func snapshot(_ window: NSWindow) -> NSBitmapImageRep {
    let view = window.contentView!.superview!
    view.layoutSubtreeIfNeeded()
    let rep = bitmap(size: view.bounds.size)
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

func bitmap(size: NSSize) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    return rep
}

// Window art with rounded corners and a drop shadow.
func drawFramed(_ rep: NSBitmapImageRep, in rect: NSRect, radius: CGFloat, shadowBlur: CGFloat, shadowOffset: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    shadow.shadowBlurRadius = shadowBlur
    shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    rep.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ appearance: NSAppearance.Name, name: String?, withSheet: Bool, done: @escaping () -> Void) {
    NSApp.appearance = NSAppearance(named: appearance)
    let list = AlarmListWindowController()
    list.refresh(alarms)
    list.show()
    let window = NSApp.windows.first { $0.title == "Relarm" && $0.isVisible }!
    window.setContentSize(windowContentSize)
    window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
    if withSheet { list.presentAlarmForm(existing: alarms[0]) { _ in } }
    // Lets the sheet finish animating in.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        let sheet = window.attachedSheet
        // Shown at rest, without the name preselected.
        sheet?.makeFirstResponder(nil)
        // Nothing told the window it became key, so it would still draw inactive.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        window.contentView!.superview!.subviews.forEach { $0.needsDisplay = true }

        let windowRect = NSRect(origin: NSPoint(x: margin, y: margin), size: window.frame.size)
        let canvas = bitmap(size: NSSize(width: windowRect.width + margin * 2, height: windowRect.height + margin * 2))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        drawFramed(snapshot(window), in: windowRect, radius: 16, shadowBlur: 30, shadowOffset: 10)
        if let sheet {
            let sheetRect = NSRect(x: windowRect.midX - sheet.frame.width / 2,
                                   y: windowRect.maxY - titlebarHeight - sheet.frame.height,
                                   width: sheet.frame.width, height: sheet.frame.height)
            drawFramed(snapshot(sheet), in: sheetRect, radius: 12, shadowBlur: 12, shadowOffset: 2)
            window.endSheet(sheet)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let name {
            let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(name).png")
            try! canvas.representation(using: .png, properties: [:])!.write(to: url)
            print("Wrote \(url.path)")
        }
        window.orderOut(nil)
        done()
    }
}

// The first pass draws the default button unhighlighted, so a throwaway one goes first.
render(.aqua, name: nil, withSheet: true) {
    render(.aqua, name: "alarms-light", withSheet: false) {
        render(.darkAqua, name: "alarms-dark", withSheet: false) {
            render(.aqua, name: "form-light", withSheet: true) {
                render(.darkAqua, name: "form-dark", withSheet: true) { exit(0) }
            }
        }
    }
}
app.run()
