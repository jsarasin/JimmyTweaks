import AppKit

enum AwakeSleepUI {
    static func custom(_ action: PowerAction, controller: AwakeSleepController) {
        let alert = NSAlert(); alert.messageText = action.title
        alert.informativeText = "Enter a duration in hours and minutes."
        alert.addButton(withTitle: "Start"); alert.addButton(withTitle: "Cancel")
        let hours = NSTextField(string: "0"), minutes = NSTextField(string: "30")
        for field in [hours, minutes] { field.widthAnchor.constraint(equalToConstant: 75).isActive = true; field.alignment = .right }
        hours.setAccessibilityLabel("Hours"); minutes.setAccessibilityLabel("Minutes")
        let error = UI.caption(""); error.textColor = .systemRed
        let content = UI.vertical([UI.horizontal([UI.label("Hours"), hours, UI.label("Minutes"), minutes]), error])
        content.frame = NSRect(x: 0, y: 0, width: 330, height: 65); alert.accessoryView = content
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            if let duration = PowerAction.duration(hours: hours.stringValue, minutes: minutes.stringValue) {
                controller.start(action, duration: duration); return
            }
            error.stringValue = "Enter whole numbers: hours ≥ 0, minutes 0–59, total ≥ 1 minute."
        }
    }
}

final class AwakeSleepPageController: SettingsPageController {
    override func build() {
        let power = context.awakeSleep
        add(UI.caption("Keep this Mac running, or set a timer to sleep or shut down. Choosing a new action replaces the current session."))
        let current = card("Current Session")
        let summary = UI.label("", size: 17, weight: .medium), failure = UI.caption("")
        failure.textColor = .systemRed
        add(summary, to: current); add(failure, to: current)
        action("Cancel Session", id: "awakeSleep.cancel", description: "Cancel the active power session and restore normal sleep behavior.", keywords: ["stop", "awake", "timer"], to: current,
               enabled: { power.session != nil || power.transitioning }) { power.cancel() }
        action("Stop & Sleep Now", id: "awakeSleep.sleepNow", description: "End the active session, restore the sleep setting, and immediately request system sleep.", keywords: ["lid", "manual sleep"], to: current,
               enabled: { power.powerActionsAllowed && !power.transitioning }) { power.sleepNow() }
        refreshers.append { [weak summary, weak failure] in
            summary?.stringValue = power.summary; failure?.stringValue = power.error ?? ""; failure?.isHidden = power.error == nil
        }
        let timers = card("Start a Session")
        for choice in PowerAction.allCases {
            let titles = choice.presets.map { PowerAction.durationTitle(minutes: $0) } + (choice == .keepAwake ? ["Indefinitely"] : []) + ["Custom…"]
            let picker = ActionPopup(items: titles) { _ in }
            let start = ActionButton(choice.title) {
                let index = picker.indexOfSelectedItem
                if index < choice.presets.count { power.start(choice, duration: Double(choice.presets[index]) * 60) }
                else if choice == .keepAwake && index == choice.presets.count { power.start(choice, duration: nil) }
                else { AwakeSleepUI.custom(choice, controller: power) }
            }
            add(UI.horizontal([UI.label(choice.title), NSView(), picker, start]), to: timers)
            metadata(picker, id: "awakeSleep.\(choice.rawValue).duration", label: "\(choice.title) Duration", description: "Choose a preset or custom duration in hours and minutes.", keywords: ["power", "timer", "amphetamine"], section: "Start a Session")
            metadata(start, id: "awakeSleep.\(choice.rawValue).start", label: choice.title, description: "Start a \(choice.title.lowercased()) session. Sleep and shutdown timers keep the computer awake until they finish.", keywords: ["power", "timer", "awake", "shutdown", "sleep"], section: "Start a Session")
            refreshers.append { [weak start, weak picker] in
                start?.isEnabled = power.powerActionsAllowed && !power.preferences.bool(.suspended) && !power.transitioning
                picker?.isEnabled = !power.preferences.bool(.suspended)
            }
        }
        toggle("Keep Display Awake", key: .keepDisplayAwake, id: "awakeSleep.display", description: "Also prevent the display from sleeping while a session is active. Off lets the display follow its normal settings.", keywords: ["screen", "monitor", "awake", "display"], section: "Start a Session", to: timers)
        add(UI.caption("Sleep and shutdown show a cancellable warning in their final 30 seconds. Quit, Suspend All, logout, or system sleep cancels the session."), to: timers)
        let helper = card("Closed-Lid Support")
        let status = UI.caption(""); add(status, to: helper)
        let setup = action("Set Up Closed-Lid Helper…", id: "awakeSleep.helper", description: "Register the power helper and open macOS approval settings when needed. Administrator approval is required.", keywords: ["lid", "clamshell", "administrator", "power", "permission"], to: helper,
               enabled: { power.canConfigureHelper }) { power.configureHelper() }
        refreshers.append { [weak status, weak setup] in
            status?.stringValue = power.helperStatus
            let title = power.helperNeedsApproval ? "Open Login Items…" : "Set Up Closed-Lid Helper…"
            setup?.title = title; setup?.setAccessibilityLabel(title)
        }
        add(UI.caption("With the helper approved, sessions temporarily override system sleep on battery and external power. Normal Sleep commands may be blocked: use Stop & Sleep Now to end the override first. Without approval, sessions prevent idle sleep only. macOS emergency power protections still apply."), to: helper)
    }
}
