import AppKit
import UserNotifications
import RelarmCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
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
        updateStatusIcon()
        // A menu on the status item opens on either button; the delegate refills
        // it each time so the alarm list is current.
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        // Installed up front; only displayed while the app is a regular app.
        NSApp.mainMenu = makeMainMenu()
        restoreAlarms()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ringingSounds.values.forEach { $0.stop() }
    }

    // Reopening the app (Finder, `open`, Launchpad) brings the alarms window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showAlarmsWindow()
        return true
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
        // Alarms saved by an earlier install never asked for permission here.
        if alarms.contains(where: \.isEnabled) { requestNotificationsIfNeeded() }
    }

    @objc private func editFromMenu(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let id = UUID(uuidString: text),
              let alarm = alarms.first(where: { $0.id == id }) else { return }
        presentForm(existing: alarm)
    }

    // Relarm lives in the status bar, but a visible window deserves a real menu
    // bar and Dock presence: become a regular app until that window closes.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Relarm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Relarm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Relarm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        // undo:/redo: have no typed counterpart; the rest resolve on the field editor.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.windowsMenu = windowMenu
        return main
    }

    private func showAlarmsWindow() {
        NSApp.setActivationPolicy(.regular)
        if listWindow == nil {
            let controller = AlarmListWindowController()
            controller.onAdd = { [weak self] in self?.addAlarm() }
            controller.onEdit = { [weak self] id in
                guard let self, let alarm = self.alarms.first(where: { $0.id == id }) else { return }
                self.presentForm(existing: alarm)
            }
            controller.onDuplicate = { [weak self] id in self?.duplicateAlarm(id: id) }
            controller.onToggle = { [weak self] id, enabled in self?.setEnabled(id: id, enabled: enabled) }
            controller.onDelete = { [weak self] id in self?.deleteAlarm(id: id) }
            controller.onClose = { NSApp.setActivationPolicy(.accessory) }
            listWindow = controller
        }
        listWindow?.refresh(alarms)
        activateApp()
        listWindow?.show()
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String = "", represents: Any? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = represents
        menu.addItem(item)
    }

    @objc private func addAlarm() { presentForm(existing: nil) }

    @objc private func openAlarms() { showAlarmsWindow() }

    @objc private func openSettings() {
        showAlarmsWindow()
        listWindow?.presentSettings()
    }

    private func presentForm(existing: AlarmConfiguration?) {
        showAlarmsWindow()
        listWindow?.presentAlarmForm(existing: existing) { [weak self] formResult in
            guard let self, let formResult else { return }
            if case .delete = formResult, let existing {
                self.deleteAlarm(id: existing.id)
                return
            }
            guard case let .saved(selection) = formResult else { return }
            self.saveAlarm(selection: selection, existing: existing)
        }
    }

    private func saveAlarm(selection: AlarmFormController.Selection, existing: AlarmConfiguration?) {
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

    // The copy keeps the original's schedule and on/off state, under a new id.
    private func duplicateAlarm(id: UUID) {
        guard var copy = alarms.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.name += " copy"
        alarms.append(copy)
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
        updateStatusIcon()
        listWindow?.refresh(alarms)
    }

    // The badge dot means "something is scheduled", so it tracks enabled alarms.
    private func updateStatusIcon() {
        let symbol = alarms.contains(where: \.isEnabled) ? "bell.badge.fill" : "bell.fill"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Relarm")
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
        let firingAlarm = alarms[index]
        alarms[index].nextFireDate = AlarmSchedule.nextFutureDate(
            after: alarms[index].nextFireDate.addingTimeInterval(Double(alarms[index].interval)),
            interval: alarms[index].interval
        )
        saveAndSchedule()
        deliverAlarm(for: firingAlarm, nextAlarm: alarms.first(where: \.isEnabled))
    }

    private func deliverAlarm(for alarm: AlarmConfiguration, nextAlarm: AlarmConfiguration?) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            let canNotify = [.authorized, .provisional].contains(settings.authorizationStatus)
            // The sound needs no permission. It loops only when a notification offers Stop.
            DispatchQueue.main.async {
                self?.playAlarmSound(for: alarm.id, soundName: alarm.soundName, loops: canNotify)
            }
            guard canNotify else { return }
            let content = UNMutableNotificationContent()
            content.title = alarm.name
            // The scheduled time, so a timer that fires a few ms late still reads ":00".
            let now = clockLabel(alarm.nextFireDate)
            if let nextAlarm {
                content.body = "\(now). Next: \(clockLabel(nextAlarm.nextFireDate))"
            } else {
                content.body = "\(now). No upcoming alarms."
            }
            content.categoryIdentifier = NotificationAction.category
            content.userInfo = ["alarmID": alarm.id.uuidString]
            let request = UNNotificationRequest(identifier: "relarm.ring.\(UUID().uuidString)", content: content, trigger: nil)
            center.add(request)
        }
    }

    private func registerNotificationActions(on center: UNUserNotificationCenter) {
        let snooze = UNNotificationAction(identifier: NotificationAction.snooze, title: "Snooze", options: [])
        let stop = UNNotificationAction(identifier: NotificationAction.stop, title: "Stop", options: [])
        let category = UNNotificationCategory(identifier: NotificationAction.category, actions: [snooze, stop],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    private func playAlarmSound(for id: UUID, soundName: String, loops: Bool) {
        stopAlarmSound(for: id)
        guard let sound = NSSound(named: NSSound.Name(soundName)) else { return }
        sound.loops = loops
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
        activateApp()
        alert.runModal()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let enabled = alarms.filter(\.isEnabled)
        // Items without an action would otherwise be auto-disabled, and dimmed.
        menu.addItem(NSMenuItem(title: "Next Up", action: nil, keyEquivalent: ""))
        if enabled.isEmpty {
            menu.addItem(NSMenuItem(title: "No upcoming alarms", action: nil, keyEquivalent: ""))
        } else {
            for alarm in enabled {
                addItem(to: menu, title: "\(clockLabel(alarm.nextFireDate)): \(alarm.name)",
                        action: #selector(editFromMenu(_:)), represents: alarm.id.uuidString)
            }
        }
        menu.addItem(.separator())
        addItem(to: menu, title: "Open Alarms", action: #selector(openAlarms))
        addItem(to: menu, title: "Quit Relarm", action: #selector(quit), key: "q")
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
