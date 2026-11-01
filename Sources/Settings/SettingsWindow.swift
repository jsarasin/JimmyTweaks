import AppKit

private final class DetailHost: NSViewController {
    private var current: NSViewController?
    override func loadView() { view = NSView() }
    func display(_ controller: NSViewController) {
        guard current !== controller else { return }
        current?.view.removeFromSuperview(); current?.removeFromParent()
        addChild(controller); UI.pin(controller.view, in: view); current = controller
    }
}

private final class SidebarController: NSViewController, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate {
    let search = NSSearchField()
    let table = NSTableView()
    let quit = ActionButton("Quit Jimmy Tweaks") { NSApp.terminate(nil) }
    var onNavigate: ((SettingsPage) -> Void)?
    var onQuery: ((String) -> Void)?
    var onSearchCommand: ((String) -> Void)?
    private var debounce: DispatchWorkItem?
    private let rows: [SettingsPage] = SettingsPage.allCases
    override func loadView() {
        view = NSView()
        let material = NSVisualEffectView(); material.material = .sidebar; material.blendingMode = .behindWindow; UI.pin(material, in: view)
        let content = UI.vertical([], spacing: 14); UI.pin(content, in: view, inset: 14)
        search.placeholderString = "Search"; search.delegate = self
        search.controlSize = .large; search.font = .systemFont(ofSize: 14)
        search.heightAnchor.constraint(equalToConstant: 30).isActive = true
        search.sendsSearchStringImmediately = false; search.sendsWholeSearchString = true
        search.target = self; search.action = #selector(submitSearch)
        search.identifier = NSUserInterfaceItemIdentifier("global.search"); search.setAccessibilityLabel("Search Settings")
        content.addArrangedSubview(search); search.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        table.headerView = nil; table.delegate = self; table.dataSource = self; table.backgroundColor = .clear
        table.style = .sourceList; table.intercellSpacing = NSSize(width: 0, height: 3)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("navigation")); table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        content.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        quit.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(quit); quit.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let footer = UI.caption("Jimmy Tweaks · Background Agent"); content.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        select(.general)
    }
    func select(_ page: SettingsPage) {
        if let row = rows.firstIndex(of: page) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
    func clearSearch() { debounce?.cancel(); search.stringValue = ""; onQuery?("") }
    func controlTextDidChange(_ obj: Notification) {
        debounce?.cancel(); let text = search.stringValue
        let work = DispatchWorkItem { [weak self] in self?.onQuery?(text) }; debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
    @objc private func submitSearch() { if !search.stringValue.isEmpty { onSearchCommand?("insertNewline:") } }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let name = NSStringFromSelector(commandSelector)
        if ["moveUp:", "moveDown:", "insertNewline:", "insertNewlineIgnoringFieldEditor:", "cancelOperation:"].contains(name), !search.stringValue.isEmpty {
            if name == "cancelOperation:" { clearSearch() } else { onSearchCommand?(name.hasPrefix("insertNewline") ? "insertNewline:" : name) }; return true
        }
        return false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 36 }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(table.selectedRow) else { return }
        onNavigate?(rows[table.selectedRow])
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = rows[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true; icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let title = UI.label(page.title, size: 13)
        let cell = UI.horizontal([icon, title], spacing: 9)
        cell.setAccessibilityLabel(page.title)
        cell.identifier = NSUserInterfaceItemIdentifier("navigation.\(page.rawValue)"); return cell
    }
}

private final class SearchResultsController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    private let context: SettingsContext
    private let table = NSTableView()
    private let countLabel = UI.caption("")
    private let emptyTitle = UI.label("", size: 18, weight: .medium)
    private let emptyDetail = UI.caption("Try a feature name, gesture, or permission.")
    let clear = ActionButton("Clear Search") {}
    private var empty: NSStackView!
    private var scroll: NSScrollView!
    private var results: [ControlMetadata] = []
    var onOpen: ((SearchDestination) -> Void)?
    init(context: SettingsContext) { self.context = context; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    override func loadView() {
        view = NSView()
        let body = UI.vertical([], spacing: 15); UI.pin(body, in: view, inset: 26)
        for v in [UI.label("Search Results", size: 28, weight: .semibold), countLabel] { body.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        table.delegate = self; table.dataSource = self; table.headerView = nil; table.rowHeight = 94
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("results")))
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.backgroundColor = .clear
        table.target = self; table.action = #selector(openSelected)
        table.setAccessibilityLabel("Settings search results")
        scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        body.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        empty = UI.vertical([emptyTitle, emptyDetail, clear], spacing: 12)
        body.addArrangedSubview(empty); empty.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        let spacer = NSView(); body.addArrangedSubview(spacer); spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    }
    func update(query: String) {
        _ = view
        results = context.catalog.search(query); table.reloadData(); table.deselectAll(nil)
        countLabel.stringValue = "\(results.count) \(results.count == 1 ? "setting" : "settings") found"
        emptyTitle.stringValue = "No settings found for ‘\(query)’."
        empty.isHidden = !results.isEmpty; scroll.isHidden = results.isEmpty
        NSAccessibility.post(element: countLabel, notification: .announcementRequested,
                             userInfo: [.announcement: results.isEmpty ? emptyTitle.stringValue : countLabel.stringValue, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }
    func command(_ name: String) {
        guard !results.isEmpty else { return }
        if name == "insertNewline:" { openSelected(); return }
        let current = table.selectedRow
        let next = current < 0 ? 0 : max(0, min(results.count - 1, current + (name == "moveUp:" ? -1 : 1)))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); table.scrollRowToVisible(next)
    }
    @objc private func openSelected() {
        guard !results.isEmpty else { return }; let row = max(0, table.selectedRow)
        guard results.indices.contains(row) else { return }; onOpen?(results[row].destination)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }; let item = results[row]
        let label = UI.label(item.label, size: 14, weight: .semibold), breadcrumb = UI.caption(item.breadcrumb)
        let status = item.availability().map { "Unavailable: " + $0 } ?? item.value()
        let detail = UI.caption(item.description + (status.map { "  ·  " + $0 } ?? ""))
        detail.maximumNumberOfLines = 2
        let stack = UI.vertical([label, breadcrumb, detail], spacing: 4)
        let cell = NSView(); UI.pin(stack, in: cell, inset: 7); return cell
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let context: SettingsContext
    private let split = NSSplitViewController()
    private let sidebar = SidebarController()
    private let host = DetailHost()
    private var pages: [SettingsPage: SettingsPageController] = [:]
    private var currentPage: SettingsPage = .general
    private var searching = false
    private var rememberedScroll = CGPoint.zero
    private var results: SearchResultsController!
    private var observers: [NSObjectProtocol] = []

    init(context: SettingsContext) {
        self.context = context
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Jimmy Tweaks"; window.subtitle = "Settings"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 780, height: 560); window.delegate = self
        window.contentViewController = split
        let side = NSSplitViewItem(sidebarWithViewController: sidebar); side.minimumThickness = 218; side.maximumThickness = 275; side.canCollapse = false
        split.addSplitViewItem(side); split.addSplitViewItem(NSSplitViewItem(viewController: host))
        split.splitView.setPosition(235, ofDividerAt: 0)
        results = SearchResultsController(context: context)
        buildPages(); bind(); registerMetadata()
        window.contentMinSize = NSSize(width: 780, height: 560)
        window.setContentSize(NSSize(width: 960, height: 700))
        window.center(); window.setFrameAutosaveName("JimmyTweaks.Settings")
        if let content = window.contentView, content.frame.width < 780 || content.frame.height < 560 {
            window.setContentSize(NSSize(width: max(780, content.frame.width), height: max(560, content.frame.height)))
        }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        show(.general); refreshAll()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    private func buildPages() {
        pages = [.general: GeneralPageController(.general, context: context), .window: WindowPageController(.window, context: context),
            .iconAbsorber: IconAbsorberPageController(.iconAbsorber, context: context), .scripts: ScriptsPageController(.scripts, context: context),
            .logging: LoggingPageController(.logging, context: context), .about: AboutPageController(.about, context: context)]
        for page in SettingsPage.allCases { _ = pages[page]?.view }
    }
    private func bind() {
        sidebar.onNavigate = { [weak self] page in
            guard let self = self else { return }
            if self.searching { self.sidebar.clearSearch() }; self.show(page)
        }
        sidebar.onQuery = { [weak self] in self?.search($0) }
        sidebar.onSearchCommand = { [weak self] in self?.results.command($0) }
        results.clear.handler = { [weak self] in self?.sidebar.clearSearch(); self?.window?.makeFirstResponder(self?.sidebar.search) }
        results.onOpen = { [weak self] destination in self?.navigate(destination) }
        context.navigate = { [weak self] in self?.navigate($0) }
        context.confirm = { [weak self] title, detail, completion in self?.confirm(title, detail: detail, completion: completion) }
        context.showMessage = { [weak self] title, detail in self?.message(title, detail: detail) }
        context.refresh = { [weak self] in self?.refreshAll() }
        for name in [Notification.Name.preferencesChanged, .runtimeChanged, .permissionsChanged, .loggingChanged, .iconAbsorberChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshAll() })
        }
    }
    private func registerMetadata() {
        for page in SettingsPage.allCases {
            context.catalog.register(ControlMetadata(id: "navigation.\(page.rawValue)", label: page.title, description: page == .scripts ? "Sample script controls and fictional history. Nothing executes." : "Open the \(page.title) Settings page.", keywords: [page.rawValue], section: "", destination: SearchDestination(page: page, controlID: "")))
        }
        for (id, label, description) in [
            ("global.search", "Search Settings", "Find controls by feature, description, gesture, and keyword."),
            ("global.search.clear", "Clear Search", "Clear the query and restore the preceding Settings page."),
            ("global.quit", "Quit Jimmy Tweaks", "Stop the background application explicitly. Closing Settings does not quit it.")
        ] {
            context.catalog.register(ControlMetadata(id: id, label: label, description: description, keywords: ["global", "background", id == "global.suspendAll" ? "pause stop resume master" : ""], section: "Application", destination: SearchDestination(page: .general, controlID: id)))
        }
        for (scope, page, parent) in [("window", SettingsPage.window, "window.reset"), ("scripts", .scripts, "scripts.reset"), ("all", .general, "general.resetAll")] {
            for action in ["confirm", "cancel"] {
                context.catalog.register(ControlMetadata(id: "reset.\(scope).\(action)", label: action == "confirm" ? "Confirm \(scope.capitalized) Reset" : "Cancel \(scope.capitalized) Reset", description: "Navigate to the reset action. Opening a result never confirms or executes a reset.", keywords: ["reset", "defaults", "cancel"], section: "Preferences", destination: SearchDestination(page: page, controlID: parent)))
            }
        }
    }
    func present() {
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        context.permissions.refresh(); refreshAll(); updatePermissionVisibility()
    }
    private func show(_ page: SettingsPage) {
        guard let controller = pages[page] else { return }
        let changed = currentPage != page; currentPage = page
        host.display(controller)
        if sidebar.table.selectedRow >= 0, changed { sidebar.select(page) }
        controller.refreshValues(); updatePermissionVisibility()
    }
    private func search(_ query: String) {
        let nonempty = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if nonempty {
            if !searching { rememberedScroll = pages[currentPage]?.scroll.contentView.bounds.origin ?? .zero }
            searching = true; host.display(results); results.update(query: query)
        } else if searching {
            searching = false; show(currentPage)
            if let page = pages[currentPage] { page.scroll.contentView.scroll(to: rememberedScroll); page.scroll.reflectScrolledClipView(page.scroll.contentView) }
        }
        updatePermissionVisibility()
    }
    private func navigate(_ destination: SearchDestination) {
        sidebar.clearSearch(); show(destination.page)
        if let sample = destination.sampleID { (pages[.scripts] as? ScriptsPageController)?.selectSample(sample) }
        let globals: [String: NSView] = ["global.search": sidebar.search, "global.search.clear": sidebar.search, "global.quit": sidebar.quit]
        if let control = globals[destination.controlID] { window?.makeFirstResponder(control) }
        else { DispatchQueue.main.async { [weak self] in self?.pages[destination.page]?.focus(destination.controlID) } }
    }
    func refreshAll() {
        for page in pages.values { page.refreshValues() }
    }
    private func confirm(_ title: String, detail: String, completion: @escaping () -> Void) {
        guard let window = window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Reset"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { completion() } }
    }
    private func message(_ title: String, detail: String) {
        guard let window = window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
    private func updatePermissionVisibility() {
        let visible = window?.isVisible == true && window?.isMiniaturized != true && !searching
        context.permissions.setDetailed("general-page", visible: visible && currentPage == .general)
        (pages[.iconAbsorber] as? IconAbsorberPageController)?.setPreviewVisible(visible && currentPage == .iconAbsorber)
    }
    func windowDidMiniaturize(_ notification: Notification) { updatePermissionVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updatePermissionVisibility() }
    func windowWillClose(_ notification: Notification) {
        context.permissions.setDetailed("general-page", visible: false)
        (pages[.iconAbsorber] as? IconAbsorberPageController)?.setPreviewVisible(false)
    }
}
