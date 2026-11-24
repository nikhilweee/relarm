import AppKit
import RelarmCore

// Single home for UserDefaults keys, defaults, and fallbacks
enum Prefs {
    static let alarmsKey = "alarms"
    static let legacyAlarmKey = "activeAlarm"
    static let defaultSoundKey = "defaultSound"
    static let defaultIntervalKey = "defaultInterval"

    static let fallbackInterval = 5 * 60

    static var alarms: [AlarmConfiguration] {
        get {
            if let data = UserDefaults.standard.data(forKey: alarmsKey),
               let saved = try? JSONDecoder().decode([AlarmConfiguration].self, from: data) {
                return saved
            }
            // One-time migration from Relarm 0.1's single-alarm preference.
            if let data = UserDefaults.standard.data(forKey: legacyAlarmKey),
               let legacy = try? JSONDecoder().decode(AlarmConfiguration.self, from: data) {
                let migrated = [legacy]
                self.alarms = migrated
                UserDefaults.standard.removeObject(forKey: legacyAlarmKey)
                return migrated
            }
            return []
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: alarmsKey)
        }
    }

    // Tones ship with macOS, so a stored name is only trusted if it still exists.
    static var defaultSoundName: String {
        get {
            guard let name = UserDefaults.standard.string(forKey: defaultSoundKey),
                  AlarmSounds.names.contains(name) else { return AlarmSounds.defaultName }
            return name
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultSoundKey) }
    }

    static var defaultInterval: Int {
        get {
            let seconds = UserDefaults.standard.integer(forKey: defaultIntervalKey)
            return seconds > 0 ? seconds : fallbackInterval
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultIntervalKey) }
    }
}

enum AlarmSounds {
    // These are the public, built-in NSSound names that a third-party macOS
    // app can depend on. Clock's Radial tone is private to the Clock app.
    static let names = ["Glass", "Basso", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    static let defaultName = "Glass"
}

final class SettingsController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let soundPicker = NSPopUpButton()
    private let repeatField = NSTextField()
    private let hintLabel = detailLabel()
    // Colon forms still parse, but mm:ss reads as hours to too many people.
    private let defaultHint = "e.g. 5m, 90s, or 1h 30m"
    private var window: SheetWindow!
    private var previewSound: NSSound?
    private weak var parentWindow: NSWindow?
    private var completion: (() -> Void)?

    override init() {
        super.init()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = Metrics.rowSpacing
        root.edgeInsets = Metrics.windowInsets

        let title = NSTextField(labelWithString: "Settings")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)

        soundPicker.addItems(withTitles: AlarmSounds.names)
        soundPicker.target = self
        soundPicker.action = #selector(soundChanged)
        soundPicker.widthAnchor.constraint(equalToConstant: Metrics.controlWidth).isActive = true

        repeatField.placeholderString = defaultHint
        repeatField.delegate = self
        repeatField.widthAnchor.constraint(equalToConstant: Metrics.controlWidth).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true

        // Settings apply as they change, so Done just dismisses.
        let done = NSButton(title: "Done", target: self, action: #selector(finishEditing))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [aboutFooter(), spacer, done])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true

        let repeatRow = formRow("Default repeat", repeatField)
        let hintRow = formRow("", hintLabel)
        root.addArrangedSubview(title)
        root.setCustomSpacing(Metrics.sectionSpacing, after: title)
        root.addArrangedSubview(formRow("Default sound", soundPicker))
        root.addArrangedSubview(repeatRow)
        root.setCustomSpacing(6, after: repeatRow)
        root.addArrangedSubview(hintRow)
        root.setCustomSpacing(Metrics.sectionSpacing, after: hintRow)
        root.addArrangedSubview(separator)
        root.setCustomSpacing(Metrics.rowSpacing, after: separator)
        root.addArrangedSubview(footer)

        window = SheetWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = root
        window.onCancel = { [weak self] in self?.finishEditing() }
        sizeToFit(window, content: root)
        window.initialFirstResponder = soundPicker
    }

    func beginSheet(for parent: NSWindow, completion: @escaping () -> Void) {
        parentWindow = parent
        self.completion = completion
        refresh()
        parent.beginSheet(window)
    }

    // Resigning first responder commits a pending interval edit.
    @objc private func finishEditing() {
        window.makeFirstResponder(nil)
        previewSound?.stop()
        finish()
    }

    private func finish() {
        guard let parent = parentWindow else { return }
        let callback = completion
        completion = nil
        parentWindow = nil
        parent.endSheet(window)
        callback?()
    }

    private func aboutFooter() -> NSStackView {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            return label
        }
        let github = NSButton(title: "GitHub", target: self, action: #selector(openRepo))
        github.isBordered = false
        github.contentTintColor = .linkColor
        github.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let footer = NSStackView(views: [label("Relarm · Version \(version)"), label("·"), github])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        return footer
    }

    private func refresh() {
        soundPicker.selectItem(withTitle: Prefs.defaultSoundName)
        repeatField.stringValue = compactDuration(Prefs.defaultInterval)
        showHint(defaultHint, isError: false)
    }

    @objc private func openRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/nikhilweee/relarm")!)
    }

    @objc private func soundChanged() {
        guard let name = soundPicker.titleOfSelectedItem else { return }
        Prefs.defaultSoundName = name
        previewSound?.stop()
        previewSound = NSSound(named: NSSound.Name(name))
        previewSound?.play()
    }

    // Invalid text is reverted rather than saved, so the stored default stays usable.
    private func commitInterval() {
        guard let interval = parseDuration(repeatField.stringValue) else {
            NSSound.beep()
            refresh()
            return
        }
        Prefs.defaultInterval = interval
        repeatField.stringValue = compactDuration(interval)
        showHint(defaultHint, isError: false)
    }

    private func showHint(_ text: String, isError: Bool) {
        hintLabel.stringValue = text
        hintLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    func controlTextDidChange(_ notification: Notification) {
        let text = repeatField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return showHint(defaultHint, isError: false) }
        guard parseDuration(text) != nil else {
            return showHint("Unknown interval \"\(text)\"", isError: true)
        }
        showHint(defaultHint, isError: false)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitInterval()
    }

    // Never leave a preview tone ringing.
    func windowWillClose(_ notification: Notification) {
        previewSound?.stop()
        finish()
    }
}
