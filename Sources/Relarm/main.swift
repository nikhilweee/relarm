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
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var alarms: [AlarmConfiguration] = []
    private var timers: [UUID: Timer] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "Relarm")
        button.target = self
        button.action = #selector(showMenu)
        restoreAlarms()
    }

    func applicationWillTerminate(_ notification: Notification) {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    private func restoreAlarms() {
        alarms = Prefs.alarms
        for index in alarms.indices where alarms[index].isEnabled {
            alarms[index].nextFireDate = AlarmSchedule.nextFutureDate(
                after: alarms[index].nextFireDate, interval: alarms[index].interval
            )
        }
        saveAndSchedule()
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        if alarms.isEmpty {
            let empty = NSMenuItem(title: "No alarms", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for alarm in alarms {
                let item = NSMenuItem(title: alarm.name, action: nil, keyEquivalent: "")
                item.submenu = alarmMenu(for: alarm)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        addItem(to: menu, title: "Add Alarm…", action: #selector(addAlarm))
        menu.addItem(.separator())
        addItem(to: menu, title: "Quit Relarm", action: #selector(quit), key: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func alarmMenu(for alarm: AlarmConfiguration) -> NSMenu {
        let menu = NSMenu(title: alarm.name)
        if alarm.isEnabled {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let next = NSMenuItem(title: "Next: \(formatter.string(from: alarm.nextFireDate))", action: nil, keyEquivalent: "")
            next.isEnabled = false
            menu.addItem(next)
            let repeatLabel = NSMenuItem(title: "Repeats every \(durationLabel(alarm.interval))", action: nil, keyEquivalent: "")
            repeatLabel.isEnabled = false
            menu.addItem(repeatLabel)
        } else {
            let disabled = NSMenuItem(title: "Disabled", action: nil, keyEquivalent: "")
            disabled.isEnabled = false
            menu.addItem(disabled)
        }
        menu.addItem(.separator())
        let enable = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enable.target = self
        enable.state = alarm.isEnabled ? .on : .off
        enable.representedObject = alarm.id.uuidString
        menu.addItem(enable)
        addItem(to: menu, title: "Edit Alarm…", action: #selector(editAlarm(_:)), represents: alarm.id.uuidString)
        addItem(to: menu, title: "Delete Alarm", action: #selector(deleteAlarm(_:)), represents: alarm.id.uuidString)
        return menu
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String = "", represents: Any? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = represents
        menu.addItem(item)
    }

    @objc private func addAlarm() { presentForm(existing: nil) }

    @objc private func editAlarm(_ sender: NSMenuItem) {
        guard let id = alarmID(from: sender), let alarm = alarms.first(where: { $0.id == id }) else { return }
        presentForm(existing: alarm)
    }

    private func presentForm(existing: AlarmConfiguration?) {
        let form = AlarmFormController(existing: existing)
        NSApp.activate(ignoringOtherApps: true)
        guard let selection = form.run() else { return }
        let alarm = AlarmConfiguration(
            id: existing?.id ?? UUID(), name: selection.name,
            isEnabled: existing?.isEnabled ?? true,
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

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        guard let id = alarmID(from: sender), let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[index].isEnabled.toggle()
        if alarms[index].isEnabled {
            alarms[index].nextFireDate = AlarmSchedule.nextFutureDate(
                after: alarms[index].nextFireDate, interval: alarms[index].interval
            )
        }
        saveAndSchedule()
    }

    @objc private func deleteAlarm(_ sender: NSMenuItem) {
        guard let id = alarmID(from: sender) else { return }
        alarms.removeAll { $0.id == id }
        saveAndSchedule()
    }

    private func alarmID(from item: NSMenuItem) -> UUID? {
        guard let text = item.representedObject as? String else { return nil }
        return UUID(uuidString: text)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func saveAndSchedule() {
        Prefs.alarms = alarms
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for alarm in alarms where alarm.isEnabled {
            schedule(alarm)
        }
    }

    private func schedule(_ alarm: AlarmConfiguration) {
        let timer = Timer(fireAt: alarm.nextFireDate.addingTimeInterval(1), interval: 0,
                          target: self, selector: #selector(alarmFired(_:)), userInfo: alarm.id.uuidString, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        timers[alarm.id] = timer

        let content = UNMutableNotificationContent()
        content.title = alarm.name
        content.body = "Your repeating alarm is ringing."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: notificationID(for: alarm.id), content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, alarm.nextFireDate.timeIntervalSinceNow), repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    @objc private func alarmFired(_ timer: Timer) {
        guard let text = timer.userInfo as? String, let id = UUID(uuidString: text),
              let index = alarms.firstIndex(where: { $0.id == id }), alarms[index].isEnabled else { return }
        timers[id] = nil
        alarms[index].nextFireDate = AlarmSchedule.nextFutureDate(
            after: alarms[index].nextFireDate.addingTimeInterval(Double(alarms[index].interval)),
            interval: alarms[index].interval
        )
        saveAndSchedule()
    }

    private func notificationID(for id: UUID) -> String { "relarm.\(id.uuidString)" }

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
        completionHandler([.banner, .sound])
    }
}

private final class AlarmFormController: NSObject, NSWindowDelegate {
    struct Selection {
        let name: String
        let secondsSinceMidnight: Int
        let interval: Int
    }

    private let nameField = NSTextField()
    private let timePicker = NSDatePicker()
    private let intervalPicker = NSPopUpButton()
    private let customIntervalField = NSTextField(string: "5m")
    private let validationLabel = NSTextField(labelWithString: "")
    private var window: NSWindow!
    private var result: Selection?
    private let isEditing: Bool

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

        intervalPicker.addItems(withTitles: ["Every 5 minutes", "Every 15 minutes", "Every 30 minutes", "Every hour", "Custom…"])
        intervalPicker.target = self
        intervalPicker.action = #selector(intervalSelectionChanged)
        intervalPicker.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let presetIntervals = [5 * 60, 15 * 60, 30 * 60, 60 * 60]
        if let interval = existing?.interval, let index = presetIntervals.firstIndex(of: interval) {
            intervalPicker.selectItem(at: index)
        } else if let interval = existing?.interval {
            intervalPicker.selectItem(at: 4)
            customIntervalField.stringValue = compactDuration(interval)
        }

        customIntervalField.placeholderString = "e.g. 45m or 1h 30m"
        customIntervalField.isEnabled = intervalPicker.indexOfSelectedItem == 4
        customIntervalField.widthAnchor.constraint(equalToConstant: 220).isActive = true

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
        let buttons = NSStackView(views: [spacer, cancel, save])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.widthAnchor.constraint(equalToConstant: 380).isActive = true

        root.addArrangedSubview(title)
        root.addArrangedSubview(description)
        root.setCustomSpacing(20, after: description)
        root.addArrangedSubview(row("Name", nameField))
        root.addArrangedSubview(row("First alert", timePicker))
        root.addArrangedSubview(row("Repeat", intervalPicker))
        root.addArrangedSubview(row("Custom interval", customIntervalField))
        root.addArrangedSubview(validationLabel)
        root.setCustomSpacing(20, after: validationLabel)
        root.addArrangedSubview(buttons)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 428, height: 338),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Relarm"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = root
        window.center()
    }

    func run() -> Selection? {
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        return result
    }

    @objc private func intervalSelectionChanged() {
        customIntervalField.isEnabled = intervalPicker.indexOfSelectedItem == 4
        validationLabel.isHidden = true
    }

    @objc private func submit() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return showValidation("Give this alarm a name.") }
        let interval: Int?
        switch intervalPicker.indexOfSelectedItem {
        case 0: interval = 5 * 60
        case 1: interval = 15 * 60
        case 2: interval = 30 * 60
        case 3: interval = 60 * 60
        default: interval = parseDuration(customIntervalField.stringValue)
        }
        guard let interval, interval >= 60 else { return showValidation("Enter a repeat interval of at least one minute.") }
        let components = Calendar.current.dateComponents([.hour, .minute], from: timePicker.dateValue)
        result = Selection(name: name, secondsSinceMidnight: (components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60,
                           interval: interval)
        close(with: .OK)
    }

    private func showValidation(_ text: String) {
        validationLabel.stringValue = text
        validationLabel.isHidden = false
    }

    @objc private func cancel() { close(with: .cancel) }

    private func close(with response: NSApplication.ModalResponse) {
        window.orderOut(nil)
        NSApp.stopModal(withCode: response)
    }

    func windowWillClose(_ notification: Notification) {
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
