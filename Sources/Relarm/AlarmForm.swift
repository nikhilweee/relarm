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
        let ringDuration: Int
    }

    private let nameField = makeTextField()
    private let timePicker = NSDatePicker()
    private let nowButton = NSButton()
    private let soundPicker = NSPopUpButton()
    private let repeatField = makeTextField()
    private let stopAfterPicker = makeRingDurationPicker(untilStoppedTitle: "Never")
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

        timePicker.datePickerElements = [.hourMinuteSecond]
        timePicker.datePickerStyle = .textField
        // NSDatePicker has no rounded bezel, so a borderless picker sits on an
        // empty rounded field to match the text fields around it.
        timePicker.isBezeled = false
        timePicker.isBordered = false
        timePicker.drawsBackground = false
        let timeBox = makeTextField()
        timeBox.isEditable = false
        timeBox.isSelectable = false
        timeBox.refusesFirstResponder = true
        timeBox.addSubview(timePicker)
        timePicker.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            timePicker.leadingAnchor.constraint(equalTo: timeBox.leadingAnchor, constant: Metrics.timePickerInset),
            timePicker.trailingAnchor.constraint(lessThanOrEqualTo: timeBox.trailingAnchor),
            timePicker.centerYAnchor.constraint(equalTo: timeBox.centerYAnchor),
        ])
        if let existing {
            timePicker.dateValue = Calendar.current.date(byAdding: .second, value: existing.secondsSinceMidnight,
                                                          to: Calendar.current.startOfDay(for: Date()))!
        } else {
            timePicker.dateValue = Date()
        }
        nowButton.title = "Now"
        nowButton.bezelStyle = .rounded
        nowButton.target = self
        nowButton.action = #selector(fillCurrentTime)
        nowButton.toolTip = "Use the current time"
        // The time box takes whatever width the button leaves in the control column.
        let timeRow = NSStackView(views: [timeBox, nowButton])
        timeRow.orientation = .horizontal
        timeRow.alignment = .centerY
        timeRow.spacing = 8
        timeRow.distribution = .fill
        timeBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nowButton.setContentHuggingPriority(.required, for: .horizontal)
        timeRow.widthAnchor.constraint(equalToConstant: Metrics.controlWidth).isActive = true

        soundPicker.addItems(withTitles: AlarmSounds.names)
        soundPicker.selectItem(withTitle: existing?.soundName ?? Prefs.defaultSoundName)
        soundPicker.target = self
        soundPicker.action = #selector(previewSelectedSound)
        soundPicker.focusRingType = .default
        soundPicker.widthAnchor.constraint(equalToConstant: Metrics.controlWidth).isActive = true

        stopAfterPicker.selectItem(withTag: existing?.ringDuration ?? Prefs.defaultRingDuration)

        repeatField.stringValue = compactDuration(existing?.interval ?? Prefs.defaultInterval)
        repeatField.placeholderString = "e.g. 5m, 90s, or 1h 30m"
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
        root.addArrangedSubview(formRow("First alert", timeRow))
        root.addArrangedSubview(formRow("Repeat every", repeatField))
        root.addArrangedSubview(formRow("Sound", soundPicker))
        root.addArrangedSubview(formRow("Stop after", stopAfterPicker))
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
        timePicker.nextKeyView = nowButton
        nowButton.nextKeyView = repeatField
        repeatField.nextKeyView = soundPicker
        soundPicker.nextKeyView = stopAfterPicker
        stopAfterPicker.nextKeyView = cancel
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

    @objc private func fillCurrentTime() {
        timePicker.dateValue = Date()
    }

    @objc private func submit() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return showValidation("Give this alarm a name.") }
        // parseDuration rejects zero, so one second is the shortest repeat.
        guard let interval = parseDuration(repeatField.stringValue) else {
            return showValidation("Enter a repeat like 5m, 30s, or 1h 30m.")
        }
        let time = Calendar.current.dateComponents([.hour, .minute, .second], from: timePicker.dateValue)
        let secondsSinceMidnight = (time.hour ?? 0) * 3600 + (time.minute ?? 0) * 60 + (time.second ?? 0)
        result = .saved(Selection(name: name, soundName: soundPicker.titleOfSelectedItem ?? Prefs.defaultSoundName,
                                  secondsSinceMidnight: secondsSinceMidnight,
                                  interval: interval, ringDuration: stopAfterPicker.selectedTag()))
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
        // NSDatePicker owns internal text fields for each time unit. Connect
        // every one to the Now button using AppKit's native key-view chain.
        func setNextKeyViewRecursively(_ view: NSView, next: NSView) {
            view.nextKeyView = next
            view.subviews.forEach { setNextKeyViewRecursively($0, next: next) }
        }
        nameField.nextKeyView = timePicker
        setNextKeyViewRecursively(timePicker, next: nowButton)
        nowButton.nextKeyView = repeatField
        repeatField.nextKeyView = soundPicker
        soundPicker.nextKeyView = stopAfterPicker
        stopAfterPicker.nextKeyView = window.defaultButtonCell?.controlView ?? nameField
    }

    func windowWillClose(_ notification: Notification) {
        previewSound?.stop()
        finish()
    }
}
