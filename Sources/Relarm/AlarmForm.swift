import AppKit
import RelarmCore

final class AlarmFormController: NSObject, NSWindowDelegate {
    enum Result {
        case saved(Selection)
        case delete
    }

    struct Selection {
        let name: String
        let soundName: String
        let secondsSinceMidnight: Int
        let interval: Int
    }

    private let nameField = NSTextField()
    private let timePicker = NSDatePicker()
    private let soundPicker = NSPopUpButton()
    private let repeatField = NSTextField()
    private let validationLabel = detailLabel()
    private var window: NSWindow!
    private var result: Result?
    private let isEditing: Bool
    private let existingName: String
    private var previewSound: NSSound?
    private weak var parentWindow: NSWindow?
    private var completion: ((Result?) -> Void)?

    init(existing: AlarmConfiguration?) {
        isEditing = existing != nil
        existingName = existing?.name ?? ""
        super.init()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = Metrics.rowSpacing
        root.edgeInsets = Metrics.windowInsets

        let title = NSTextField(labelWithString: isEditing ? "Edit Alarm" : "Add Alarm")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)

        nameField.placeholderString = "e.g. Stretch, Take medicine"
        nameField.stringValue = existing?.name ?? ""
        nameField.widthAnchor.constraint(equalToConstant: Metrics.controlWidth).isActive = true

        timePicker.datePickerElements = [.hourMinute]
        timePicker.datePickerStyle = .textFieldAndStepper
        if let existing {
            timePicker.dateValue = Calendar.current.date(byAdding: .second, value: existing.secondsSinceMidnight,
                                                          to: Calendar.current.startOfDay(for: Date()))!
        } else {
            timePicker.dateValue = Date()
        }
        timePicker.widthAnchor.constraint(equalToConstant: Metrics.controlWidth).isActive = true

        soundPicker.addItems(withTitles: AlarmSounds.names)
        soundPicker.selectItem(withTitle: existing?.soundName ?? Prefs.defaultSoundName)
        soundPicker.target = self
        soundPicker.action = #selector(previewSelectedSound)
        soundPicker.focusRingType = .default
        soundPicker.widthAnchor.constraint(equalToConstant: Metrics.controlWidth).isActive = true

        repeatField.stringValue = compactDuration(existing?.interval ?? Prefs.defaultInterval)
        repeatField.placeholderString = "e.g. 5m, 1:30, or 1h 30m"
        repeatField.widthAnchor.constraint(equalToConstant: Metrics.controlWidth).isActive = true

        // Always laid out, empty when valid: the sheet is sized to fit, so a
        // hidden label would leave no room for the message to appear in.
        validationLabel.textColor = .systemRed

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: isEditing ? "Save" : "Add Alarm", target: self, action: #selector(submit))
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var buttonViews: [NSView] = []
        if isEditing {
            let delete = NSButton(title: "Delete", target: self, action: #selector(deleteAlarm))
            delete.hasDestructiveAction = true
            buttonViews.append(delete)
        }
        buttonViews.append(contentsOf: [spacer, cancel, save])
        let buttons = NSStackView(views: buttonViews)
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true

        root.addArrangedSubview(title)
        root.setCustomSpacing(Metrics.sectionSpacing, after: title)
        root.addArrangedSubview(formRow("Name", nameField))
        root.addArrangedSubview(formRow("First alert", timePicker))
        root.addArrangedSubview(formRow("Repeat every", repeatField))
        root.addArrangedSubview(formRow("Sound", soundPicker))
        let validationRow = formRow("", validationLabel)
        root.addArrangedSubview(validationRow)
        root.setCustomSpacing(Metrics.sectionSpacing, after: validationRow)
        root.addArrangedSubview(buttons)

        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = root
        sizeToFit(window, content: root)
        nameField.nextKeyView = timePicker
        timePicker.nextKeyView = repeatField
        repeatField.nextKeyView = soundPicker
        soundPicker.nextKeyView = cancel
        window.initialFirstResponder = nameField
    }

    func beginSheet(for parent: NSWindow, completion: @escaping (Result?) -> Void) {
        parentWindow = parent
        self.completion = completion
        wireDatePickerKeyViews()
        parent.beginSheet(window)
    }

    @objc private func previewSelectedSound() {
        previewSound?.stop()
        guard let name = soundPicker.titleOfSelectedItem,
              let sound = NSSound(named: NSSound.Name(name)) else { return }
        previewSound = sound
        sound.play()
    }

    @objc private func submit() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return showValidation("Give this alarm a name.") }
        let interval = parseDuration(repeatField.stringValue)
        guard let interval, interval >= Prefs.minimumInterval else {
            return showValidation("Repeat at least once a minute.")
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: timePicker.dateValue)
        result = .saved(Selection(name: name, soundName: soundPicker.titleOfSelectedItem ?? Prefs.defaultSoundName,
                                  secondsSinceMidnight: (components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60,
                                  interval: interval))
        previewSound?.stop()
        finish()
    }

    private func showValidation(_ text: String) {
        validationLabel.stringValue = text
    }

    @objc private func cancel() {
        previewSound?.stop()
        finish()
    }

    @objc private func deleteAlarm() {
        confirmDelete(of: existingName, in: window) { [weak self] confirmed in
            guard let self, confirmed else { return }
            self.result = .delete
            self.previewSound?.stop()
            self.finish()
        }
    }

    private func finish() {
        guard let parent = parentWindow else { return }
        let callback = completion
        completion = nil
        parentWindow = nil
        parent.endSheet(window)
        callback?(result)
    }

    private func wireDatePickerKeyViews() {
        // NSDatePicker owns internal text fields for hour and minute. Connect
        // every one to Sound using AppKit's native key-view chain.
        func setNextKeyViewRecursively(_ view: NSView, next: NSView) {
            view.nextKeyView = next
            view.subviews.forEach { setNextKeyViewRecursively($0, next: next) }
        }
        nameField.nextKeyView = timePicker
        setNextKeyViewRecursively(timePicker, next: repeatField)
        repeatField.nextKeyView = soundPicker
        soundPicker.nextKeyView = window.defaultButtonCell?.controlView ?? nameField
    }

    func windowWillClose(_ notification: Notification) {
        previewSound?.stop()
        finish()
    }
}
