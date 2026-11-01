import AppKit

final class CustomShortcutsPageController: SettingsPageController, NSTableViewDataSource, NSTableViewDelegate {
    let shortcutsTable = NSTableView()
    let actionsTable = NSTableView()
    private let configuration = UI.vertical([])
    private let actionConfiguration = UI.vertical([])
    private let status = UI.caption("")
    private let issue = UI.caption("")
    private var selectedID: UUID?
    private var selectedActionID: UUID?
    private var rows: [ShortcutDefinition] = []
    private var displayed: ShortcutDefinition?
    private var picker: ShortcutActionPickerController?
    private var pickerShortcutID: UUID?
    private var saving = false
    private weak var testButton: NSButton?
    private let dragType = NSPasteboard.PasteboardType("local.jimmytweaks.shortcutAction")
    private var shortcut: ShortcutDefinition? { rows.first { $0.id == selectedID } }

    override func build() {
        let module = card("")
        toggle("Enable Custom Shortcuts", key: .shortcutsEnabled, id: "shortcuts.enabled", description: "Run global keyboard and mouse shortcuts while Jimmy Tweaks is in the background.", keywords: ["hotkey", "keyboard", "mouse", "transparent", "absorbing"], section: "Module", to: module)
        add(status, to: module)
        permissionLink(.accessibility, title: "Accessibility for Absorbing shortcuts…", to: module)
        permissionLink(.inputMonitoring, title: "Input Monitoring for Transparent shortcuts and recording…", to: module)
        let captureLink = permissionLink(.screenRecording, title: "Screen Recording for capture actions…", to: module)
        let retry = ActionButton("Retry Shortcuts") { [weak self] in self?.context.runtime.shortcuts.retry() }
        add(retry, to: module)
        refreshers.append { [weak self, weak retry, weak captureLink] in
            guard let self else { return }
            let service = self.context.runtime.shortcuts
            retry?.isHidden = !service.needsObservationPermission && !service.needsInterceptionPermission
            captureLink?.isHidden = !self.context.preferences.shortcuts.flatMap(\.actions).contains { service.registry.definition($0.actionID)?.requiredPermissions.contains(.screenRecording) == true }
        }
        prepare(shortcutsTable, columns: [("enabled", "", 34),("name","Name",180),("combination","Shortcut",170),("mode","Mode",90)])
        shortcutsTable.identifier = NSUserInterfaceItemIdentifier("shortcuts.list")
        shortcutsTable.headerView = nil
        add(UI.scrollTable(shortcutsTable, height: 155))
        let plus = ActionButton("+") { [weak self] in self?.addShortcut() }; plus.setAccessibilityLabel("Add Shortcut")
        let minus = ActionButton("−") { [weak self] in self?.removeShortcut() }; minus.setAccessibilityLabel("Remove Shortcut")
        add(UI.horizontal([plus, minus, NSView()]))
        metadata(plus, id: "shortcuts.add", label: "Add Shortcut", description: "Create a global keyboard or mouse shortcut.", keywords: ["hotkey", "record"])
        add(configuration)
    }
    override func refreshValues() {
        super.refreshValues()
        guard !saving else { return }
        rows = context.preferences.shortcuts
        status.stringValue = context.runtime.shortcuts.status
        if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) { selectedID = rows.first?.id }
        shortcutsTable.reloadData()
        if let index = rows.firstIndex(where: { $0.id == selectedID }) { shortcutsTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        if shortcut != displayed { rebuild() }
        if let shortcut = shortcut {
            issue.stringValue = context.runtime.shortcuts.message(for: shortcut)
            testButton?.isEnabled = context.preferences.bool(.shortcutsEnabled) && !context.preferences.bool(.suspended) && shortcut.enabled && shortcut.combination != nil
        }
        actionsTable.reloadData()
    }
    private func prepare(_ table: NSTableView, columns: [(String,String,CGFloat)]) {
        table.delegate = self; table.dataSource = self; table.rowHeight = 28; table.allowsEmptySelection = true
        for (id, title, width) in columns { let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column) }
    }
    private func clear(_ stack: NSStackView) { for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() } }
    private func rebuild() {
        if pickerShortcutID != selectedID { picker?.close() }
        displayed = shortcut; clear(configuration)
        guard let shortcut = shortcut else { add(UI.caption("Add a shortcut to begin."), to: configuration); return }
        let title = CommitField(value: shortcut.name)
        title.placeholderString = "Shortcut name"; title.setAccessibilityLabel("Shortcut Name")
        title.commit = { [weak self] name in self?.edit { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Shortcut" : String(name.prefix(120)) } }
        add(UI.label("Shortcut", size: 14, weight: .semibold), to: configuration); add(title, to: configuration)
        let record = ActionButton(shortcut.combination?.display ?? "Record Shortcut…") { [weak self] in
            guard let self = self, let current = self.shortcut else { return }
            self.context.runtime.shortcuts.record(current) { [weak self] combination in
                self?.edit(shortcutID: current.id, validate: true) { $0.combination = combination }
            }
        }
        let clear = ActionButton("Clear") { [weak self] in self?.edit { $0.combination = nil } }
        add(UI.horizontal([record, clear, NSView()]), to: configuration)
        let mode = ActionPopup(items: ["Transparent", "Absorbing"]) { [weak self] index in self?.edit(validate: true) { $0.mode = index == 0 ? .transparent : .absorbing } }
        mode.selectItem(at: shortcut.mode == .transparent ? 0 : 1); mode.setAccessibilityLabel("Shortcut Mode")
        let activation = ActionPopup(items: ["Press", "Release"]) { [weak self] index in self?.edit { $0.activation = index == 0 ? .press : .release } }
        activation.selectItem(at: shortcut.activation == .press ? 0 : 1); activation.setAccessibilityLabel("Shortcut Activation")
        let test = ActionButton("Test Shortcut") { [weak self] in guard let self = self, let id = self.selectedID else { return }; self.context.runtime.shortcuts.test(id) }
        testButton = test
        test.isEnabled = context.preferences.bool(.shortcutsEnabled) && !context.preferences.bool(.suspended) && shortcut.enabled && shortcut.combination != nil
        add(UI.horizontal([UI.label("Mode"),mode, UI.label("Activation"),activation,NSView(),test]), to: configuration)
        issue.stringValue = context.runtime.shortcuts.message(for: shortcut); add(issue, to: configuration)
        add(UI.separator(), to: configuration); add(UI.label("Actions", size: 14, weight: .semibold), to: configuration)
        if actionsTable.tableColumns.isEmpty {
            prepare(actionsTable, columns: [("action","Action",300)]); actionsTable.headerView = nil
            actionsTable.identifier = NSUserInterfaceItemIdentifier("shortcuts.actions")
            actionsTable.registerForDraggedTypes([dragType]); actionsTable.setDraggingSourceOperationMask(.move, forLocal: true)
        }
        actionsTable.reloadData()
        if selectedActionID == nil || !shortcut.actions.contains(where: { $0.id == selectedActionID }) { selectedActionID = shortcut.actions.first?.id }
        if let row = shortcut.actions.firstIndex(where: { $0.id == selectedActionID }) { actionsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        add(UI.scrollTable(actionsTable, height: 135), to: configuration)
        let plus = ActionButton("+") { [weak self] in self?.addAction() }; plus.setAccessibilityLabel("Add Action")
        let minus = ActionButton("−") { [weak self] in self?.removeAction() }; minus.setAccessibilityLabel("Remove Action")
        let up = ActionButton("Up") { [weak self] in self?.moveAction(by: -1) }
        let down = ActionButton("Down") { [weak self] in self?.moveAction(by: 1) }
        add(UI.horizontal([plus, minus, up, down, NSView()]), to: configuration)
        add(actionConfiguration, to: configuration); rebuildActionEditor()
    }
    private func rebuildActionEditor() {
        clear(actionConfiguration)
        guard let action = shortcut?.actions.first(where: { $0.id == selectedActionID }) else { return }
        let registry = context.runtime.shortcuts.registry
        guard let definition = registry.definition(action.actionID) else { add(UI.caption("Unavailable action: \(action.actionID)"), to: actionConfiguration); return }
        add(UI.caption(definition.description), to: actionConfiguration)
        if let editor = definition.editor {
            let actionID = action.id
            add(editor(action.parameters) { [weak self] parameters in
                self?.edit(rebuild: false) { shortcut in
                    guard let index = shortcut.actions.firstIndex(where: { $0.id == actionID }) else { return }
                    shortcut.actions[index].parameters = parameters
                }
            }, to: actionConfiguration)
        }
    }
    private func edit(shortcutID: UUID? = nil, validate: Bool = false, rebuild: Bool = true, _ mutate: (inout ShortcutDefinition) -> Void) {
        guard var current = rows.first(where: { $0.id == (shortcutID ?? selectedID) }) else { return }
        mutate(&current)
        if validate, let error = ShortcutConflictChecker.error(for: current, among: rows, gestures: context.preferences.gesture) {
            context.showMessage?("Shortcut Unavailable", error); displayed = nil; self.rebuild(); return
        }
        guard let index = rows.firstIndex(where: { $0.id == current.id }) else { return }
        rows[index] = current; save()
        shortcutsTable.reloadData(); actionsTable.reloadData()
        if current.id == selectedID {
            displayed = current
            if rebuild { self.rebuild() }
        }
    }
    private func save() { saving = true; context.preferences.shortcuts = rows; saving = false; status.stringValue = context.runtime.shortcuts.status }
    private func addShortcut() {
        let row = ShortcutDefinition(); rows.append(row); selectedID = row.id; selectedActionID = nil; save(); displayed = nil; refreshValues()
    }
    private func removeShortcut() {
        guard let id = selectedID else { return }; context.runtime.shortcuts.runner.cancel(id)
        rows.removeAll { $0.id == id }; selectedID = nil; save(); displayed = nil; refreshValues()
    }
    private func addAction() {
        guard let shortcutID = selectedID, let parent = view.window else { return }
        if let picker = picker, pickerShortcutID == shortcutID {
            picker.present(relativeTo: parent); return
        }
        picker?.close()
        let controller = ShortcutActionPickerController(registry: context.runtime.shortcuts.registry) { [weak self] definition in
            guard let self = self, self.selectedID == shortcutID else { return }
            let instance = ShortcutActionInstance(actionID: definition.id, parameters: definition.defaults)
            self.selectedActionID = instance.id; self.edit { $0.actions.append(instance) }
        }
        controller.onClose = { [weak self] closed in
            guard let self = self, self.picker === closed else { return }
            self.picker = nil; self.pickerShortcutID = nil
        }
        picker = controller; pickerShortcutID = shortcutID
        controller.present(relativeTo: parent)
    }
    private func removeAction() { guard let id = selectedActionID else { return }; edit { $0.actions.removeAll { $0.id == id } }; selectedActionID = nil; rebuild() }
    private func moveAction(by offset: Int) {
        guard let actions = shortcut?.actions, let from = actions.firstIndex(where: { $0.id == selectedActionID }), actions.indices.contains(from + offset) else { return }
        edit { $0.actions.swapAt(from, from + offset) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === shortcutsTable ? rows.count : shortcut?.actions.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        if tableView === shortcutsTable {
            guard rows.indices.contains(row) else { return nil }; let shortcut = rows[row]
            if column.identifier.rawValue == "enabled" {
                let button = ActionButton("") {}; button.setButtonType(.switch); button.state = shortcut.enabled ? .on : .off; button.setAccessibilityLabel("Enable \(shortcut.name)")
                button.handler = { [weak self, weak button] in
                    guard let self = self, let index = self.rows.firstIndex(where: { $0.id == shortcut.id }) else { return }
                    self.rows[index].enabled = button?.state == .on; self.save(); self.displayed = nil; self.refreshValues()
                }; return button
            }
            let value: String
            switch column.identifier.rawValue { case "name": value = shortcut.name; case "mode": value = shortcut.mode.rawValue; default: value = shortcut.combination?.display ?? "Not assigned" }
            return UI.cell(value, identifier: column.identifier, table: tableView)
        }
        guard let actions = shortcut?.actions, actions.indices.contains(row) else { return nil }; let action = actions[row]
        let definition = context.runtime.shortcuts.registry.definition(action.actionID)
        let summary = definition?.summary(action.parameters) ?? ""
        return UI.cell((definition?.name ?? "Unavailable: \(action.actionID)") + (summary.isEmpty ? "" : " · \(summary)"), identifier: column.identifier, table: tableView)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === shortcutsTable {
            guard rows.indices.contains(table.selectedRow), selectedID != rows[table.selectedRow].id else { return }
            selectedID = rows[table.selectedRow].id; selectedActionID = nil; rebuild()
        } else {
            guard let actions = shortcut?.actions, actions.indices.contains(table.selectedRow) else { return }
            selectedActionID = actions[table.selectedRow].id; rebuildActionEditor()
        }
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === actionsTable, let actions = shortcut?.actions, actions.indices.contains(row), let shortcutID = selectedID else { return nil }
        let item = NSPasteboardItem(); item.setString("\(shortcutID.uuidString)/\(actions[row].id.uuidString)", forType: dragType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === actionsTable, operation == .above, info.draggingSource as? NSTableView === actionsTable,
              let text = info.draggingPasteboard.string(forType: dragType), text.hasPrefix((selectedID?.uuidString ?? "") + "/") else { return [] }
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === actionsTable, dropOperation == .above, info.draggingSource as? NSTableView === actionsTable,
              let text = info.draggingPasteboard.string(forType: dragType), text.hasPrefix((selectedID?.uuidString ?? "") + "/"), let id = UUID(uuidString: String(text.split(separator: "/").last ?? "")), let actions = shortcut?.actions, let from = actions.firstIndex(where: { $0.id == id }), (0...actions.count).contains(row) else { return false }
        selectedActionID = id
        edit { let action = $0.actions.remove(at: from); $0.actions.insert(action, at: row > from ? row - 1 : row) }
        return true
    }
}

final class ShortcutActionPickerController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let registry: ShortcutActionRegistry
    private let selected: (ShortcutActionDefinition) -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private var entries: [(String, ShortcutActionDefinition?)] = []
    private var observer: NSObjectProtocol?
    private var parentCloseObserver: NSObjectProtocol?
    var onClose: ((ShortcutActionPickerController) -> Void)?
    init(registry: ShortcutActionRegistry, selected: @escaping (ShortcutActionDefinition) -> Void) {
        self.registry = registry; self.selected = selected
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 410), styleMask: [.titled,.closable,.resizable,.utilityWindow], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Add Action"; window.isReleasedWhenClosed = false
        window.delegate = self; window.isFloatingPanel = true; window.hidesOnDeactivate = true
        window.becomesKeyOnlyIfNeeded = false
        window.contentMinSize = NSSize(width: 430, height: 300)
        search.placeholderString = "Search actions"; search.delegate = self
        table.headerView = nil; table.delegate = self; table.dataSource = self; table.rowHeight = 48
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action")))
        table.target = self; table.doubleAction = #selector(addSelected)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        let add = ActionButton("Add") { [weak self] in self?.addSelected() }
        let cancel = ActionButton("Cancel") { [weak self] in self?.close() }
        cancel.keyEquivalent = "\u{1b}"
        let content = UI.vertical([search,scroll,UI.horizontal([NSView(),cancel,add])], spacing: 12)
        UI.pin(content, in: window.contentView!, inset: 18)
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        observer = NotificationCenter.default.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        if let parentCloseObserver = parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
    }
    func present(relativeTo parent: NSWindow) {
        guard let window = window else { return }
        if window.parent !== parent {
            window.parent?.removeChildWindow(window)
            if let parentCloseObserver = parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
            parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in self?.close() }
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.midY - window.frame.height / 2))
            parent.addChildWindow(window, ordered: .above)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(search)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = window else { return }
        window.parent?.removeChildWindow(window)
        if let parentCloseObserver = parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver); self.parentCloseObserver = nil }
        onClose?(self)
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    private func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.removeAll()
        for category in registry.categories {
            let items = registry.definitions.filter { $0.category == category && (query.isEmpty || ($0.name + " " + $0.description + " " + category).localizedCaseInsensitiveContains(query)) }
            guard !items.isEmpty || category == "Scripts" && query.isEmpty else { continue }
            entries.append((category, nil)); entries += items.map { ($0.name, Optional($0)) }
            if items.isEmpty { entries.append(("No scripts available. Scripts appear here when their execution service is available.", nil)) }
        }
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { entries[row].1 != nil }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let stack = UI.vertical([UI.label(entry.0, size: 12, weight: entry.1 == nil ? .semibold : .regular), UI.caption(entry.1?.description ?? "")], spacing: 3)
        let cell = NSView(); UI.pin(stack, in: cell, inset: 5); return cell
    }
    @objc private func addSelected() {
        guard entries.indices.contains(table.selectedRow), let definition = entries[table.selectedRow].1 else { return }
        selected(definition); close()
    }
}
