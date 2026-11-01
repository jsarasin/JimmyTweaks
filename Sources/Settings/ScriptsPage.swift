import AppKit

final class ScriptsPageController: SettingsPageController, NSTableViewDataSource, NSTableViewDelegate {
    let scriptsTable = NSTableView()
    let historyTable = NSTableView()
    private var selectedID: String? = "sample.cleanup"
    private let previewToggle = ActionButton("Enable Scripts Preview") {}
    private let rowToggle = ActionButton("Enabled in Preview") {}
    private let nameField = CommitField()
    private let urlField = CommitField()
    private var interval: ActionPopup!
    private let validation = UI.caption("")
    private let emptyScripts = UI.caption("No sample scripts. Add a sample to explore the preview.")
    private let emptyHistory = UI.caption("No sample history. Nothing has been executed.")
    private var scriptScroll: NSScrollView!
    private var historyScroll: NSScrollView!
    private var updatingSelection = false
    private var model: ScriptsPreview { context.preview }
    override func build() {
        let notice = card("Script Preview")
        add(UI.label("These are sample scripts and sample results. Nothing is downloaded, scheduled, or executed."), to: notice)
        previewToggle.setButtonType(.switch); add(previewToggle, to: notice)
        previewToggle.handler = { [weak self] in guard let self = self else { return }; self.model.enabled = self.previewToggle.state == .on; self.refreshValues() }
        metadata(previewToggle, id: "scripts.previewEnabled", label: "Enable Scripts Preview", description: "Enable demonstration editing only. This never starts background work.", keywords: ["recurring", "reoccurring", "stub", "demo", "enable"])
        let samples = card("Sample URL Scripts")
        setupTable(scriptsTable, columns: [("name", "Name", 180), ("url", "Sample URL", 230), ("badge", "", 65)])
        scriptsTable.rowHeight = 32; scriptsTable.allowsEmptySelection = true
        scriptScroll = UI.scrollTable(scriptsTable, height: 135); add(scriptScroll, to: samples); add(emptyScripts, to: samples)
        metadata(scriptsTable, id: "scripts.list", label: "Sample Script List", description: "Compact, fictional URL-based scripts. Select a row to inspect preview fields.", keywords: ["URL", "samples", "scripts", "list"])
        action("Add Sample", id: "scripts.add", description: "Add an in-memory example. No file is created or URL accessed.", to: samples,
               enabled: { [weak self] in self?.model.enabled == true }) { [weak self] in guard let self = self else { return }; self.selectedID = self.model.add(); self.reload() }
        action("Duplicate", id: "scripts.duplicate", description: "Duplicate the selected preview row in memory.", to: samples,
               enabled: { [weak self] in self?.canEdit == true }) { [weak self] in
            guard let self = self, let id = self.selectedID else { return }; self.selectedID = self.model.duplicate(id); self.reload()
        }
        action("Remove", id: "scripts.remove", description: "Remove the selected in-memory sample; no file is deleted.", to: samples,
               enabled: { [weak self] in self?.canEdit == true }) { [weak self] in
            guard let self = self else { return }; self.model.scripts.removeAll { $0.id == self.selectedID }; self.selectedID = self.model.scripts.first?.id; self.reload()
        }
        let detail = card("Selected Sample · Preview Only")
        add(UI.caption("Enable Scripts Preview to edit. Preview values last until Jimmy Tweaks quits."), to: detail)
        add(UI.label("Name"), to: detail); add(nameField, to: detail)
        metadata(nameField, id: "scripts.name", label: "Sample Name", description: "A preview label, between 1 and 80 characters. User-entered names are not indexed globally.", keywords: ["edit", "name", "script"], section: "Selected Sample")
        nameField.commit = { [weak self] text in self?.commitName(text) }
        add(UI.label("Script URL"), to: detail); add(urlField, to: detail)
        metadata(urlField, id: "scripts.url", label: "Script URL", description: "An HTTPS URL string, validated for syntax only. It is never opened, downloaded, or executed.", keywords: ["https", "address", "URL", "sample"], section: "Selected Sample")
        urlField.commit = { [weak self] text in self?.commitURL(text) }
        interval = ActionPopup(items: ScriptsPreview.intervals) { [weak self] index in
            guard let self = self, let row = self.selectedIndex else { return }
            self.model.scripts[row].interval = ScriptsPreview.intervals[index]; self.refreshValues()
        }
        add(UI.horizontal([UI.label("Interval (informational only)"), NSView(), interval]), to: detail)
        metadata(interval, id: "scripts.interval", label: "Sample Interval", description: "An informational interval label. No schedule is registered and no countdown runs.", keywords: ["schedule", "every", "minutes", "hours", "recurring", "reoccurring"], section: "Selected Sample")
        rowToggle.setButtonType(.switch); add(rowToggle, to: detail)
        rowToggle.handler = { [weak self] in
            guard let self = self, let index = self.selectedIndex else { return }
            self.model.scripts[index].enabled = self.rowToggle.state == .on; self.refreshValues()
        }
        metadata(rowToggle, id: "scripts.rowEnabled", label: "Enabled in Preview", description: "Change a selected row's demonstration check state only.", keywords: ["enable", "sample", "toggle"], section: "Selected Sample")
        validation.textColor = .systemRed; validation.isHidden = true; add(validation, to: detail)
        action("Run Now (Preview Only)", id: "scripts.runPreview", description: "Show an explanation that nothing was executed. No history record is appended.", keywords: ["run", "execute", "preview", "stub"], to: detail,
               enabled: { [weak self] in self?.canEdit == true }) { [weak self] in
            self?.context.showMessage?("Preview Only", "Nothing was executed. Reoccurring Scripts is a nonfunctional UI stub.")
        }
        let history = card("Sample Run History")
        add(UI.caption("Fictional examples shown for layout only. No scripts have run."), to: history)
        setupTable(historyTable, columns: [("time", "Example Time", 135), ("name", "Script", 165), ("result", "Sample Result", 110), ("duration", "Sample Duration", 100)])
        historyTable.rowHeight = 30; historyTable.allowsEmptySelection = true
        historyScroll = UI.scrollTable(historyTable, height: 125); add(historyScroll, to: history); add(emptyHistory, to: history)
        metadata(historyTable, id: "scripts.history", label: "Sample Run History", description: "Static fictional times and sample outcomes. These are not actual executions.", keywords: ["success", "failure", "skipped", "run history", "fictional"])
        action("Clear Sample History", id: "scripts.clearHistory", description: "Clear fictional in-memory rows only. Application logs are preserved.", to: history) { [weak self] in self?.model.history.removeAll(); self?.reload() }
        action("Reset Scripts Preview…", id: "scripts.reset", description: "Restore the sample URL scripts and fictional run history.", keywords: ["seed", "reset", "defaults", "example"], to: history) { [weak self] in
            self?.context.confirm?("Reset Scripts Preview?", "Your in-memory preview edits will be replaced by the fixed sample scripts and fictional history. Nothing will run.") { [weak self] in
                self?.model.reset(); self?.selectedID = "sample.cleanup"; self?.reload()
            }
        }
        registerSampleMetadata(); reload()
    }
    override func refreshValues() {
        guard interval != nil else { return }
        if let id = selectedID, !model.scripts.contains(where: { $0.id == id }) {
            selectedID = model.scripts.first?.id; validation.isHidden = true
        }
        registerSampleMetadata()
        super.refreshValues()
        previewToggle.state = model.enabled ? .on : .off
        rowToggle.isEnabled = canEdit; nameField.isEnabled = canEdit; urlField.isEnabled = canEdit; interval.isEnabled = canEdit
        if let index = selectedIndex {
            let row = model.scripts[index]
            if nameField.currentEditor() == nil, validation.isHidden { nameField.stringValue = row.name }
            if urlField.currentEditor() == nil, validation.isHidden { urlField.stringValue = row.url }
            interval.selectItem(withTitle: row.interval); rowToggle.state = row.enabled ? .on : .off
        } else {
            nameField.stringValue = ""; urlField.stringValue = ""; rowToggle.state = .off
        }
        emptyScripts.isHidden = !model.scripts.isEmpty; scriptScroll?.isHidden = model.scripts.isEmpty
        emptyHistory.isHidden = !model.history.isEmpty; historyScroll?.isHidden = model.history.isEmpty
        if let id = selectedID { rowToggle.identifier = NSUserInterfaceItemIdentifier("scripts.row.\(id).enabled") }
        let selection = selectedIndex
        updatingSelection = true
        scriptsTable.reloadData()
        if let selection = selection { scriptsTable.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
        else { scriptsTable.deselectAll(nil) }
        updatingSelection = false
        historyTable.reloadData()
    }
    private var selectedIndex: Int? { model.scripts.firstIndex { $0.id == selectedID } }
    private var canEdit: Bool { model.enabled && selectedIndex != nil }
    func selectSample(_ id: String) { if model.scripts.contains(where: { $0.id == id }) { selectedID = id; reload() } }
    private func reload() {
        validation.isHidden = true; refreshValues()
    }
    private func registerSampleMetadata() {
        context.catalog.remove { $0.id.hasPrefix("scripts.row.") || $0.id.hasPrefix("scripts.seed.") }
        for script in model.scripts {
            let id = "scripts.row.\(script.id).enabled"
            let sampleID = script.id
            context.catalog.register(ControlMetadata(id: id, label: "Enabled in Preview", description: "An in-memory sample check state; no script is scheduled or executed.", keywords: ["sample", "enable", "stub"], section: "Selected Sample",
                destination: SearchDestination(page: .scripts, controlID: "scripts.rowEnabled", sampleID: script.id),
                availability: { [weak self] in
                    guard let self = self, self.model.scripts.contains(where: { $0.id == sampleID }) else { return "This sample has been removed." }
                    return self.model.enabled ? nil : "Enable Scripts Preview to edit."
                }))
        }
        let seedNames = [("sample.cleanup", "Temporary File Cleanup"), ("sample.backup", "Notes Backup"), ("sample.health", "System Health Check")]
        for (id, name) in seedNames where model.scripts.contains(where: { $0.id == id }) {
            context.catalog.register(ControlMetadata(id: "scripts.seed.\(id)", label: name, description: "Fixed fictional URL script example. No content is fetched or run.", keywords: ["sample", "URL", "script"], section: "Samples",
                destination: SearchDestination(page: .scripts, controlID: "scripts.list", sampleID: id)))
        }
    }
    private func commitName(_ text: String) {
        guard canEdit, let index = selectedIndex else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count) else { validation.stringValue = "Use a name between 1 and 80 characters."; validation.isHidden = false; return }
        model.scripts[index].name = name; validation.isHidden = true; scriptsTable.reloadData()
    }
    private func commitURL(_ text: String) {
        guard canEdit, let index = selectedIndex else { return }
        guard ScriptsPreview.validURL(text) else { validation.stringValue = "Enter an HTTPS URL with a host, no credentials or spaces, and at most 2,048 characters."; validation.isHidden = false; return }
        model.scripts[index].url = text; validation.isHidden = true; scriptsTable.reloadData()
    }
    private func setupTable(_ table: NSTableView, columns: [(String, String, CGFloat)]) {
        table.dataSource = self; table.delegate = self; table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; column.minWidth = 50
            table.addTableColumn(column)
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === scriptsTable ? model.scripts.count : model.history.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { tableView === scriptsTable }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, notification.object as? NSTableView === scriptsTable else { return }
        let row = scriptsTable.selectedRow
        selectedID = model.scripts.indices.contains(row) ? model.scripts[row].id : nil
        validation.isHidden = true
        refreshValues()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let text: String
        if tableView === scriptsTable {
            guard model.scripts.indices.contains(row) else { return nil }; let script = model.scripts[row]
            switch column.identifier.rawValue {
            case "name": text = script.name
            case "url": text = script.url.replacingOccurrences(of: "https://", with: "")
            default: text = "Sample"
            }
        } else {
            guard model.history.indices.contains(row) else { return nil }; let record = model.history[row]
            switch column.identifier.rawValue {
            case "time": text = record.time
            case "name": text = record.name
            case "result": text = record.result
            default: text = record.duration
            }
        }
        return UI.cell(text, identifier: column.identifier, table: tableView)
    }
}
