import AppKit
import RelarmCore

// One set of metrics so every window lays out on the same grid.
enum Metrics {
    static let windowInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    static let rowSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 20
    static let labelWidth: CGFloat = 110
    static let controlWidth: CGFloat = 220
    static let contentWidth: CGFloat = 380
    static let rowLabelSpacing: CGFloat = 12
    // Lines a borderless date picker's text up with a rounded text field's.
    static let timePickerInset: CGFloat = 0
    // What's left for hint and error text sharing a row with the label column.
    static var detailWidth: CGFloat { contentWidth - labelWidth - rowLabelSpacing }
}

// Secondary text under a control: capped so a long message can't widen or
// overflow the window it sits in.
func detailLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.widthAnchor.constraint(equalToConstant: Metrics.detailWidth).isActive = true
    return label
}

// Right-aligned label, then control: the native settings layout, shared by the
// alarm sheet and the settings window.
func formRow(_ labelText: String, _ control: NSView) -> NSStackView {
    let label = NSTextField(labelWithString: labelText)
    label.alignment = .right
    label.widthAnchor.constraint(equalToConstant: Metrics.labelWidth).isActive = true
    let row = NSStackView(views: [label, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = Metrics.rowLabelSpacing
    return row
}

// The default square bezel looks out of place beside the rounded popups and buttons.
func makeTextField() -> NSTextField {
    let field = NSTextField()
    field.bezelStyle = .roundedBezel
    return field
}

// Ring duration choices, tagged with their seconds, shared by the alarm sheet
// and the settings default. Each caller names the zero choice to suit its label.
func makeRingDurationPicker(untilStoppedTitle: String) -> NSPopUpButton {
    let picker = NSPopUpButton()
    for seconds in AlarmConfiguration.ringDurationChoices {
        picker.addItem(withTitle: seconds > 0 ? durationLabel(seconds) : untilStoppedTitle)
        picker.lastItem?.tag = seconds
    }
    picker.widthAnchor.constraint(equalToConstant: Metrics.controlWidth).isActive = true
    return picker
}

// NSStackView's fittingSize drops the trailing inset, so drive the width from a
// known content width instead of asking for it.
func sizeToFit(_ window: NSWindow, content: NSStackView) {
    content.layoutSubtreeIfNeeded()
    window.setContentSize(NSSize(width: Metrics.contentWidth + content.edgeInsets.left + content.edgeInsets.right,
                                 height: content.fittingSize.height))
}

// A sheet has no close button, so Escape needs somewhere to go.
final class SheetWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

func activateApp() {
    if #available(macOS 14.0, *) {
        NSApp.activate()
    } else {
        NSApp.activate(ignoringOtherApps: true)
    }
}

// Deleting an alarm can't be undone, so every path through it asks first.
func confirmDelete(of name: String, in parent: NSWindow?, completion: @escaping (Bool) -> Void) {
    let alert = NSAlert()
    alert.messageText = "Delete “\(name)”?"
    alert.informativeText = "This alarm stops ringing and can't be recovered."
    let delete = alert.addButton(withTitle: "Delete")
    delete.hasDestructiveAction = true
    delete.keyEquivalent = ""
    // Cancel takes Return so a stray keypress can't destroy an alarm.
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
    guard let parent else {
        completion(alert.runModal() == .alertFirstButtonReturn)
        return
    }
    alert.beginSheetModal(for: parent) { completion($0 == .alertFirstButtonReturn) }
}

private let shortClock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter
}()

private let mediumClock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .medium
    return formatter
}()

// Most alarms sit on the minute, so ":00" would only add clutter.
func clockLabel(_ date: Date) -> String {
    let hasSeconds = Calendar.current.component(.second, from: date) != 0
    return (hasSeconds ? mediumClock : shortClock).string(from: date)
}

func compactDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainder = seconds % 60
    var parts: [String] = []
    if hours > 0 { parts.append("\(hours)h") }
    if minutes > 0 { parts.append("\(minutes)m") }
    if remainder > 0 { parts.append("\(remainder)s") }
    return parts.joined(separator: " ")
}
