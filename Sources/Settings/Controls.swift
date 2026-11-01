import AppKit

private final class FlippedDocumentView: NSView { override var isFlipped: Bool { true } }

final class ActionButton: NSButton {
    var handler: (() -> Void)?
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; target = self; action = #selector(invoke)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    @objc private func invoke() { handler?() }
}

final class ActionPopup: NSPopUpButton {
    var handler: ((Int) -> Void)?
    init(items: [String], handler: @escaping (Int) -> Void) {
        self.handler = handler
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: items); target = self; action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    @objc private func invoke() { handler?(indexOfSelectedItem) }
}

final class CommitField: NSTextField, NSTextFieldDelegate {
    var commit: ((String) -> Void)?
    init(value: String = "") {
        super.init(frame: .zero); stringValue = value; delegate = self; target = self; action = #selector(commitNow)
        usesSingleLineMode = true; cell?.isScrollable = true
    }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    @objc private func commitNow() { commit?(stringValue) }
    func controlTextDidEndEditing(_ notification: Notification) { commit?(stringValue) }
}

final class NumericEditor: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    let stepper = NSStepper()
    private let errorLabel = UI.caption("")
    private let range: ClosedRange<Int>
    private let changed: (Int) -> Void
    private var stored: Int
    private var resetRevision: UInt64 = 0
    init(value: Int, range: ClosedRange<Int>, changed: @escaping (Int) -> Void) {
        self.range = range; self.changed = changed; self.stored = value
        super.init(frame: .zero)
        let row = NSStackView(views: [field, stepper, UI.caption("points")]); row.orientation = .horizontal; row.spacing = 7
        let stack = NSStackView(views: [row, errorLabel]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        UI.pin(stack, in: self)
        field.delegate = self; field.target = self; field.action = #selector(commitField)
        field.stringValue = String(value); field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        stepper.minValue = Double(range.lowerBound); stepper.maxValue = Double(range.upperBound); stepper.increment = 1
        stepper.integerValue = value; stepper.target = self; stepper.action = #selector(stepped)
        errorLabel.textColor = .systemRed; errorLabel.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    func refresh(value: Int, enabled: Bool, resetRevision: UInt64 = 0) {
        let replace = self.resetRevision != resetRevision || value != stored
        self.resetRevision = resetRevision
        if replace {
            errorLabel.isHidden = true
            field.currentEditor()?.string = String(value)
        }
        if replace || (field.currentEditor() == nil && errorLabel.isHidden) { field.stringValue = String(value) }
        stored = value; stepper.integerValue = value; field.isEnabled = enabled; stepper.isEnabled = enabled
    }
    @objc private func stepped() { field.stringValue = String(stepper.integerValue); validate() }
    @objc private func commitField() { validate() }
    func controlTextDidEndEditing(_ notification: Notification) { validate() }
    private func validate() {
        guard let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), range.contains(number) else {
            errorLabel.stringValue = "Enter a whole number from \(range.lowerBound) to \(range.upperBound)."
            errorLabel.isHidden = false; stepper.integerValue = stored; return
        }
        errorLabel.isHidden = true; stored = number; stepper.integerValue = number; changed(number)
    }
}

enum UI {
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = .labelColor
        label.isSelectable = false; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    static func caption(_ text: String) -> NSTextField { let label = label(text, size: 12); label.textColor = .secondaryLabelColor; return label }
    static func horizontal(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing; return stack
    }
    static func vertical(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing; return stack
    }
    static func pin(_ view: NSView, in parent: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)])
    }
    static func separator() -> NSView { let box = NSBox(); box.boxType = .separator; return box }
    static func scrollTable(_ table: NSTableView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        table.usesAlternatingRowBackgroundColors = false; table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        return scroll
    }
    static func cell(_ text: String, identifier: NSUserInterfaceItemIdentifier, table: NSTableView) -> NSView {
        let cell = (table.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let field = NSTextField(labelWithString: ""); field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail; field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field); cell.textField = field
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        cell.textField?.stringValue = text; return cell
    }
}

final class SettingsContext {
    let preferences: PreferenceStore
    let permissions: PermissionCoordinator
    let runtime: RuntimeCoordinator
    let logger: FileLogger
    let login: LoginService
    let iconAbsorber: IconAbsorberController
    let preview = ScriptsPreview()
    let catalog = SearchCatalog()
    var navigate: ((SearchDestination) -> Void)?
    var showAssistant: ((Int?, String?) -> Void)?
    var confirm: ((String, String, @escaping () -> Void) -> Void)?
    var showMessage: ((String, String) -> Void)?
    var refresh: (() -> Void)?
    init(preferences: PreferenceStore, permissions: PermissionCoordinator, runtime: RuntimeCoordinator, logger: FileLogger, login: LoginService) {
        self.preferences = preferences; self.permissions = permissions; self.runtime = runtime; self.logger = logger; self.login = login
        iconAbsorber = IconAbsorberController(preferences: preferences, permissions: permissions, logger: logger)
    }
    func openLog() {
        logger.flush { [weak self] result in
            switch result {
            case .success(let url):
                let workspace = NSWorkspace.shared
                // Resolve the user's plain-text handler, rather than a .log association
                // that may lead to a system log viewer. The original file stays .log.
                let textURL = url.deletingPathExtension().appendingPathExtension("txt")
                guard let editor = workspace.urlForApplication(toOpen: textURL) ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
                    self?.showMessage?("Couldn’t Open Log File", "Install or choose a plain-text application, then try again."); return
                }
                workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                    if error != nil { DispatchQueue.main.async { self?.showMessage?("Couldn’t Open Log File", "The selected text application could not open the current log.") } }
                }
            case .failure: self?.showMessage?("Log File Unavailable", "The current log could not be created or opened. Review the Logging page for details.")
            }
        }
    }
}

class SettingsPageController: NSViewController {
    let context: SettingsContext
    let page: SettingsPage
    let stack = NSStackView()
    let scroll = NSScrollView()
    var controls: [String: NSView] = [:]
    var refreshers: [() -> Void] = []
    init(_ page: SettingsPage, context: SettingsContext) { self.page = page; self.context = context; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    override func loadView() {
        view = NSView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        UI.pin(scroll, in: view)
        let document = FlippedDocumentView(); scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        UI.pin(stack, in: document, inset: 26)
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let title = UI.label(page.title, size: 28, weight: .semibold); add(title)
        build(); refreshValues()
    }
    func build() {}
    func refreshValues() { refreshers.forEach { $0() } }
    func add(_ child: NSView, to parent: NSStackView? = nil) {
        let parent = parent ?? stack; parent.addArrangedSubview(child)
        if let button = child as? NSButton { button.setContentHuggingPriority(.defaultLow, for: .horizontal); button.alignment = .left }
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
    }
    @discardableResult func card(_ title: String) -> NSStackView {
        let box = NSBox(); box.boxType = .custom
        box.borderColor = .separatorColor; box.borderWidth = 0.5; box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor; box.titlePosition = .noTitle
        box.contentViewMargins = NSSize(width: 16, height: 16)
        let content = UI.vertical([], spacing: 12)
        box.contentView = NSView(); UI.pin(content, in: box.contentView!)
        add(box)
        if !title.isEmpty { add(UI.label(title, size: 14, weight: .semibold), to: content) }
        return content
    }
    func metadata(_ view: NSView, id: String, label: String, description: String, keywords: [String] = [], section: String = "", unavailable: String = "This control is unavailable with the current settings.", value: @escaping () -> String? = { nil }) {
        view.identifier = NSUserInterfaceItemIdentifier(id); controls[id] = view
        view.setAccessibilityHelp(description)
        if let control = view as? NSControl { control.setAccessibilityLabel(label) }
        context.catalog.register(ControlMetadata(id: id, label: label, description: description, keywords: keywords,
            section: section, destination: SearchDestination(page: page, controlID: id),
            availability: { [weak view] in
                if let control = view as? NSControl, !control.isEnabled { return unavailable }
                return nil
            }, value: value))
    }
    @discardableResult func action(_ title: String, id: String, description: String, keywords: [String] = [], section: String = "", to parent: NSStackView, enabled: @escaping () -> Bool = { true }, handler: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title, handler: handler)
        let row = UI.horizontal([button, NSView()]); add(row, to: parent)
        metadata(button, id: id, label: title, description: description, keywords: keywords, section: section)
        refreshers.append { [weak button] in button?.isEnabled = enabled() }
        return button
    }
    @discardableResult func toggle(_ title: String, key: PreferenceKey, id: String, description: String, keywords: [String], section: String, to parent: NSStackView, enabled: @escaping () -> Bool = { true }, unavailable: String = "Enable Window Resizer first.") -> ActionButton {
        let prefs = context.preferences
        let button = ActionButton(title) {}; button.setButtonType(.switch); button.bezelStyle = .regularSquare
        button.handler = { [weak button] in prefs.set(button?.state == .on, for: key) }
        add(button, to: parent); add(UI.caption(description), to: parent)
        metadata(button, id: id, label: title, description: description, keywords: keywords, section: section, unavailable: unavailable,
                 value: { prefs.bool(key) ? "On" : "Off" })
        refreshers.append { [weak button] in button?.state = prefs.bool(key) ? .on : .off; button?.isEnabled = enabled() }
        return button
    }
    func number(_ title: String, key: PreferenceKey, id: String, description: String, section: String, to parent: NSStackView, enabled: @escaping () -> Bool) {
        let prefs = context.preferences
        let editor = NumericEditor(value: prefs.int(key), range: key.range!) { prefs.set($0, for: key) }
        let name = UI.label(title); name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        add(UI.horizontal([name, NSView(), editor]), to: parent); add(UI.caption(description), to: parent)
        let keywords = key == .cornerSize ? ["points", "corner", "hit area", "size"] : ["points", "distance", "five", "5", "drag", "threshold"] + (key == .moveThreshold ? ["move", "moving", "left drag", "Command"] : ["resize", "resizing", "right click", "Command"])
        metadata(editor.field, id: id, label: title, description: description, keywords: keywords, section: section,
                 unavailable: "Enable the related gesture and threshold activation to edit this value.", value: { "\(prefs.int(key)) points" })
        metadata(editor.stepper, id: id + ".stepper", label: "Adjust \(title)", description: description, keywords: ["increase", "decrease", "points"], section: section)
        refreshers.append { [weak editor] in editor?.refresh(value: prefs.int(key), enabled: enabled(), resetRevision: prefs.resetRevision) }
    }
    func focus(_ id: String) {
        guard let control = controls[id] else { return }
        control.scrollToVisible(control.bounds.insetBy(dx: -8, dy: -12))
        if let native = control as? NSControl, native.isEnabled { view.window?.makeFirstResponder(native) }
        control.wantsLayer = true
        control.layer?.borderColor = NSColor.controlAccentColor.cgColor; control.layer?.borderWidth = 2; control.layer?.cornerRadius = 5
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak control] in control?.layer?.borderWidth = 0 }
    }
}
