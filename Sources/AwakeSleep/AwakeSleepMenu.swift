import AppKit

private final class PowerMenuChoice: NSObject {
    let action: PowerAction
    let minutes: Int?
    let custom: Bool
    init(_ action: PowerAction, minutes: Int? = nil, custom: Bool = false) { self.action = action; self.minutes = minutes; self.custom = custom }
}

final class AwakeSleepMenu: NSObject {
    private let controller: AwakeSleepController
    private let status = NSMenuItem(title: "No active session", action: nil, keyEquivalent: "")
    private let error = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cancel = NSMenuItem(title: "Cancel Session", action: nil, keyEquivalent: "")
    private let sleep = NSMenuItem(title: "Stop & Sleep Now", action: nil, keyEquivalent: "")
    private let display = NSMenuItem(title: "Keep Display Awake", action: nil, keyEquivalent: "")
    private let support = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var choices: [NSMenuItem] = []
    private var observation: NSObjectProtocol?
    init(controller: AwakeSleepController) {
        self.controller = controller
        super.init()
        observation = NotificationCenter.default.addObserver(forName: .awakeSleepChanged, object: controller, queue: .main) { [weak self] _ in self?.refresh() }
    }
    func append(to menu: NSMenu) {
        menu.addItem(NSMenuItem.sectionHeader(title: "Awake & Sleep")); menu.addItem(status); menu.addItem(error)
        for action in PowerAction.allCases {
            let parent = NSMenuItem(title: action.title, action: nil, keyEquivalent: ""), child = NSMenu()
            child.autoenablesItems = false
            for minutes in action.presets { addChoice(PowerAction.durationTitle(minutes: minutes), choice: PowerMenuChoice(action, minutes: minutes), to: child) }
            if action == .keepAwake { addChoice("Indefinitely", choice: PowerMenuChoice(action), to: child) }
            child.addItem(.separator()); addChoice("Custom…", choice: PowerMenuChoice(action, custom: true), to: child)
            parent.submenu = child; menu.addItem(parent)
        }
        display.target = self; display.action = #selector(toggleDisplay); menu.addItem(display)
        cancel.target = self; cancel.action = #selector(cancelSession); menu.addItem(cancel)
        sleep.target = self; sleep.action = #selector(sleepNow); menu.addItem(sleep)
        support.target = self; support.action = #selector(configureHelper); menu.addItem(support)
        menu.addItem(.separator()); refresh()
    }
    private func addChoice(_ title: String, choice: PowerMenuChoice, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(start(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = choice; menu.addItem(item); choices.append(item)
    }
    func refresh() {
        status.title = controller.summary; status.isEnabled = false
        error.title = "Session Failed — See Settings"; error.isEnabled = false; error.isHidden = controller.error == nil
        error.toolTip = controller.error
        for item in choices {
            item.isEnabled = controller.powerActionsAllowed && !controller.preferences.bool(.suspended) && !controller.transitioning
            guard let choice = item.representedObject as? PowerMenuChoice else { continue }
            let seconds = choice.minutes.map { Double($0) * 60 }
            item.state = !choice.custom && controller.session?.action == choice.action && controller.session?.duration == seconds ? .on : .off
        }
        display.state = controller.preferences.bool(.keepDisplayAwake) ? .on : .off
        cancel.isEnabled = controller.session != nil || controller.transitioning
        sleep.isEnabled = controller.powerActionsAllowed && !controller.transitioning
        support.title = controller.helperSetupFailed ? "Closed-Lid Helper Unavailable" : controller.helperAvailable ? "Closed-Lid Helper Approved" : controller.helperNeedsApproval ? "Open Login Items…" : !controller.powerActionsAllowed ? "Sleep Restoration Pending" : "Set Up Closed-Lid Helper…"
        support.isEnabled = controller.canConfigureHelper
    }
    @objc private func start(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? PowerMenuChoice else { return }
        if choice.custom { AwakeSleepUI.custom(choice.action, controller: controller) }
        else { controller.start(choice.action, duration: choice.minutes.map { Double($0) * 60 }) }
    }
    @objc private func toggleDisplay() { controller.preferences.set(!controller.preferences.bool(.keepDisplayAwake), for: .keepDisplayAwake) }
    @objc private func cancelSession() { controller.cancel() }
    @objc private func sleepNow() { controller.sleepNow() }
    @objc private func configureHelper() { controller.configureHelper() }
    deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
}
