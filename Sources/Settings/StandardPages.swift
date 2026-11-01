import AppKit

final class StatusPageController: SettingsPageController {
    override func build() {
        let stateCard = card("BACKGROUND AGENT")
        let state = UI.label("", size: 23, weight: .semibold), detail = UI.caption("")
        add(state, to: stateCard); add(detail, to: stateCard)
        metadata(state, id: "status.windowState", label: "Window Resizer Status", description: "Current background utility state, configured intent, and any reason it cannot run.", keywords: ["running", "failed", "permission", "pause", "health"])
        let background = UI.label("Jimmy Tweaks runs in the background. Closing Settings does not stop enabled features. To change settings, open Jimmy Tweaks again from Applications.")
        add(background, to: stateCard)
        metadata(background, id: "status.background", label: "Background Operation", description: background.stringValue, keywords: ["hidden", "close", "reopen", "Applications", "settings"])
        let resume = action("Resume All", id: "global.resumeAll", description: "Turn off persistent master suspension without changing individual utility preferences.", keywords: ["unpause", "suspend"], to: stateCard) { [weak self] in self?.context.preferences.set(false, for: .suspended) }
        let windows = card("Window Resizer")
        let prefs = context.preferences
        toggle("Enable Window Resizer", key: .enabled, id: "status.windowEnabled", description: "Command + right-drag at a corner resizes. Command + left-drag inside a window moves it.", keywords: ["resize", "move", "Command", "cmd"], section: "Window Resizer", to: windows)
        let gestures = UI.caption(""); add(gestures, to: windows)
        action("Window Resizer Settings…", id: "status.windowSettings", description: "Choose gesture activation, independent thresholds, corners, and feedback.", to: windows) { [weak self] in
            self?.context.navigate?(SearchDestination(page: .window, controlID: "window.enabled"))
        }
        let retry = action("Retry Window Engine", id: "status.retryWindowEngine", description: "Start a new bounded recovery attempt after a failed engine.", keywords: ["failure", "restart", "retry"], to: windows,
                           enabled: { [weak self] in self?.context.runtime.state == .failed }) { [weak self] in self?.context.runtime.retry() }
        let failedAt = UI.caption(""); add(failedAt, to: windows)
        let permissions = card("Permissions")
        let permissionState = UI.caption(""); add(permissionState, to: permissions)
        action("Open Permission Assistant…", id: "status.openAssistant", description: "Run the guided, skippable setup assistant again.", keywords: ["setup", "grant", "accessibility", "onboarding"], to: permissions) { [weak self] in self?.context.showAssistant?(nil, nil) }
        action("Review Permissions", id: "status.reviewPermissions", description: "Review current window-control and input capabilities.", to: permissions) { [weak self] in self?.context.navigate?(SearchDestination(page: .permissions, controlID: "permissions.accessibility.status")) }
        let scripts = card("Reoccurring Scripts · UI Stub")
        let stub = UI.caption("NONFUNCTIONAL UI STUB — examples only; nothing runs."); add(stub, to: scripts)
        metadata(stub, id: "status.scriptsState", label: "Scripts Preview Status", description: stub.stringValue, keywords: ["recurring", "reoccurring", "nonfunctional", "example"])
        action("Explore Scripts Preview", id: "status.scriptsSettings", description: "Open fictional script examples and sample history.", to: scripts) { [weak self] in self?.context.navigate?(SearchDestination(page: .scripts, controlID: "scripts.previewEnabled")) }
        let logs = card("Diagnostics")
        action("Open Log File", id: "status.openLog", description: "Open the current plain-text log in your default text application.", keywords: ["logfile", "error", "normal"], to: logs) { [weak self] in self?.context.openLog() }
        let warning = UI.caption(""); warning.textColor = .systemOrange; add(warning, to: logs)
        refreshers.append { [weak self, weak state, weak detail, weak resume, weak gestures, weak permissionState, weak failedAt, weak retry, weak warning] in
            guard let self = self else { return }
            let runtime = self.context.runtime
            state?.stringValue = runtime.state.rawValue
            state?.textColor = runtime.state == .running ? .systemGreen : (runtime.state == .failed ? .systemRed : .labelColor)
            detail?.stringValue = runtime.detail
            resume?.isHidden = !prefs.bool(.suspended)
            gestures?.stringValue = "Resizing: \(prefs.bool(.resizeEnabled) ? "On" : "Off")    ·    Moving: \(prefs.bool(.moveEnabled) ? "On" : "Off")"
            permissionState?.stringValue = self.context.permissions.summary
            failedAt?.stringValue = runtime.lastFailure.map { "Last engine fault: " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? ""
            failedAt?.isHidden = runtime.lastFailure == nil; retry?.isHidden = runtime.state != .failed
            warning?.stringValue = self.context.preferences.newerSchema ? "These preferences came from a newer version. Unknown settings have been preserved." : (self.context.preferences.repairMessage ?? "")
            warning?.isHidden = warning?.stringValue.isEmpty ?? true
        }
    }
}

final class WindowPageController: SettingsPageController {
    override func build() {
        let prefs = context.preferences
        add(UI.caption("Live control of the window beneath your pointer, including inactive windows where macOS permits it."))
        let enabled = card("")
        toggle("Enable Window Resizer", key: .enabled, id: "window.enabled", description: "Enable the window utility. Resize and move gestures can be switched on independently below.", keywords: ["utility", "background", "window"], section: "", to: enabled)
        let resize = card("Resize Windows")
        toggle("Resize Windows", key: .resizeEnabled, id: "window.resize.enabled", description: "Hold Command (⌘) and right-click near any of the four corners, then drag. The opposite corner stays in place.", keywords: ["cmd", "right click", "all four corners", "anchor"], section: "Resize Windows", to: resize, enabled: { prefs.bool(.enabled) })
        let popup = ActionPopup(items: ["Immediate", "After Small Drag"]) { prefs.set($0 == 0 ? "immediate" : "threshold", for: .activation) }
        add(UI.horizontal([UI.label("Activation"), NSView(), popup]), to: resize)
        metadata(popup, id: "window.resize.activation", label: "Resize Activation", description: "Immediate claims an eligible right-click without a drag threshold. After Small Drag preserves unclaimed clicks by delaying them briefly.", keywords: ["immediate", "small drag", "activation", "threshold"], section: "Resize Windows", value: { prefs.string(.activation) == "immediate" ? "Immediate" : "After Small Drag" })
        refreshers.append { [weak popup] in popup?.selectItem(at: prefs.string(.activation) == "immediate" ? 0 : 1); popup?.isEnabled = prefs.bool(.enabled) && prefs.bool(.resizeEnabled) }
        number("Drag Threshold", key: .resizeThreshold, id: "window.resize.threshold", description: "Used only for After Small Drag. Measured from mouse-down in logical screen points.", section: "Resize Windows", to: resize,
               enabled: { prefs.bool(.enabled) && prefs.bool(.resizeEnabled) && prefs.string(.activation) == "threshold" })
        number("Corner Size", key: .cornerSize, id: "window.resize.cornerSize", description: "The size of the corner areas inside each window. Defaults to 200 points. Once a drag starts, it continues outside the window.", section: "Resize Windows", to: resize,
               enabled: { prefs.bool(.enabled) && prefs.bool(.resizeEnabled) })
        let move = card("Window Moving")
        toggle("Move Windows", key: .moveEnabled, id: "window.move.enabled", description: "Hold Command (⌘), left-click in the window interior, and drag. The initial distance between the pointer and the window stays fixed.", keywords: ["cmd", "left click", "left drag", "interior", "move"], section: "Window Moving", to: move, enabled: { prefs.bool(.enabled) })
        number("Drag Threshold", key: .moveThreshold, id: "window.move.threshold", description: "Moving always starts after a small drag. Its threshold is independent of resize activation and defaults to 5 points.", section: "Window Moving", to: move,
               enabled: { prefs.bool(.enabled) && prefs.bool(.moveEnabled) })
        let feedback = card("Cursor & Overlays")
        toggle("Change Cursor During Gestures", key: .cursor, id: "window.feedback.cursor", description: "Show a diagonal resize cursor or a hand when the pointer is over an eligible area. Other applications may replace the cursor.", keywords: ["pointer", "hand", "diagonal", "feedback"], section: "Cursor & Overlays", to: feedback)
        toggle("Show Corner Hints", key: .hints, id: "window.feedback.cornerHints", description: "Show a glowing corner mark in your system accent colour while Command is held over an eligible resize corner. The glow pulses unless Reduce Motion is enabled.", keywords: ["overlay", "highlight", "corner", "hint", "neon", "glow", "accent", "colour"], section: "Cursor & Overlays", to: feedback)
        toggle("Show Window Outline", key: .outline, id: "window.feedback.frame", description: "Outline the actual accepted window frame while resizing or moving.", keywords: ["overlay", "border", "frame", "outline"], section: "Cursor & Overlays", to: feedback)
        let behavior = card("Gesture Behavior")
        add(UI.caption("Release Command or the mouse button to finish. Press Escape to try restoring the original frame. Windows may move partly off-screen, and inactive windows are not deliberately activated."), to: behavior)
        add(UI.caption("The original window stays selected throughout a drag, even when the pointer leaves it or moves over another window. If macOS limits the window's size or position, keep dragging or reverse direction to continue."), to: behavior)
        add(UI.caption("Moving starts in the content interior, away from the edges and title bar. Threshold activation briefly delays ordinary Command-clicks; long-press timing and synthetic-input handling can vary by app. Control-click is not a right-button shortcut."), to: behavior)
        add(UI.caption("macOS and individual applications can constrain or reject window changes. Permission changes take effect automatically when possible. Closing Settings keeps enabled features running."), to: behavior)
        action("Reset Window Resizer…", id: "window.reset", description: "Restore this utility's defaults. Master suspension, permissions, login preference, and logs are preserved.", keywords: ["defaults", "reset", "restore"], to: behavior) { [weak self] in
            self?.context.confirm?("Reset Window Resizer?", "This restores resize, moving, and feedback defaults. An active gesture ends at its current frame. Suspend All and other application settings are preserved.") { [weak self] in self?.context.runtime.endGestureForReset(); self?.context.preferences.resetWindow() }
        }
    }
}

final class GeneralPageController: SettingsPageController {
    override func build() {
        let behavior = card("Background Operation")
        add(UI.label("Close Settings to keep Jimmy Tweaks out of the way. Open the application again from Applications whenever you want to change settings."), to: behavior)
        add(UI.caption("Suspend All persists across launches. Quitting stops the current process; it does not change any saved login preference."), to: behavior)
        if context.login.available {
            let login = card("Login")
            let toggle = ActionButton("Launch Jimmy Tweaks at Login") {}; toggle.setButtonType(.switch)
            toggle.handler = { [weak self, weak toggle] in self?.context.login.setEnabled(toggle?.state == .on) }
            add(toggle, to: login)
            metadata(toggle, id: "general.launchAtLogin", label: "Launch Jimmy Tweaks at Login", description: "Start the installed, signed app silently when you sign in. Master suspension remains in effect.", keywords: ["startup", "sign in", "login", "launch"], section: "Login", unavailable: "Install a Developer ID signed Release copy in Applications first.", value: { [weak self] in self?.context.login.enabled == true ? "Enabled by system" : "Off" })
            let explanation = UI.caption(""); add(explanation, to: login)
            action("Open Login Items Settings", id: "general.openLoginSettings", description: "Review the system's actual login registration and approvals.", to: login) { [weak self] in self?.context.login.openSettings() }
            refreshers.append { [weak self, weak toggle, weak explanation] in
                guard let self = self else { return }; toggle?.state = self.context.login.enabled ? .on : .off
                toggle?.isEnabled = self.context.login.eligible; explanation?.stringValue = self.context.login.explanation
            }
        }
        let reset = card("Preferences")
        add(UI.caption("Changes take effect immediately. Resetting preferences does not revoke system permissions or delete logs."), to: reset)
        action("Reset All Preferences…", id: "general.resetAll", description: "Restore known preferences and scripts preview defaults. This can resume enabled features when permissions are granted.", keywords: ["reset", "defaults", "restore", "all"], to: reset) { [weak self] in
            self?.context.confirm?("Reset All Preferences?", "Window settings and the scripts preview return to their defaults. Suspend All turns off, so enabled features can resume immediately when permission is granted. Login startup is requested off. Permission grants, setup disposition, and logs are preserved.") { [weak self] in
                guard let self = self else { return }
                self.context.runtime.endGestureForReset()
                self.context.preferences.batch { self.context.login.reset(); self.context.preview.reset(); self.context.preferences.resetAll() }
                self.context.refresh?()
            }
        }
    }
}

final class PermissionsPageController: SettingsPageController {
    override func build() {
        let access = card("Window Control")
        let status = UI.label("", size: 17, weight: .semibold); add(status, to: access)
        metadata(status, id: "permissions.accessibility.status", label: "Accessibility Permission", description: "Trust is required to change other applications' window positions and sizes.", keywords: ["grant", "trust", "control", "device control", "data access"], section: "Window Control")
        add(UI.caption("Jimmy Tweaks uses Accessibility to control window geometry and a modifying input tap to recognize and consume only its gestures. It does not record typed content or capture your screen."), to: access)
        action("Enable Accessibility…", id: "permissions.accessibility.request", description: "Ask macOS to let you grant window-control access. Approval remains your choice in System Settings.", keywords: ["allow", "permission", "trust"], to: access) { [weak self] in self?.context.permissions.request() }
        action("Open System Settings", id: "permissions.accessibility.openSettings", description: "Open Privacy & Security to review Jimmy Tweaks' access.", to: access) { [weak self] in self?.context.permissions.openSettings() }
        add(UI.caption("If the direct link does not reach the right category, open System Settings → Privacy & Security and find the category for controlling other applications. Its name varies by macOS version and language."), to: access)
        let input = card("Input Capabilities")
        let posting = UI.caption(""); add(posting, to: input)
        metadata(posting, id: "permissions.inputControl.status", label: "Input Control", description: "Modifying input interception and safe click replay use the Accessibility-authorized control path.", keywords: ["tap", "event", "replay", "capture"], section: "Input Capabilities")
        let monitoring = UI.caption("Input Monitoring: Not required for this capture path."); add(monitoring, to: input)
        metadata(monitoring, id: "permissions.inputMonitoring.status", label: "Input Monitoring", description: monitoring.stringValue, keywords: ["listen", "monitoring", "keyboard", "permission"], section: "Input Capabilities")
        add(UI.caption("Newly granted access is checked automatically, and enabled gestures start when macOS makes access available. Use Check Again to refresh access and retry the input engine."), to: input)
        let assistant = card("Guided Setup")
        action("Check Again", id: "permissions.checkAgain", description: "Re-read system permission state and retry the input engine without prompting.", keywords: ["refresh", "recheck"], to: assistant) { [weak self] in self?.context.runtime.retry(); self?.refreshValues() }
        action("Open Permission Assistant…", id: "permissions.assistant", description: "Run the skippable guided permission setup again.", keywords: ["first run", "onboarding", "setup", "guide"], to: assistant) { [weak self] in self?.context.showAssistant?(nil, nil) }
        refreshers.append { [weak self, weak status, weak posting] in
            guard let self = self else { return }
            status?.stringValue = self.context.permissions.accessibility ? "Accessibility: Granted" : "Accessibility: Not Granted"
            status?.textColor = self.context.permissions.accessibility ? .systemGreen : .systemOrange
            posting?.stringValue = self.context.permissions.eventPosting ? "Input control: Available" : "Input control: Not available yet"
        }
    }
}

final class LoggingPageController: SettingsPageController {
    override func build() {
        let normal = card("Normal Logging")
        let policy = UI.caption("Local UTF-8 plain-text logs are retained for seven days (168 hours). Cleanup runs hourly and at startup. No typed content, window titles, document contents, or script URL values are logged.")
        add(policy, to: normal)
        metadata(policy, id: "logging.retention", label: "Log Retention", description: policy.stringValue, keywords: ["normal", "7 days", "seven", "plain text", "privacy", "168 hours"])
        let state = UI.label(""); add(state, to: normal)
        metadata(state, id: "logging.status", label: "Logging Status", description: "Current local logfile availability or a nonfatal file-access error.", keywords: ["error", "writer"])
        let path = UI.caption(""); path.isSelectable = true; add(path, to: normal)
        metadata(path, id: "logging.path", label: "Current Log File", description: "The file currently receiving normal diagnostic records.", keywords: ["location", "folder", "path", "logfile"])
        action("Open Log File", id: "logging.open", description: "Flush and open the current plain-text log in your default text application.", keywords: ["logfile", "text", "open"], to: normal) { [weak self] in self?.context.openLog() }
        action("Reveal Logs Folder", id: "logging.reveal", description: "Reveal the local Jimmy Tweaks logs directory in Finder.", keywords: ["Finder", "directory", "files"], to: normal) { [weak self] in
            guard let self = self else { return }; NSWorkspace.shared.activateFileViewerSelecting([self.context.logger.directory])
        }
        action("Retry Log Writer", id: "logging.retry", description: "Try creating or reopening the log after a local file error.", keywords: ["failure", "disk", "access"], to: normal) { [weak self] in self?.context.logger.retry() }
        refreshers.append { [weak self, weak state, weak path] in
            guard let self = self else { return }; let status = self.context.logger.status
            state?.stringValue = status.error ?? "Normal logging · Local only"; state?.textColor = status.error == nil ? .labelColor : .systemOrange
            path?.stringValue = status.path ?? self.context.logger.directory.path
        }
    }
}

final class AboutPageController: SettingsPageController {
    override func build() {
        let card = card("Jimmy Tweaks")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let label = UI.label("Version \(version) (\(build))", size: 17, weight: .medium); add(label, to: card)
        metadata(label, id: "about.version", label: "Application Version", description: label.stringValue, keywords: ["version", "build", "Jimmy Tweaks"])
        let platform = UI.caption("Native Swift and AppKit · macOS 27 or later · Apple silicon"); add(platform, to: card)
        metadata(platform, id: "about.platform", label: "Supported Platform", description: platform.stringValue, keywords: ["macOS", "27", "system", "requirements"])
        add(UI.label("Small window gestures. Native settings. Quiet background operation."), to: card)
        add(UI.caption("Window resizing and moving run locally with your permission. Reoccurring Scripts is a nonfunctional interface preview. No account, analytics, network connection, or telemetry is used."), to: card)
    }
}
