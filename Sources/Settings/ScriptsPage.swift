import AppKit

final class ScriptsPageController: SettingsPageController, NSTableViewDataSource, NSTableViewDelegate {
    let scriptsTable = NSTableView(), historyTable = NSTableView()
    private var selectedID: UUID?, selectedRunID: UUID?
    private var draft: RequestDefinition?
    private var updating = false
    private let moduleToggle = ActionButton("Enable Recurring Requests") {}
    private let rowToggle = ActionButton("Enable scheduled runs for this request") {}
    private let status = UI.caption(""), validation = UI.caption("")
    private let nameField = CommitField(), urlField = CommitField()
    private let minutesField = CommitField(value: "60"), timeField = CommitField(value: "09:00")
    private let bodyEditor = NSTextView(), responseEditor = NSTextView()
    private let headerRows = NSStackView()
    private var method: ActionPopup!, bodyKind: ActionPopup!, schedule: ActionPopup!
    private var customRow: NSStackView!, dailyRow: NSStackView!
    private let emptyRequests = UI.caption("No requests yet. Add a request to configure an API call.")
    private let emptyHistory = UI.caption("No requests have run yet.")
    private static let intervals = [5, 30, 60, 360, 1440]
    private static let schedules = ["Manual Only", "Every 5 minutes", "Every 30 minutes", "Every 1 hour", "Every 6 hours", "Every day", "Custom interval", "Daily at time"]
    private var model: RequestController { context.requests }

    override func build() {
        let module = card("HTTP Requests")
        add(UI.caption("Send HTTP/API requests manually or on a schedule while Jimmy Tweaks runs. Closing Settings keeps schedules active. Quit cancels all requests and timers. Missed runs are skipped."), to: module)
        moduleToggle.setButtonType(.switch); add(moduleToggle, to: module); add(status, to: module)
        metadata(moduleToggle, id: "scripts.enabled", label: "Enable Recurring Requests", description: "Enable HTTP requests and scheduling. Suspend All pauses requests.", keywords: ["HTTP", "API", "recurring", "reoccurring", "scripts", "webhook"])
        metadata(status, id: "scripts.status", label: "Request Status", description: "Current scheduling, suspension, and storage status.", keywords: ["running", "error", "paused"])
        moduleToggle.handler = { [weak self] in guard let self else { return }; self.perform { try self.model.setEnabled(self.moduleToggle.state == .on) } }
        let list = card("Saved Requests")
        setupTable(scriptsTable, columns: [("name", "Name", 130), ("method", "Method", 65), ("state", "State", 80), ("next", "Next Run", 125), ("result", "Last Result", 95)])
        add(UI.scrollTable(scriptsTable, height: 135), to: list); add(emptyRequests, to: list)
        scriptsTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        metadata(scriptsTable, id: "scripts.list", label: "Saved Requests", description: "Select a request to edit its method, URL, headers, body, and optional schedule.", keywords: ["list", "HTTP", "API", "scripts"])
        action("Add Request", id: "scripts.add", description: "Create a manual-only request with an empty URL.", to: list) { [weak self] in
            guard let self else { return }; self.perform { let id = try self.model.add(); self.selectRequest(id) }
        }
        action("Duplicate", id: "scripts.duplicate", description: "Copy the saved request with scheduling disabled.", to: list, enabled: { [weak self] in self?.selectedID != nil }) { [weak self] in
            guard let self, let id = self.selectedID else { return }; self.perform { let copy = try self.model.duplicate(id); self.selectRequest(copy) }
        }
        action("Remove", id: "scripts.remove", description: "Remove the saved request and cancel its active run. History is retained.", to: list, enabled: { [weak self] in self?.selectedID != nil }) { [weak self] in
            guard let self, let id = self.selectedID else { return }; self.perform { try self.model.remove(id) }
        }
        let detail = card("Selected Request")
        add(UI.caption("Save before selecting another request. Run Once saves and sends the current request. Use Manual Only for requests without a schedule. No automatic retries or redirects."), to: detail)
        field("Name", nameField, id: "scripts.name", description: "Request name, 1–80 characters. Names are excluded from global search.", to: detail)
        field("URL", urlField, id: "scripts.url", description: "HTTP or HTTPS endpoint, including localhost and private-network addresses.", to: detail)
        method = ActionPopup(items: RequestDefinition.methods) { [weak self] _ in self?.refreshEditorAvailability() }
        add(UI.horizontal([UI.label("HTTP Method"), NSView(), method]), to: detail)
        metadata(method, id: "scripts.method", label: "HTTP Method", description: "GET, HEAD, POST, PUT, PATCH, DELETE, or OPTIONS.", keywords: ["JSON", "API", "post", "get"])
        add(UI.label("Headers"), to: detail)
        headerRows.orientation = .vertical; headerRows.alignment = .leading; headerRows.spacing = 8; add(headerRows, to: detail)
        action("Add Header", id: "scripts.headers.add", description: "Add an HTTP header name and value, including API authorization.", to: detail, enabled: { [weak self] in self?.draft != nil }) { [weak self] in
            guard let self, self.draft != nil else { return }; self.view.window?.makeFirstResponder(nil)
            self.draft?.headers.append(RequestHeader(name: "", value: "")); self.renderHeaders()
        }
        bodyKind = ActionPopup(items: RequestBodyKind.allCases.map(\.rawValue)) { [weak self] _ in self?.refreshEditorAvailability() }
        add(UI.horizontal([UI.label("Request Body"), NSView(), bodyKind]), to: detail)
        metadata(bodyKind, id: "scripts.bodyKind", label: "Request Body Type", description: "None, JSON, or plain text. GET and HEAD do not send bodies.", keywords: ["payload", "content type"])
        add(textArea(bodyEditor, height: 125, editable: true), to: detail)
        metadata(bodyEditor, id: "scripts.body", label: "Request Body", description: "UTF-8 JSON or plain-text payload, up to 1 MiB. Content is excluded from global search.", keywords: ["JSON", "payload", "text"])
        schedule = ActionPopup(items: Self.schedules) { [weak self] _ in self?.refreshEditorAvailability() }
        add(UI.horizontal([UI.label("Schedule"), NSView(), schedule]), to: detail)
        metadata(schedule, id: "scripts.schedule", label: "Request Schedule", description: "Manual Only, an interval, or a daily local clock time. Missed runs are skipped.", keywords: ["interval", "every", "daily", "time", "minutes", "manual"])
        customRow = UI.horizontal([UI.label("Interval in minutes"), minutesField]); add(customRow, to: detail)
        dailyRow = UI.horizontal([UI.label("Daily local time (HH:mm)"), timeField]); add(dailyRow, to: detail)
        metadata(minutesField, id: "scripts.minutes", label: "Custom Interval Minutes", description: "A whole number from 1 to 525,600 minutes.")
        metadata(timeField, id: "scripts.time", label: "Daily Request Time", description: "Local 24-hour time, for example 09:30. Runs once per day, accounting for daylight saving time.")
        rowToggle.setButtonType(.switch); add(rowToggle, to: detail)
        metadata(rowToggle, id: "scripts.rowEnabled", label: "Enable Scheduled Request", description: "Include this saved request in its schedule when the module is enabled.", keywords: ["enable", "schedule"])
        validation.textColor = .systemRed; validation.isHidden = true; add(validation, to: detail)
        action("Save", id: "scripts.save", description: "Validate and persist the selected request and optional schedule.", to: detail, enabled: { [weak self] in self?.draft != nil }) { [weak self] in
            guard let self else { return }; self.perform { try self.saveDraft() }
        }
        action("Run Once", id: "scripts.run", description: "Save and send this request once, with or without a schedule. Enable the module and turn Suspend All off first.", keywords: ["execute", "HTTP", "API", "manual", "run now"], to: detail, enabled: { [weak self] in
            guard let self, let id = self.selectedID else { return false }; return self.model.available && !self.model.isRunning(id)
        }) { [weak self] in
            guard let self, let id = self.selectedID else { return }; self.perform { try self.saveDraft(); try self.model.runNow(id) }
        }
        action("Cancel Request", id: "scripts.cancel", description: "Cancel the active request. Server-side work already accepted cannot be undone.", to: detail, enabled: { [weak self] in
            guard let self, let id = self.selectedID else { return false }; return self.model.isRunning(id)
        }) { [weak self] in guard let self, let id = self.selectedID else { return }; self.model.cancel(id) }
        let history = card("Run History")
        add(UI.caption("Latest 100 runs, stored locally. Select a run to inspect its response. Bodies retain up to 64 KiB. Request headers, bodies, and responses may contain private API data."), to: history)
        setupTable(historyTable, columns: [("time", "Started", 135), ("name", "Request", 140), ("status", "HTTP", 60), ("result", "Result", 130), ("duration", "Duration", 70)])
        add(UI.scrollTable(historyTable, height: 150), to: history); add(emptyHistory, to: history)
        historyTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        metadata(historyTable, id: "scripts.history", label: "Request Run History", description: "Actual request results, HTTP status, errors, duration, and responses.", keywords: ["success", "failure", "response", "history"])
        add(textArea(responseEditor, height: 220, editable: false), to: history)
        metadata(responseEditor, id: "scripts.response", label: "HTTP Response", description: "Saved response headers and bounded body, displayed as selectable inert text.", keywords: ["JSON", "response", "headers", "body"])
        action("Clear History", id: "scripts.clearHistory", description: "Delete saved request responses and run records.", to: history) { [weak self] in
            guard let self else { return }; self.perform { try self.model.clearHistory() }
        }
        action("Reset Recurring Requests…", id: "scripts.reset", description: "Cancel all requests, remove definitions and responses, and disable the module.", to: history) { [weak self] in
            self?.context.confirm?("Reset Recurring Requests?", "All saved requests and responses will be removed, active requests cancelled, and the module disabled.") { [weak self] in
                guard let self else { return }; self.perform { try self.model.reset(); self.draft = nil; self.refreshValues() }
            }
        }
        selectedID = model.state.requests.first?.id; loadSelection(); refreshValues()
    }
    private func field(_ title: String, _ field: CommitField, id: String, description: String, to parent: NSStackView) {
        add(UI.label(title), to: parent); add(field, to: parent)
        metadata(field, id: id, label: title, description: description, keywords: ["HTTP", "request"])
    }
    private func textArea(_ editor: NSTextView, height: CGFloat, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .lineBorder
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        editor.isRichText = false; editor.isEditable = editable; editor.isSelectable = true
        editor.minSize = NSSize(width: 0, height: height); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor; return scroll
    }
    private func renderHeaders() {
        context.catalog.remove { $0.id.hasPrefix("scripts.header.") }
        controls = controls.filter { !$0.key.hasPrefix("scripts.header.") }
        headerRows.arrangedSubviews.forEach { headerRows.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, header) in (draft?.headers ?? []).enumerated() {
            let name = CommitField(value: header.name), value = CommitField(value: header.value)
            name.placeholderString = "Header name"; value.placeholderString = "Value"
            name.commit = { [weak self] text in guard self?.draft?.headers.indices.contains(index) == true else { return }; self?.draft?.headers[index].name = text }
            value.commit = { [weak self] text in guard self?.draft?.headers.indices.contains(index) == true else { return }; self?.draft?.headers[index].value = text }
            let remove = ActionButton("Remove") { [weak self] in
                guard let self else { return }; self.view.window?.makeFirstResponder(nil)
                guard self.draft?.headers.indices.contains(index) == true else { return }; self.draft?.headers.remove(at: index); self.renderHeaders()
            }
            add(UI.horizontal([name, value, remove]), to: headerRows)
            name.widthAnchor.constraint(equalTo: value.widthAnchor, multiplier: 0.65).isActive = true
            metadata(name, id: "scripts.header.\(index).name", label: "Header Name", description: "HTTP header name. Duplicate names are rejected.")
            metadata(value, id: "scripts.header.\(index).value", label: "Header Value", description: "HTTP header value, including API authorization if needed. Values are stored locally.")
            metadata(remove, id: "scripts.header.\(index).remove", label: "Remove Header", description: "Remove this header from the draft; Save applies the change.")
        }
    }
    private func loadSelection() {
        draft = model.state.requests.first { $0.id == selectedID }
        nameField.stringValue = draft?.name ?? ""; urlField.stringValue = draft?.url ?? ""
        method?.selectItem(withTitle: draft?.method ?? "GET"); bodyKind?.selectItem(withTitle: draft?.bodyKind.rawValue ?? "None")
        bodyEditor.setAccessibilityLabel("Request Body"); responseEditor.setAccessibilityLabel("HTTP Response")
        bodyEditor.string = draft?.body ?? ""; rowToggle.state = draft?.enabled == true ? .on : .off
        switch draft?.schedule ?? .manual {
        case .manual: schedule?.selectItem(at: 0)
        case .interval(let minutes):
            schedule?.selectItem(at: Self.intervals.firstIndex(of: minutes).map { $0 + 1 } ?? 6); minutesField.stringValue = String(minutes)
        case .daily(let hour, let minute):
            schedule?.selectItem(at: 7); timeField.stringValue = String(format: "%02d:%02d", hour, minute)
        }
        validation.isHidden = true; renderHeaders(); refreshEditorAvailability()
    }
    private func refreshEditorAvailability() {
        let selected = draft != nil
        [nameField, urlField, minutesField, timeField].forEach { $0.isEnabled = selected }
        method?.isEnabled = selected; schedule?.isEnabled = selected
        rowToggle.isEnabled = selected && schedule?.indexOfSelectedItem != 0
        if schedule?.indexOfSelectedItem == 0 { rowToggle.state = .off }
        let allowsBody = selected && !["GET", "HEAD"].contains(method?.titleOfSelectedItem ?? "GET")
        bodyKind?.isEnabled = allowsBody; bodyEditor.isEditable = allowsBody && bodyKind?.indexOfSelectedItem != 0
        bodyEditor.textColor = bodyEditor.isEditable ? .textColor : .disabledControlTextColor
        customRow?.isHidden = schedule?.indexOfSelectedItem != 6; dailyRow?.isHidden = schedule?.indexOfSelectedItem != 7
    }
    private func saveDraft() throws {
        view.window?.makeFirstResponder(nil)
        guard var definition = draft else { return }
        definition.name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        definition.url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        definition.method = method.titleOfSelectedItem ?? "GET"
        definition.bodyKind = RequestBodyKind(rawValue: bodyKind.titleOfSelectedItem ?? "None") ?? .none
        definition.body = bodyEditor.string; definition.enabled = rowToggle.state == .on
        switch schedule.indexOfSelectedItem {
        case 0: definition.schedule = .manual; definition.enabled = false
        case 7:
            let parts = timeField.stringValue.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { throw RequestError.message("Enter a local 24-hour time such as 09:30.") }
            definition.schedule = .daily(hour: hour, minute: minute)
        case 6:
            guard let minutes = Int(minutesField.stringValue) else { throw RequestError.message("Enter a whole number of minutes.") }
            definition.schedule = .interval(minutes: minutes)
        default: definition.schedule = .interval(minutes: Self.intervals[schedule.indexOfSelectedItem - 1])
        }
        try model.update(definition); draft = definition
    }
    private func perform(_ work: () throws -> Void) {
        do { try work(); validation.isHidden = true }
        catch { validation.stringValue = error.localizedDescription; validation.isHidden = false }
        refreshValues()
    }
    func selectRequest(_ id: UUID) {
        guard model.state.requests.contains(where: { $0.id == id }) else { return }
        view.window?.makeFirstResponder(nil); selectedID = id; loadSelection(); refreshValues()
    }
    override func refreshValues() {
        guard schedule != nil else { return }
        if !model.state.requests.contains(where: { $0.id == selectedID }) { selectedID = model.state.requests.first?.id; loadSelection() }
        super.refreshValues(); refreshEditorAvailability()
        status.stringValue = model.status; moduleToggle.state = model.state.enabled ? .on : .off
        emptyRequests.isHidden = !model.state.requests.isEmpty; emptyHistory.isHidden = !model.state.history.isEmpty
        context.catalog.remove { $0.id.hasPrefix("scripts.request.") }
        for request in model.state.requests {
            let id = request.id
            context.catalog.register(ControlMetadata(id: "scripts.request.\(id.uuidString)", label: "Scheduled Request", description: "Select a configured HTTP request. Request content is excluded from search.", keywords: ["request", "schedule"], section: "Requests",
                destination: SearchDestination(page: .scripts, controlID: "scripts.rowEnabled", requestID: id),
                availability: { [weak self] in self?.model.state.requests.contains(where: { $0.id == id }) == true ? nil : "This request has been removed." }))
        }
        updating = true; scriptsTable.reloadData(); historyTable.reloadData()
        if let row = model.state.requests.firstIndex(where: { $0.id == selectedID }) { scriptsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } else { scriptsTable.deselectAll(nil) }
        if let row = model.state.history.firstIndex(where: { $0.id == selectedRunID }) { historyTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } else { selectedRunID = nil; historyTable.deselectAll(nil) }
        updating = false; showResponse()
    }
    private func showResponse() {
        guard let run = model.state.history.first(where: { $0.id == selectedRunID }) else { responseEditor.string = "Select a run to inspect its response."; return }
        let headers = run.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        let body = String(data: run.body, encoding: .utf8) ?? "[Binary response: \(run.body.count) retained bytes]"
        let text = "\(run.outcome) · HTTP \(run.statusCode.map(String.init) ?? "—") · \(String(format: "%.2f", run.duration)) seconds\n\n\(headers)\n\n\(body)" + (run.truncated ? "\n\n[Response truncated at 64 KiB]" : "")
        if responseEditor.string != text { responseEditor.string = text }
    }
    private func setupTable(_ table: NSTableView, columns: [(String, String, CGFloat)]) {
        table.dataSource = self; table.delegate = self; table.rowHeight = 30; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; column.minWidth = 45; table.addTableColumn(column)
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === scriptsTable ? model.state.requests.count : model.state.history.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, let table = notification.object as? NSTableView else { return }
        if table === scriptsTable {
            let row = table.selectedRow; view.window?.makeFirstResponder(nil)
            selectedID = model.state.requests.indices.contains(row) ? model.state.requests[row].id : nil; loadSelection(); refreshValues()
        } else if table === historyTable {
            let row = table.selectedRow; selectedRunID = model.state.history.indices.contains(row) ? model.state.history[row].id : nil; showResponse()
        }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }; let text: String
        if tableView === scriptsTable {
            guard model.state.requests.indices.contains(row) else { return nil }; let request = model.state.requests[row]
            switch column.identifier.rawValue {
            case "name": text = request.name
            case "method": text = request.method
            case "state": text = model.isRunning(request.id) ? "Running" : request.validationError != nil ? "Needs setup" : request.schedule == .manual ? "Manual" : !request.enabled ? "Disabled" : !model.available ? "Paused" : "Scheduled"
            case "next": text = model.nextRun(request.id).map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "—"
            default: text = model.state.history.first(where: { $0.requestID == request.id })?.outcome ?? "—"
            }
        } else {
            guard model.state.history.indices.contains(row) else { return nil }; let run = model.state.history[row]
            switch column.identifier.rawValue {
            case "time": text = DateFormatter.localizedString(from: run.started, dateStyle: .short, timeStyle: .medium)
            case "name": text = run.name
            case "status": text = run.statusCode.map(String.init) ?? "—"
            case "result": text = run.outcome
            default: text = String(format: "%.2f s", run.duration)
            }
        }
        let cell = UI.cell(text, identifier: column.identifier, table: tableView); cell.toolTip = text; return cell
    }
}
