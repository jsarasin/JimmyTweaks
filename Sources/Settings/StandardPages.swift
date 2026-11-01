import AppKit

final class GeneralPageController: SettingsPageController {
    override func build() {
        let options = card("Preferences")
        toggle("Show menu bar icon", key: .showMenuBarIcon, id: "general.menuBarIcon", description: "Show the gothic J in the menu bar for quick access to Jimmy Tweaks.", keywords: ["menu", "icon", "status", "J"], section: "Preferences", to: options)
        toggle("Suspend All", key: .suspended, id: "global.suspendAll", description: "Pause all enabled features and restore absorbed icons. Your individual settings are preserved.", keywords: ["pause", "resume", "stop", "master"], section: "Preferences", to: options)
        add(UI.caption("Closing Settings keeps enabled features running. Reopen it from the menu bar icon or Applications."), to: options)
        if context.login.available {
            let login = ActionButton("Launch at login") {}; login.setButtonType(.switch)
            login.handler = { [weak self, weak login] in self?.context.login.setEnabled(login?.state == .on) }
            add(login, to: options)
            metadata(login, id: "general.launchAtLogin", label: "Launch at Login", description: "Start the installed, signed application silently when you sign in.", keywords: ["startup", "login", "launch"], section: "Preferences", unavailable: "Install a Developer ID signed Release copy in Applications first.")
            let explanation = UI.caption(""); add(explanation, to: options)
            refreshers.append { [weak self, weak login, weak explanation] in
                guard let self else { return }
                login?.state = self.context.login.enabled ? .on : .off
                login?.isEnabled = self.context.login.eligible; explanation?.stringValue = self.context.login.explanation
            }
        }
        let reset = card("")
        action("Reset All Preferences…", id: "general.resetAll", description: "Restore known preferences and script-preview defaults. System permission grants and logs are preserved.", keywords: ["reset", "defaults", "restore"], to: reset) { [weak self] in
            self?.context.confirm?("Reset All Preferences?", "All feature settings return to their defaults. Suspend All turns off and Icon Absorber turns off. Permission grants and logs are preserved.") { [weak self] in
                guard let self else { return }
                self.context.runtime.endGestureForReset()
                self.context.preferences.batch { self.context.login.reset(); self.context.preview.reset(); self.context.preferences.resetAll() }
                self.context.refresh?()
            }
        }
    }
}

final class PermissionsPageController: SettingsPageController {
    private func addGuide(for permission: PermissionEntry, to card: NSStackView) {
        let guide = SystemAccessGuide(permission: permission)
        guide.heightAnchor.constraint(equalToConstant: guide.intrinsicContentSize.height).isActive = true
        add(guide, to: card)
    }
    override func build() {
        add(UI.caption("Manage the macOS permissions used by Jimmy Tweaks. Each module links to the access it needs."))
        let reset = card("Reset for Testing")
        add(UI.caption("Clear Jimmy Tweaks’ macOS privacy permissions, then quit for a clean next launch. Your shortcut definitions and app preferences are preserved."), to: reset)
        let resetButton = action("Reset macOS Permissions and Quit…", id: "permissions.reset", description: "Reset only this build’s macOS privacy permissions and quit. Reopen Jimmy Tweaks to grant access again.", keywords: ["remove", "clear", "reset", "testing", "tcc", "privacy"], to: reset) { [weak self] in
            self?.context.confirm?("Reset macOS Permissions and Quit?", "This clears privacy permission decisions for Jimmy Tweaks and then quits the app. Reopen it to grant access again. macOS may keep some entries listed; Login Items and other System Settings are not reset. Your shortcut definitions and app preferences are preserved.") { [weak self] in
                self?.context.resetPermissionsAndQuit?()
            }
        }
        resetButton.hasDestructiveAction = true
        let access = card(PermissionEntry.accessibility.title)
        metadata(access, id: PermissionEntry.accessibility.controlID, label: "Accessibility — Device Control and Data Access", description: "Required for Window Resizer, Icon Absorber, and Absorbing shortcuts.", keywords: ["permission", "device control", "data access", "window", "menu bar", "absorbing"], section: "Accessibility")
        addGuide(for: .accessibility, to: access)
        add(UI.label("Enable Jimmy Tweaks in Device Control and Data Access to control windows, discover menu bar applications, and intercept Absorbing shortcuts."), to: access)
        let status = UI.caption(""); add(status, to: access)
        action("Open System Settings", id: "permissions.accessibility.open", description: "Open macOS privacy settings for Accessibility / Device Control and Data Access.", keywords: ["allow", "grant", "system settings"], section: "Accessibility", to: access) { [weak self] in self?.context.permissions.openSettings() }
        refreshers.append { [weak self, weak status] in
            guard let self, let status else { return }
            UI.updateSystemAccessStatus(status, permissions: self.context.permissions)
        }

        let input = card(PermissionEntry.inputMonitoring.title)
        metadata(input, id: PermissionEntry.inputMonitoring.controlID, label: "Input Monitoring", description: "Observe Transparent shortcuts and record global keyboard and mouse combinations.", keywords: ["permission", "keyboard", "mouse", "listen", "transparent", "recorder"], section: "Input Monitoring")
        addGuide(for: .inputMonitoring, to: input)
        add(UI.caption("Used by Transparent shortcuts and the global shortcut recorder. Accessibility may also permit observation; the module checks whether input observation can actually start."), to: input)
        let inputStatus = UI.caption(""); add(inputStatus, to: input)
        let request = action("Allow Input Monitoring", id: "permissions.inputMonitoring.allow", description: "Ask macOS for Input Monitoring access. A denied request is not repeated automatically.", keywords: ["grant", "listen", "request"], section: "Input Monitoring", to: input) { [weak self] in self?.context.permissions.requestShortcutObservation() }
        action("Open Input Monitoring Settings…", id: "permissions.inputMonitoring.open", description: "Open macOS Input Monitoring privacy settings.", keywords: ["system settings", "allow", "listen"], section: "Input Monitoring", to: input) { [weak self] in self?.context.permissions.openInputMonitoringSettings() }
        refreshers.append { [weak self, weak inputStatus, weak request] in
            guard let self else { return }
            let granted = self.context.permissions.inputMonitoring
            inputStatus?.stringValue = granted ? "Permission granted" : "Input Monitoring has not been granted."
            inputStatus?.textColor = granted ? .systemGreen : .systemOrange
            request?.isEnabled = !granted
        }

        let screen = card(PermissionEntry.screenRecording.title)
        metadata(screen, id: PermissionEntry.screenRecording.controlID, label: "Screen Recording", description: "Optional access for capturing original menu bar icon pictures. Review capture access for native screenshot actions here.", keywords: ["permission", "screen capture", "clipboard", "screenshot", "icon pictures"], section: "Screen Recording")
        addGuide(for: .screenRecording, to: screen)
        add(UI.caption("Optional for Icon Absorber’s original icon pictures. Native screenshot actions use the macOS screenshot utility; macOS handles authorization for that operation."), to: screen)
        let screenStatus = UI.caption(""); add(screenStatus, to: screen)
        action("Open Screen Recording Settings…", id: "permissions.screenRecording.open", description: "Open macOS Screen Recording privacy settings. No screen is captured by opening this entry.", keywords: ["system settings", "capture", "allow"], section: "Screen Recording", to: screen) { [weak self] in self?.context.permissions.openScreenRecordingSettings() }
        refreshers.append { [weak self, weak screenStatus] in
            guard let self else { return }
            let granted = self.context.permissions.screenRecording
            screenStatus?.stringValue = granted ? "Permission granted" : "Screen Recording has not been granted. Optional features can use application icons instead."
            screenStatus?.textColor = granted ? .systemGreen : .secondaryLabelColor
        }
        let refresh = card("")
        action("Check Permissions Again", id: "permissions.refresh", description: "Refresh permission status and retry the input engine without requesting a new grant.", keywords: ["retry", "refresh", "access"], to: refresh) { [weak self] in self?.context.runtime.shortcuts.retry() }
    }
}

final class WindowPageController: SettingsPageController {
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    override func build() {
        let prefs = context.preferences
        add(UI.caption("Live control of the window beneath your pointer, including inactive windows where macOS permits it."))
        let enabled = card("")
        toggle("Enable Window Resizer", key: .enabled, id: "window.enabled", description: "Enable the window utility. Resize and move gestures can be switched on independently below.", keywords: ["utility", "background", "window"], section: "", to: enabled)
        permissionLink(.accessibility, to: enabled)
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
        toggle("Show Corner Hints", key: .hints, id: "window.feedback.cornerHints", description: "Mark eligible resize corners while Command is held and throughout resizing. Animated corners use their own iridescent colours; static markers use your system accent colour.", keywords: ["overlay", "highlight", "corner", "hint", "neon", "glow", "accent", "colour"], section: "Cursor & Overlays", to: feedback)
        let animated = ActionButton("Animated effects") {}; animated.setButtonType(.switch)
        animated.handler = { [weak animated] in prefs.set(animated?.state == .on, for: .animatedEffects) }
        let motionNote = UI.caption("Disabled because Reduce Motion is enabled in System Settings.")
        add(UI.horizontal([animated, motionNote]), to: feedback)
        add(UI.caption("Iridescent corner energy and blue moving mist respond to window motion and dissolve into grey smoke on release or when switching gestures. Turn off for a steady corner marker and a simple moving outline."), to: feedback)
        metadata(animated, id: "window.feedback.animatedEffects", label: "Animated Effects", description: "Animate iridescent resize energy, blue moving mist, and brief grey smoke transitions. Reduce Motion uses static visuals and preserves your saved preference.", keywords: ["fire", "flame", "fog", "mist", "neon", "animation", "reduce motion"], section: "Cursor & Overlays", unavailable: "Disabled because Reduce Motion is enabled in System Settings.")
        let refreshMotion = { [weak self, weak animated, weak motionNote] in
            let reduced = self?.reduceMotion() ?? true
            animated?.isEnabled = !reduced
            animated?.state = !reduced && prefs.bool(.animatedEffects) ? .on : .off
            motionNote?.isHidden = !reduced
        }
        refreshers.append(refreshMotion)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionSettingsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        toggle("Show Window Outline", key: .outline, id: "window.feedback.frame", description: "Outline the actual accepted window frame while resizing or moving.", keywords: ["overlay", "border", "frame", "outline"], section: "Cursor & Overlays", to: feedback)
        let behavior = card("Gesture Behavior")
        add(UI.caption("Release the mouse button to finish moving or resizing. Keep Command held to leave the effect idling at the window; release Command to disperse animated effects in a quick grey smoke poof. Press Escape during a gesture to try restoring the original frame. Windows may move partly off-screen, and inactive windows are not deliberately activated."), to: behavior)
        add(UI.caption("The original window stays selected throughout a drag, even when the pointer leaves it or moves over another window. If macOS limits the window's size or position, keep dragging or reverse direction to continue."), to: behavior)
        add(UI.caption("Moving starts in the content interior, away from the edges and title bar. Threshold activation briefly delays ordinary Command-clicks; long-press timing and synthetic-input handling can vary by app. Control-click is not a right-button shortcut."), to: behavior)
        add(UI.caption("macOS and individual applications can constrain or reject window changes. Permission changes take effect automatically when possible. Closing Settings keeps enabled features running."), to: behavior)
        action("Reset Window Resizer…", id: "window.reset", description: "Restore this utility's defaults. Master suspension, permissions, login preference, and logs are preserved.", keywords: ["defaults", "reset", "restore"], to: behavior) { [weak self] in
            self?.context.confirm?("Reset Window Resizer?", "This restores resize, moving, and feedback defaults. An active gesture ends at its current frame. Suspend All and other application settings are preserved.") { [weak self] in self?.context.runtime.endGestureForReset(); self?.context.preferences.resetWindow() }
        }
    }
    @objc private func motionSettingsChanged() { refreshValues() }
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
