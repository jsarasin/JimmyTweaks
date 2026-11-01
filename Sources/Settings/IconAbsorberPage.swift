import AppKit
import QuartzCore

private final class StatusIconButton: NSButton {
    var open: ((Bool) -> Void)?
    init(item: AbsorbedStatusItem, image: NSImage, captured: Bool) {
        super.init(frame: .zero)
        self.image = image; imagePosition = .imageOnly; imageScaling = .scaleProportionallyDown
        isBordered = false; bezelStyle = .regularSquare; target = self; action = #selector(pressed)
        toolTip = item.name + (item.label.isEmpty ? "" : " — " + item.label) + (captured ? "" : " (application icon; capture the status icon with Refresh Icon Pictures)")
        setAccessibilityLabel("Open \(item.name) status item \(item.index + 1)")
    }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    @objc private func pressed() { open?(false) }
    override func rightMouseDown(with event: NSEvent) { open?(true) }
}

/// Native drawing of an upper-right desktop slice. It never captures other apps.
private final class DesktopSliceView: NSView {
    private let iconScroll = NSScrollView()
    private let iconDocument = NSView()
    private let cutMask = CAShapeLayer()
    private var buttons: [(StatusIconButton, CGFloat)] = []
    private var wallpaper: NSImage?
    private var wallpaperKey = ""
    private var desktopSize = NSSize(width: 2560, height: 1440)
    private var wallpaperScaling = NSImageScaling.scaleProportionallyUpOrDown
    private var wallpaperClips = true
    private var wallpaperFill = NSColor.underPageBackgroundColor
    var wallpaperDescription = "Wallpaper unavailable for this display"
    var emptyText = "Choose applications below"
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.mask = cutMask
        iconScroll.drawsBackground = false; iconScroll.borderType = .noBorder
        iconScroll.hasHorizontalScroller = true; iconScroll.autohidesScrollers = true
        iconScroll.documentView = iconDocument; addSubview(iconScroll)
        setAccessibilityLabel("Desktop preview containing only selected applications")
    }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    func update(items: [AbsorbedStatusItem], images: [String: NSImage], enabled: Bool, activate: @escaping (AbsorbedStatusItem, Bool, NSView) -> Void) {
        buttons.forEach { $0.0.removeFromSuperview() }; buttons = []
        for item in items {
            let captured = images[item.id] != nil
            let image = images[item.id] ?? NSRunningApplication(processIdentifier: item.pid)?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: item.name) ?? NSImage()
            let button = StatusIconButton(item: item, image: image, captured: captured)
            button.isEnabled = enabled
            button.open = { [weak button] right in if let button { activate(item, right, button) } }
            iconDocument.addSubview(button)
            buttons.append((button, min(72, max(26, item.frame?.width ?? 30))))
        }
        needsLayout = true; needsDisplay = true
    }
    func loadWallpaper() {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        desktopSize = screen.frame.size
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let modified = url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let key = "\(url?.absoluteString ?? "")/\(String(describing: modified))/\(screen.frame)/\(effectiveAppearance.name)/\(options)"
        guard key != wallpaperKey else { return }; wallpaperKey = key
        wallpaper = url.flatMap { NSImage(contentsOf: $0) }
        wallpaperScaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
        wallpaperClips = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        wallpaperFill = options[.fillColor] as? NSColor ?? .underPageBackgroundColor
        wallpaperDescription = wallpaper == nil ? "Wallpaper unavailable for this display" : "Your desktop wallpaper · \(screen.localizedName)"
        needsDisplay = true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); loadWallpaper() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); loadWallpaper() }
    override func layout() {
        super.layout()
        cutMask.frame = bounds; cutMask.path = cutaway()
        iconScroll.frame = NSRect(x: 25, y: bounds.height - 34, width: max(0, bounds.width - 37), height: 32)
        let width = buttons.reduce(CGFloat(0)) { $0 + $1.1 + 4 }
        let documentWidth = max(iconScroll.contentSize.width, width)
        iconDocument.frame = NSRect(x: 0, y: 0, width: documentWidth, height: 28)
        var x = max(0, documentWidth - width)
        for (button, width) in buttons { button.frame = NSRect(x: x, y: 4, width: width, height: 22); x += width + 4 }
    }
    private func cutaway() -> CGPath {
        let path = CGMutablePath(), h = bounds.height, w = bounds.width
        path.move(to: CGPoint(x: 9, y: h)); path.addLine(to: CGPoint(x: w, y: h)); path.addLine(to: CGPoint(x: w, y: 5))
        var step = 0
        for x in stride(from: w - 22, through: 12, by: -22) {
            path.addLine(to: CGPoint(x: x, y: [CGFloat(5), 8, 4, 6][step % 4])); step += 1
        }
        path.addLine(to: CGPoint(x: 9, y: 5)); step = 0
        for y in stride(from: CGFloat(22), to: h - 1, by: 18) {
            path.addLine(to: CGPoint(x: [CGFloat(6), 13, 8, 11][step % 4], y: y)); step += 1
        }
        path.closeSubpath(); return path
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(cgPath: cutaway()).addClip()
        wallpaperFill.setFill(); bounds.fill()
        if let wallpaper, wallpaper.size.width > 0, wallpaper.size.height > 0 {
            let image = wallpaper.size
            var scale = wallpaperClips ? max(desktopSize.width / image.width, desktopSize.height / image.height) : min(desktopSize.width / image.width, desktopSize.height / image.height)
            if wallpaperScaling == .scaleProportionallyDown { scale = min(1, scale) }
            if wallpaperScaling == .scaleNone { scale = 1 }
            let size = wallpaperScaling == .scaleAxesIndependently ? desktopSize : NSSize(width: image.width * scale, height: image.height * scale)
            let fullDesktop = NSRect(x: bounds.maxX - desktopSize.width, y: bounds.maxY - desktopSize.height, width: desktopSize.width, height: desktopSize.height)
            let imageFrame = NSRect(x: fullDesktop.midX - size.width / 2, y: fullDesktop.midY - size.height / 2, width: size.width, height: size.height)
            wallpaper.draw(in: imageFrame, from: .zero, operation: .sourceOver, fraction: 1)
        }
        let bar = NSRect(x: 0, y: bounds.height - 34, width: bounds.width, height: 34)
        NSColor.windowBackgroundColor.withAlphaComponent(0.68).setFill(); bar.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setFill(); NSRect(x: 0, y: bar.minY, width: bounds.width, height: 0.5).fill()
        if buttons.isEmpty {
            let text = NSAttributedString(string: emptyText, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            text.draw(at: NSPoint(x: max(28, bounds.width - text.size().width - 18), y: bounds.height - 24))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class IconAbsorberPageController: SettingsPageController, NSTableViewDataSource, NSTableViewDelegate {
    private struct AppRow { let bundle: String; let name: String; let icon: NSImage; let count: Int; let running: Bool }
    private let desktop = DesktopSliceView()
    private let table = NSTableView()
    private let stateLabel = UI.label("", size: 17, weight: .semibold)
    private let detailLabel = UI.caption("")
    private let wallpaperLabel = UI.caption("")
    private let pictureLabel = UI.caption("")
    private let applicationsMessage = UI.caption("")
    private var rows: [AppRow] = []
    private var wallpaperTimer: Timer?
    private var previewVisible = false
    private let dragType = NSPasteboard.PasteboardType("local.jimmytweaks.iconAbsorber.application")
    private var module: IconAbsorberController { context.iconAbsorber }
    override func build() {
        add(UI.caption("Keep selected menu bar applications within reach. Each icon opens the owning application's original controls."))
        desktop.heightAnchor.constraint(equalToConstant: 180).isActive = true; add(desktop)
        metadata(desktop, id: "iconAbsorber.preview", label: "Desktop Preview", description: "An upper-right slice of your desktop showing only selected applications. Click or right-click an icon to invoke its original controls.", keywords: ["wallpaper", "virtual status bar", "menu bar", "icons"], section: "Desktop Preview")
        add(wallpaperLabel); add(pictureLabel)
        let settings = card("Icon Absorber")
        toggle("Enable Icon Absorber", key: .iconAbsorberEnabled, id: "iconAbsorber.enabled", description: "Hide status items belonging to your selected applications. Disable this module or choose Restore All to bring them back.", keywords: ["hide", "absorb", "menu", "status", "icons"], section: "Icon Absorber", to: settings)
        add(stateLabel, to: settings); add(detailLabel, to: settings)
        let restore = action("Restore All Now", id: "iconAbsorber.restore", description: "Disable Icon Absorber and release every visibility restriction immediately, preserving selections.", keywords: ["emergency", "show", "recover"], to: settings) { [weak self] in self?.module.restoreAll() }
        restore.keyEquivalent = ""; restore.hasDestructiveAction = false
        let apps = card("Applications")
        add(UI.caption("Select whole applications. Drag selected rows to change their order in the preview. Apps that are not running stay saved."), to: apps)
        add(applicationsMessage, to: apps)
        table.delegate = self; table.dataSource = self; table.rowHeight = 50; table.headerView = nil; table.style = .plain
        let check = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("selected")); check.width = 35; check.minWidth = 35; check.maxWidth = 35
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application")); name.width = 250; name.minWidth = 160
        let state = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state")); state.width = 120; state.minWidth = 90
        table.addTableColumn(check); table.addTableColumn(name); table.addTableColumn(state)
        table.registerForDraggedTypes([dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Applications providing menu bar status items")
        add(UI.scrollTable(table, height: 230), to: apps)
        metadata(table, id: "iconAbsorber.applications", label: "Absorbed Applications", description: "Discover, select, and reorder applications with status items. Selecting an app absorbs all of its items.", keywords: ["MonitorControl", "LinearMouse", "selection", "order"], section: "Applications")
        let moveUp = ActionButton("Move Earlier") { [weak self] in self?.moveSelected(-1) }
        let moveDown = ActionButton("Move Later") { [weak self] in self?.moveSelected(1) }
        let refresh = ActionButton("Refresh") { [weak self] in self?.module.retry() }
        add(UI.horizontal([moveUp, moveDown, NSView(), refresh]), to: apps)
        metadata(refresh, id: "iconAbsorber.refresh", label: "Refresh Applications", description: "Refresh discovery and retry the visibility service after a compatibility or permission change.", section: "Applications")
        let behavior = card("Original Controls")
        toggle("Keep icons hidden when opening controls", key: .iconAbsorberHiddenPress, id: "iconAbsorber.hiddenPress", description: "Try AXPress without restoring the physical icon. This is experimental and depends on the application. Leave off to restore briefly and hide again when its original controls close.", keywords: ["AXPress", "hidden", "popover"], section: "Original Controls", to: behavior)
        toggle("Position movable panels near the preview", key: .iconAbsorberPositionPanels, id: "iconAbsorber.positionPanels", description: "Best effort for accessible floating panels only. Native menus and protected or inaccessible surfaces appear in their normal position.", keywords: ["position", "move", "panel", "popover"], section: "Original Controls", to: behavior)
        action("Refresh Icon Pictures", id: "iconAbsorber.pictures", description: "Capture the original status icons from the menu-bar window. Requires optional Screen Recording permission; no other app windows are captured.", section: "Desktop Preview", to: behavior, enabled: { [weak self] in self?.module.capturing == false }) { [weak self] in self?.module.refreshPictures() }
        let compatibility = card("Compatibility")
        add(UI.caption("This module uses an unsupported macOS visibility API in an isolated service. It restores all items if that service fails or if Apple controls are present that the API cannot preserve. Original application menus are never recreated."), to: compatibility)
        add(UI.caption("Left-click uses Accessibility without synthesizing a global mouse click. Right-click uses an exposed menu action or an application-targeted event where supported. Some apps require their physical icon to be visible."), to: compatibility)
    }
    override func viewDidAppear() {
        super.viewDidAppear(); setPreviewVisible(view.window?.isVisible == true)
    }
    override func viewDidDisappear() { super.viewDidDisappear(); setPreviewVisible(false) }
    func setPreviewVisible(_ visible: Bool) {
        guard previewVisible != visible else { return }; previewVisible = visible
        module.setPanelVisible(visible); wallpaperTimer?.invalidate(); wallpaperTimer = nil
        if visible {
            updateWallpaper()
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.updateWallpaper() }
            timer.tolerance = 1; RunLoop.main.add(timer, forMode: .common); wallpaperTimer = timer
        }
    }
    private func updateWallpaper() { desktop.loadWallpaper(); wallpaperLabel.stringValue = desktop.wallpaperDescription }
    override func refreshValues() {
        super.refreshValues()
        let focused = table.selectedRow >= 0 && rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].bundle : nil
        let groups = Dictionary(grouping: module.items, by: \.bundle)
        let selected = module.selectedBundles
        let available = groups.keys.filter { !selected.contains($0) }.sorted { (groups[$0]?.first?.name ?? $0).localizedCaseInsensitiveCompare(groups[$1]?.first?.name ?? $1) == .orderedAscending }
        rows = (selected + available).map { bundle in
            let item = groups[bundle]?.first
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            let name = item?.name ?? url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
            let icon = item.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon } ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: name) ?? NSImage()
            return AppRow(bundle: bundle, name: name, icon: icon, count: groups[bundle]?.count ?? 0,
                          running: NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains { !$0.isTerminated })
        }
        table.reloadData()
        if let focused, let index = rows.firstIndex(where: { $0.bundle == focused }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        stateLabel.stringValue = module.state; detailLabel.stringValue = module.detail
        applicationsMessage.stringValue = module.applicationListMessage ?? ""
        applicationsMessage.isHidden = module.applicationListMessage == nil
        applicationsMessage.textColor = context.permissions.accessibility ? .secondaryLabelColor : .systemOrange
        stateLabel.textColor = module.state == "Enabled" ? .systemGreen : .labelColor
        let originals = module.absorbedItems
        desktop.emptyText = selected.isEmpty ? "Choose applications below" : "Selected status items are unavailable"
        desktop.update(items: originals, images: module.images, enabled: module.canInvokeStatusItems) { [weak self] item, right, view in
            guard let self, let window = view.window, let primaryHeight = NSScreen.screens.first?.frame.height else { return }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? .zero
            let visible = CGRect(x: screen.minX, y: primaryHeight - screen.maxY, width: screen.width, height: screen.height)
            self.module.activate(item, rightClick: right, anchor: CGPoint(x: rect.minX, y: primaryHeight - rect.minY + 8), visibleFrame: visible)
        }
        let missing = originals.filter { module.images[$0.id] == nil }.count
        pictureLabel.stringValue = module.capturing ? "Capturing original status icons…" : (originals.isEmpty ? "Select applications below to add their status items to the preview." : (missing > 0 ? "\(missing) item(s) use application icons. Refresh Icon Pictures to capture their original status icons." : "Click an icon to open its original controls. Right-click for the original secondary action."))
        updateWallpaper()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let app = rows[row], selected = module.selectedBundles.contains(app.bundle)
        if tableColumn?.identifier.rawValue == "selected" {
            let button = ActionButton("") {}; button.setButtonType(.switch); button.state = selected ? .on : .off
            button.setAccessibilityLabel("Absorb \(app.name)")
            button.handler = { [weak self, weak button] in self?.module.select(app.bundle, selected: button?.state == .on) }
            return button
        }
        if tableColumn?.identifier.rawValue == "application" {
            let icon = NSImageView(image: app.icon); icon.imageScaling = .scaleProportionallyDown
            icon.widthAnchor.constraint(equalToConstant: 26).isActive = true; icon.heightAnchor.constraint(equalToConstant: 26).isActive = true
            let name = UI.label(app.name); name.maximumNumberOfLines = 1
            let identifier = UI.caption(app.bundle); identifier.maximumNumberOfLines = 1; identifier.lineBreakMode = .byTruncatingMiddle
            return UI.horizontal([icon, UI.vertical([name, identifier], spacing: 2)], spacing: 9)
        }
        let unavailable = !app.running ? "Not running" : !context.permissions.accessibility ? "Needs access" : "No status items"
        let status = app.count == 0 ? unavailable : selected ? (module.isAbsorbed(app.bundle) ? "Absorbed · \(app.count)" : "Selected · \(app.count)") : "Available · \(app.count)"
        return UI.cell(status, identifier: NSUserInterfaceItemIdentifier("absorption"), table: table)
    }
    private func moveSelected(_ delta: Int) {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return }
        let bundle = rows[row].bundle, selection = module.selectedBundles
        guard let index = selection.firstIndex(of: bundle) else { return }
        let target = index + delta
        guard selection.indices.contains(target) else { return }
        let before = delta < 0 ? selection[target] : (target + 1 < selection.count ? selection[target + 1] : nil)
        module.move(bundle, before: before)
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row), module.selectedBundles.contains(rows[row].bundle) else { return nil }
        let item = NSPasteboardItem(); item.setString(rows[row].bundle, forType: dragType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table, operation == .above, row >= 0, row <= module.selectedBundles.count else { return [] }
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let bundle = info.draggingPasteboard.string(forType: dragType), row >= 0, row <= module.selectedBundles.count else { return false }
        module.move(bundle, before: row < module.selectedBundles.count ? module.selectedBundles[row] : nil); return true
    }
    deinit { wallpaperTimer?.invalidate() }
}
