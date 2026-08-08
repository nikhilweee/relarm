import AppKit
import RelarmCore

private extension NSToolbarItem.Identifier {
    static let addAlarm = NSToolbarItem.Identifier("addAlarm")
    static let settings = NSToolbarItem.Identifier("settings")
}

// One column each, so the table aligns them instead of the cell doing it by hand.
private enum Column {
    static let time = NSUserInterfaceItemIdentifier("time")
    static let name = NSUserInterfaceItemIdentifier("name")
    static let next = NSUserInterfaceItemIdentifier("next")
    static let interval = NSUserInterfaceItemIdentifier("interval")
    static let toggle = NSUserInterfaceItemIdentifier("toggle")
}

final class AlarmListWindowController: NSObject, NSWindowDelegate {
    var onAdd: (() -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onToggle: ((UUID, Bool) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onClose: (() -> Void)?

    private var alarms: [AlarmConfiguration] = []
    private let tableView = AlarmTableView()
    private let emptyState = NSTextField(labelWithString: "No alarms yet. Add one to get started.")
    private var window: NSWindow!
    private var formController: AlarmFormController?
    private var settingsController: SettingsController?

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    override init() {
        super.init()
        addColumn(Column.time, width: 105)
        addColumn(Column.name, width: 160, resizes: true)
        addColumn(Column.next, width: 115)
        addColumn(Column.interval, width: 135)
        addColumn(Column.toggle, width: 50)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 8, height: 4)
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(editSelected)
        tableView.menu = rowMenu()
        tableView.onEditKey = { [weak self] in self?.editSelected() }
        tableView.onDeleteKey = { [weak self] in self?.deleteSelected() }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyState.textColor = .secondaryLabelColor
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Relarm"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = content
        window.contentMinSize = NSSize(width: 600, height: 240)
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        if !window.setFrameUsingName("AlarmsWindow") { window.center() }
        window.setFrameAutosaveName("AlarmsWindow")
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        // An accessory app doesn't always win activation; this raises the window anyway.
        window.orderFrontRegardless()
    }

    func presentAlarmForm(existing: AlarmConfiguration?, completion: @escaping (AlarmFormController.Result?) -> Void) {
        guard formController == nil, settingsController == nil else { return }
        let form = AlarmFormController(existing: existing)
        formController = form
        form.beginSheet(for: window) { [weak self] result in
            self?.formController = nil
            completion(result)
        }
    }

    func refresh(_ newAlarms: [AlarmConfiguration]) {
        // Rows are re-sorted on every change, so follow the selection by id.
        let selectedID = alarms.indices.contains(tableView.selectedRow) ? alarms[tableView.selectedRow].id : nil
        alarms = newAlarms
        emptyState.isHidden = !alarms.isEmpty
        tableView.reloadData()
        if let selectedID, let row = alarms.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    // Only the name column takes up the slack when the window is resized.
    private func addColumn(_ identifier: NSUserInterfaceItemIdentifier, width: CGFloat, resizes: Bool = false) {
        let column = NSTableColumn(identifier: identifier)
        column.width = width
        column.resizingMask = resizes ? .autoresizingMask : []
        if resizes { column.minWidth = 120 }
        tableView.addTableColumn(column)
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "AlarmsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Edit Alarm…", action: #selector(editSelected), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Delete Alarm…", action: #selector(deleteSelected), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        return menu
    }

    // A right-click targets the row under the cursor; the keyboard uses the selection.
    private func targetedAlarm() -> AlarmConfiguration? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        return alarms.indices.contains(row) ? alarms[row] : nil
    }

    @objc private func addAlarm() { onAdd?() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // Defaults are read straight from Prefs when a form opens, so nothing to report back.
    @objc func presentSettings() {
        guard formController == nil, settingsController == nil else { return }
        let controller = SettingsController()
        settingsController = controller
        controller.beginSheet(for: window) { [weak self] in
            self?.settingsController = nil
        }
    }

    @objc private func editSelected() {
        guard let alarm = targetedAlarm() else { return }
        onEdit?(alarm.id)
    }

    @objc private func deleteSelected() {
        guard let alarm = targetedAlarm() else { return }
        confirmDelete(of: alarm.name, in: window) { [weak self] confirmed in
            if confirmed { self?.onDelete?(alarm.id) }
        }
    }

    @objc private func toggleAlarm(_ sender: NSSwitch) {
        let row = tableView.row(for: sender)
        guard alarms.indices.contains(row) else { return }
        onToggle?(alarms[row].id, sender.state == .on)
    }
}

extension AlarmListWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { targetedAlarm() != nil }
}

extension AlarmListWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .addAlarm, .settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .addAlarm:
            return toolbarItem(identifier, symbol: "plus", label: "Add Alarm", action: #selector(addAlarm))
        case .settings:
            return toolbarItem(identifier, symbol: "gearshape", label: "Settings", action: #selector(presentSettings))
        default:
            return nil
        }
    }

    private func toolbarItem(_ identifier: NSToolbarItem.Identifier, symbol: String,
                             label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }
}

extension AlarmListWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { alarms.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        UnemphasizedRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let alarm = alarms[row]
        if identifier == Column.toggle {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ToggleCellView
                ?? ToggleCellView(target: self, action: #selector(toggleAlarm(_:)))
            cell.toggle.state = alarm.isEnabled ? .on : .off
            return cell
        }
        // Font is fixed per column, so a recycled cell always has the right one.
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LabelCellView
            ?? LabelCellView(identifier: identifier, font: font(for: identifier))
        cell.textField?.stringValue = text(for: identifier, alarm: alarm)
        cell.textField?.textColor = color(for: identifier, alarm: alarm)
        return cell
    }

    private func font(for identifier: NSUserInterfaceItemIdentifier) -> NSFont {
        switch identifier {
        case Column.time: return .monospacedDigitSystemFont(ofSize: 20, weight: .regular)
        case Column.name: return .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        default: return .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
    }

    private func text(for identifier: NSUserInterfaceItemIdentifier, alarm: AlarmConfiguration) -> String {
        switch identifier {
        case Column.time: return Self.clock.string(from: timeOfDay(alarm.secondsSinceMidnight))
        case Column.name: return alarm.name
        case Column.next: return alarm.isEnabled ? "Next \(Self.clock.string(from: alarm.nextFireDate))" : "Disabled"
        default: return "Every \(durationLabel(alarm.interval))"
        }
    }

    private func color(for identifier: NSUserInterfaceItemIdentifier, alarm: AlarmConfiguration) -> NSColor {
        switch identifier {
        case Column.name: return .labelColor
        case Column.time: return alarm.isEnabled ? .labelColor : .secondaryLabelColor
        default: return .secondaryLabelColor
        }
    }

    private func timeOfDay(_ secondsSinceMidnight: Int) -> Date {
        let midnight = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .second, value: secondsSinceMidnight, to: midnight)!
    }
}

// NSTableView routes clicks on its own, but not Return or Delete.
final class AlarmTableView: NSTableView {
    var onEditKey: (() -> Void)?
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard selectedRow >= 0, let key = event.charactersIgnoringModifiers?.first else {
            return super.keyDown(with: event)
        }
        switch key {
        case "\r", "\u{3}":          // Return, Enter
            onEditKey?()
        case "\u{7f}", "\u{f728}":   // Delete, Forward Delete
            onDeleteKey?()
        default:
            super.keyDown(with: event)
        }
    }
}

private final class LabelCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, font: NSFont) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// An emphasized selection paints the row in the accent colour, which leaves a
// switched-on NSSwitch blue-on-blue. Unemphasized keeps AppKit's own drawing but
// in grey, so the switch stays legible.
private final class UnemphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}

private final class ToggleCellView: NSTableCellView {
    let toggle = NSSwitch()

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        identifier = Column.toggle
        toggle.target = target
        toggle.action = action
        toggle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggle)
        NSLayoutConstraint.activate([
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
