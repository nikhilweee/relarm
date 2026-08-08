import AppKit
import UserNotifications
import RelarmCore

private enum Prefs {
    static let alarmsKey = "alarms"
    static let legacyAlarmKey = "activeAlarm"

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
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private enum NotificationAction {
        static let category = "RELARM_ALARM"
        static let snooze = "RELARM_SNOOZE"
        static let stop = "RELARM_STOP"
        static let snoozeSeconds = 10 * 60
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var alarms: [AlarmConfiguration] = []
    private var timers: [UUID: Timer] = [:]
    private var ringingSounds: [UUID: NSSound] = [:]
    private var listWindow: AlarmListWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        registerNotificationActions(on: notificationCenter)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "Relarm")
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        restoreAlarms()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ringingSounds.values.forEach { $0.stop() }
    }

    private func restoreAlarms() {
        alarms = Prefs.alarms
        for index in alarms.indices where alarms[index].isEnabled {
            alarms[index].nextFireDate = AlarmSchedule.nextFutureDate(
                after: alarms[index].nextFireDate, interval: alarms[index].interval
            )
        }
        sortAlarms()
        saveAndSchedule()
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            showAlarmsWindow()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let enabled = alarms.filter(\.isEnabled)
        if enabled.isEmpty {
            let empty = NSMenuItem(title: "No enabled alarms", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            for alarm in enabled {
                let item = NSMenuItem(title: "\(alarm.name) — \(formatter.string(from: alarm.nextFireDate))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        addItem(to: menu, title: "Open Relarm", action: #selector(openRelarm))
        addItem(to: menu, title: "Quit Relarm", action: #selector(quit), key: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func showAlarmsWindow() {
        if listWindow == nil {
            let controller = AlarmListWindowController()
            controller.onAdd = { [weak self] in self?.addAlarm() }
            controller.onEdit = { [weak self] id in
                guard let self, let alarm = self.alarms.first(where: { $0.id == id }) else { return }
                self.presentForm(existing: alarm)
            }
            controller.onToggle = { [weak self] id, enabled in self?.setEnabled(id: id, enabled: enabled) }
            listWindow = controller
        }
        listWindow?.refresh(alarms)
        NSApp.activate(ignoringOtherApps: true)
        listWindow?.show()
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String = "", represents: Any? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = represents
        menu.addItem(item)
    }

    @objc private func addAlarm() { presentForm(existing: nil) }

    @objc private func openRelarm() { showAlarmsWindow() }

    private func presentForm(existing: AlarmConfiguration?) {
        let form = AlarmFormController(existing: existing)
        NSApp.activate(ignoringOtherApps: true)
        guard let formResult = form.run() else { return }
        if case .delete = formResult, let existing {
            deleteAlarm(id: existing.id)
            return
        }
        guard case let .saved(selection) = formResult else { return }
        let alarm = AlarmConfiguration(
            id: existing?.id ?? UUID(), name: selection.name,
            isEnabled: existing?.isEnabled ?? true,
            soundName: selection.soundName,
            secondsSinceMidnight: selection.secondsSinceMidnight, interval: selection.interval,
            nextFireDate: AlarmSchedule.initialFireDate(secondsSinceMidnight: selection.secondsSinceMidnight)
        )
        if let index = alarms.firstIndex(where: { $0.id == alarm.id }) {
            alarms[index] = alarm
        } else {
            alarms.append(alarm)
        }
        saveAndSchedule()
        requestNotificationsIfNeeded()
    }

    private func setEnabled(id: UUID, enabled: Bool) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[index].isEnabled = enabled
        if enabled {
            alarms[index].nextFireDate = AlarmSchedule.nextFutureDate(
                after: alarms[index].nextFireDate, interval: alarms[index].interval
            )
        }
        if !enabled { stopAlarmSound(for: id) }
        saveAndSchedule()
    }

    private func deleteAlarm(id: UUID) {
        stopAlarmSound(for: id)
        alarms.removeAll { $0.id == id }
        saveAndSchedule()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func saveAndSchedule() {
        sortAlarms()
        Prefs.alarms = alarms
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        for alarm in alarms where alarm.isEnabled {
            schedule(alarm)
        }
        listWindow?.refresh(alarms)
    }

    private func sortAlarms() {
        alarms.sort {
            if $0.isEnabled != $1.isEnabled { return $0.isEnabled }
            return $0.nextFireDate < $1.nextFireDate
        }
    }

    private func schedule(_ alarm: AlarmConfiguration) {
        let timer = Timer(fireAt: alarm.nextFireDate, interval: 0,
                          target: self, selector: #selector(alarmFired(_:)), userInfo: alarm.id.uuidString, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        timers[alarm.id] = timer
    }

    @objc private func alarmFired(_ timer: Timer) {
        guard let text = timer.userInfo as? String, let id = UUID(uuidString: text),
              let index = alarms.firstIndex(where: { $0.id == id }), alarms[index].isEnabled else { return }
        timers[id] = nil
        deliverAlarm(for: alarms[index])
        alarms[index].nextFireDate = AlarmSchedule.nextFutureDate(
            after: alarms[index].nextFireDate.addingTimeInterval(Double(alarms[index].interval)),
            interval: alarms[index].interval
        )
        saveAndSchedule()
    }

    private func deliverAlarm(for alarm: AlarmConfiguration) {
        // Notifications are emitted only when the app's scheduled timer fires.
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = alarm.name
            content.body = "Your repeating alarm is ringing."
            content.categoryIdentifier = NotificationAction.category
            content.userInfo = ["alarmID": alarm.id.uuidString]
            let request = UNNotificationRequest(identifier: "relarm.ring.\(UUID().uuidString)", content: content, trigger: nil)
            center.add(request) { error in
                guard error == nil else { return }
                DispatchQueue.main.async { self?.playAlarmSound(for: alarm.id, soundName: alarm.soundName) }
            }
        }
    }

    private func registerNotificationActions(on center: UNUserNotificationCenter) {
        let snooze = UNNotificationAction(identifier: NotificationAction.snooze, title: "Snooze", options: [])
        let stop = UNNotificationAction(identifier: NotificationAction.stop, title: "Stop", options: [])
        let category = UNNotificationCategory(identifier: NotificationAction.category, actions: [snooze, stop],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    private func playAlarmSound(for id: UUID, soundName: String) {
        stopAlarmSound(for: id)
        guard let sound = NSSound(named: NSSound.Name(soundName)) else { return }
        sound.loops = true
        sound.play()
        ringingSounds[id] = sound
    }

    private func stopAlarmSound(for id: UUID) {
        ringingSounds.removeValue(forKey: id)?.stop()
    }

    private func requestNotificationsIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if !granted { DispatchQueue.main.async { self?.showError("Enable notifications in System Settings to receive Relarm alerts.") } }
                }
            } else if settings.authorizationStatus == .denied {
                DispatchQueue.main.async { self?.showError("Enable notifications in System Settings to receive Relarm alerts.") }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Relarm"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.notification.request.content.categoryIdentifier == NotificationAction.category,
              let text = response.notification.request.content.userInfo["alarmID"] as? String,
              let id = UUID(uuidString: text) else {
            completionHandler()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { completionHandler(); return }
            switch response.actionIdentifier {
            case NotificationAction.stop, UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier:
                self.stopAlarmSound(for: id)
            case NotificationAction.snooze:
                self.stopAlarmSound(for: id)
                if let index = self.alarms.firstIndex(where: { $0.id == id && $0.isEnabled }) {
                    self.alarms[index].nextFireDate = Date().addingTimeInterval(Double(NotificationAction.snoozeSeconds))
                    self.saveAndSchedule()
                }
            default:
                break
            }
            completionHandler()
        }
    }
}

private final class AlarmListWindowController: NSObject, NSWindowDelegate {
    var onAdd: (() -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onToggle: ((UUID, Bool) -> Void)?

    private var alarms: [AlarmConfiguration] = []
    private let list = FlippedStackView()
    private let emptyState = NSTextField(labelWithString: "No alarms yet. Add one to get started.")
    private var window: NSWindow!

    override init() {
        super.init()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let title = NSTextField(labelWithString: "Alarms")
        title.font = .boldSystemFont(ofSize: 24)
        let add = NSButton(title: "Add Alarm", target: self, action: #selector(addAlarm))
        add.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, spacer, add])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.widthAnchor.constraint(equalToConstant: 652).isActive = true

        let subtitle = NSTextField(labelWithString: "Named repeating alarms")
        subtitle.textColor = .secondaryLabelColor

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        list.widthAnchor.constraint(equalToConstant: 652).isActive = true
        list.frame = NSRect(x: 0, y: 0, width: 652, height: 400)

        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center
        emptyState.widthAnchor.constraint(equalToConstant: 652).isActive = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 666).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 400).isActive = true

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let footerLabel = NSTextField(labelWithString: "Relarm · Version \(version)")
        footerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footerLabel.textColor = .secondaryLabelColor
        let github = NSButton(title: "GitHub", target: self, action: #selector(openGitHub))
        github.isBordered = false
        github.contentTintColor = .linkColor
        github.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let footer = NSStackView(views: [footerLabel, NSTextField(labelWithString: "·"), github])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6

        root.addArrangedSubview(header)
        root.addArrangedSubview(subtitle)
        root.setCustomSpacing(20, after: subtitle)
        root.addArrangedSubview(emptyState)
        root.addArrangedSubview(scroll)
        root.addArrangedSubview(footer)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 570),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Relarm"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = root
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    func refresh(_ newAlarms: [AlarmConfiguration]) {
        alarms = newAlarms
        list.arrangedSubviews.forEach {
            list.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        emptyState.isHidden = !alarms.isEmpty
        for (index, alarm) in alarms.enumerated() {
            list.addArrangedSubview(row(for: alarm, index: index))
        }
        list.layoutSubtreeIfNeeded()
        list.setFrameSize(NSSize(width: 652, height: max(400, list.fittingSize.height)))
    }

    private func row(for alarm: AlarmConfiguration, index: Int) -> NSView {
        let time = NSTextField(labelWithString: formattedTime(alarm.secondsSinceMidnight))
        time.font = .monospacedDigitSystemFont(ofSize: 28, weight: .regular)
        time.alignment = .left
        time.widthAnchor.constraint(equalToConstant: 168).isActive = true
        time.setContentCompressionResistancePriority(.required, for: .horizontal)

        let name = NSTextField(labelWithString: alarm.name)
        name.font = .boldSystemFont(ofSize: 15)
        let detail: String
        if alarm.isEnabled {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            detail = "Next \(formatter.string(from: alarm.nextFireDate)) · Every \(durationLabel(alarm.interval)) · \(alarm.soundName)"
        } else {
            detail = "Disabled · Every \(durationLabel(alarm.interval)) · \(alarm.soundName)"
        }
        let summary = NSTextField(labelWithString: detail)
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, summary])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.widthAnchor.constraint(equalToConstant: 238).isActive = true

        let toggle = NSSwitch()
        toggle.state = alarm.isEnabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleAlarm(_:))
        toggle.tag = index

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [spacer, toggle])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        let row = ClickableStackView(views: [time, text, controls])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        row.widthAnchor.constraint(equalToConstant: 652).isActive = true
        row.onClick = { [weak self] in self?.onEdit?(alarm.id) }
        return row
    }

    @objc private func addAlarm() { onAdd?() }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/nikhilweee/relarm")!)
    }

    @objc private func toggleAlarm(_ sender: NSSwitch) {
        guard alarms.indices.contains(sender.tag) else { return }
        onToggle?(alarms[sender.tag].id, sender.state == .on)
    }

    private func formattedTime(_ seconds: Int) -> String {
        let date = Calendar.current.date(byAdding: .second, value: seconds, to: Calendar.current.startOfDay(for: Date()))!
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class ClickableStackView: NSStackView {
    var onClick: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }
}

private final class AlarmFormController: NSObject, NSWindowDelegate {
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
    private let repeatField = NSTextField(string: "5m")
    private let validationLabel = NSTextField(labelWithString: "")
    private var window: NSWindow!
    private var result: Result?
    private let isEditing: Bool
    private var previewSound: NSSound?

    init(existing: AlarmConfiguration?) {
        isEditing = existing != nil
        super.init()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)

        let title = NSTextField(labelWithString: isEditing ? "Edit Alarm" : "Add Alarm")
        title.font = .boldSystemFont(ofSize: 20)
        let description = NSTextField(wrappingLabelWithString: "Choose when the first alert should ring. Relarm will continue at the selected interval until you disable or delete it.")
        description.font = .systemFont(ofSize: NSFont.systemFontSize)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 0
        description.widthAnchor.constraint(equalToConstant: 380).isActive = true

        nameField.placeholderString = "e.g. Stretch, Take medicine"
        nameField.stringValue = existing?.name ?? ""
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        timePicker.datePickerElements = [.hourMinute]
        timePicker.datePickerStyle = .textFieldAndStepper
        if let existing {
            timePicker.dateValue = Calendar.current.date(byAdding: .second, value: existing.secondsSinceMidnight,
                                                          to: Calendar.current.startOfDay(for: Date()))!
        } else {
            timePicker.dateValue = Date()
        }
        timePicker.widthAnchor.constraint(equalToConstant: 220).isActive = true

        soundPicker.addItems(withTitles: AlarmSounds.names)
        soundPicker.selectItem(withTitle: existing?.soundName ?? AlarmSounds.defaultName)
        soundPicker.target = self
        soundPicker.action = #selector(previewSelectedSound)
        soundPicker.widthAnchor.constraint(equalToConstant: 220).isActive = true

        repeatField.stringValue = existing.map { compactDuration($0.interval) } ?? "5m"
        repeatField.placeholderString = "e.g. 5m, 1:30, or 1h 30m"
        repeatField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        func row(_ labelText: String, _ control: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: labelText)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            return row
        }

        validationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: isEditing ? "Save Changes" : "Add Alarm", target: self, action: #selector(submit))
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var buttonViews: [NSView] = []
        if isEditing {
            let delete = NSButton(title: "Delete", target: self, action: #selector(deleteAlarm))
            delete.contentTintColor = .systemRed
            buttonViews.append(delete)
        }
        buttonViews.append(contentsOf: [spacer, cancel, save])
        let buttons = NSStackView(views: buttonViews)
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.widthAnchor.constraint(equalToConstant: 380).isActive = true

        root.addArrangedSubview(title)
        root.addArrangedSubview(description)
        root.setCustomSpacing(20, after: description)
        root.addArrangedSubview(row("Name", nameField))
        root.addArrangedSubview(row("First alert", timePicker))
        root.addArrangedSubview(row("Sound", soundPicker))
        root.addArrangedSubview(row("Repeat", repeatField))
        root.addArrangedSubview(validationLabel)
        root.setCustomSpacing(20, after: validationLabel)
        root.addArrangedSubview(buttons)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 428, height: 338),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Relarm"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = root
        nameField.nextKeyView = timePicker
        timePicker.nextKeyView = soundPicker
        soundPicker.nextKeyView = repeatField
        repeatField.nextKeyView = cancel
        window.initialFirstResponder = nameField
        window.center()
    }

    func run() -> Result? {
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        return result
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
        guard let interval, interval >= 60 else { return showValidation("Enter a repeat interval of at least one minute.") }
        let components = Calendar.current.dateComponents([.hour, .minute], from: timePicker.dateValue)
        result = .saved(Selection(name: name, soundName: soundPicker.titleOfSelectedItem ?? AlarmSounds.defaultName,
                                  secondsSinceMidnight: (components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60,
                                  interval: interval))
        previewSound?.stop()
        close(with: .OK)
    }

    private func showValidation(_ text: String) {
        validationLabel.stringValue = text
        validationLabel.isHidden = false
    }

    @objc private func cancel() {
        previewSound?.stop()
        close(with: .cancel)
    }

    @objc private func deleteAlarm() {
        result = .delete
        previewSound?.stop()
        close(with: .stop)
    }

    private func close(with response: NSApplication.ModalResponse) {
        window.orderOut(nil)
        NSApp.stopModal(withCode: response)
    }

    func windowWillClose(_ notification: Notification) {
        previewSound?.stop()
        if NSApp.modalWindow == window { NSApp.stopModal(withCode: .cancel) }
    }
}

private func compactDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainder = seconds % 60
    var parts: [String] = []
    if hours > 0 { parts.append("\(hours)h") }
    if minutes > 0 { parts.append("\(minutes)m") }
    if remainder > 0 { parts.append("\(remainder)s") }
    return parts.joined(separator: " ")
}

private enum AlarmSounds {
    // These are the public, built-in NSSound names that a third-party macOS
    // app can depend on. Clock's Radial tone is private to the Clock app.
    static let names = ["Glass", "Basso", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    static let defaultName = "Glass"
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
