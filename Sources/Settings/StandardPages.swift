import AppKit

final class GeneralPageController: SettingsPageController {
    override func build() {
        let preferences = context.preferences
        let options = card("Preferences")
        toggle("Show menu bar icon", key: .showMenuBarIcon, id: "general.menuBarIcon", description: "Show the Celtic J in the menu bar for quick access to Jimmy Tweaks.", keywords: ["menu", "icon", "status", "J"], section: "Preferences", to: options)
        toggle("Control volume from the menu bar icon", key: .menuBarAudio, id: "general.menuBarAudio", description: "Scroll up over Jimmy Tweaks’ menu bar icon to turn up the current sound output; scroll down to turn it down. Middle-click to toggle mute. Suspend All pauses this feature.", keywords: ["sound", "volume", "audio", "wheel", "middle click", "mute", "output", "speaker"], section: "Preferences", to: options, enabled: { preferences.bool(.showMenuBarIcon) }, unavailable: "Show the menu bar icon first.")
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
    }
}

final class PermissionsPageController: SettingsPageController {
    private func addActions(for permission: PermissionEntry, to card: NSStackView) {
        let permissions = context.permissions
        let feedback = UI.caption("")
        feedback.identifier = NSUserInterfaceItemIdentifier("\(permission.controlID).requestFeedback")
        feedback.isHidden = true; feedback.isSelectable = true
        let open = ActionButton("Open \(permission.title)") { permissions.openSettings(for: permission) }
        let request = ActionButton("Request \(permission.title)") { [weak self, weak feedback] in
            permissions.request(permission); self?.refreshValues()
            if permission == .inputMonitoring {
                let opened = permissions.openInputMonitoringSettings()
                feedback?.stringValue = "Request sent to macOS. " +
                    (opened ? "Review Input Monitoring in System Settings." : "Open System Settings → Privacy & Security → Input Monitoring manually.") +
                    " If no prompt appears, enable Jimmy Tweaks there. If it is missing, use + to add this copy:\n\(Bundle.main.bundleURL.path)"
                feedback?.isHidden = false
                self?.context.logger.log("permissions", "input-monitoring.request", "Native request invoked; listeningAvailable=\(permissions.inputMonitoring); accessibility=\(permissions.accessibility); settingsOpened=\(opened)")
            }
        }
        let check = ActionButton("Check for approval") { [weak self] in
            permissions.refresh(); self?.refreshValues()
        }
        let row = UI.horizontal([open, request, check], spacing: 8)
        row.distribution = .fillEqually
        for (button, suffix, description) in [
            (open, "open", "Open \(permission.title) in System Settings without requesting access."),
            (request, "request", "Request Jimmy Tweaks access to \(permission.title). macOS controls approval."),
            (check, "check", "Check approval for \(permission.title) without requesting access.")
        ] {
            button.bezelStyle = .regularSquare
            button.font = .systemFont(ofSize: 12)
            button.cell?.usesSingleLineMode = false; button.cell?.isScrollable = false
            button.cell?.wraps = true; button.cell?.lineBreakMode = .byWordWrapping
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.heightAnchor.constraint(equalToConstant: 76).isActive = true
            metadata(button, id: "\(permission.controlID).\(suffix)", label: button.title,
                     description: description, keywords: ["permission", "allow", "approval", "system settings"], section: permission.title)
        }
        if permission == .inputMonitoring { add(feedback, to: card) }
        add(row, to: card)
    }
    private func addGuide(for permission: PermissionEntry, to card: NSStackView) {
        let guide = SystemAccessGuide(permission: permission)
        guide.heightAnchor.constraint(equalToConstant: guide.intrinsicContentSize.height).isActive = true
        add(guide, to: card)
        add(UI.caption("Example System Settings — the illustration does not show your current permission status."), to: card)
    }
    override func build() {
        add(UI.caption("Jimmy Tweaks does not request permissions at launch. Use Request to ask macOS for access, then Check for approval to refresh the status. While this page is visible, missing access is also checked automatically every two seconds."))
        let reset = card("Reset permissions and uninstall workers")
        add(UI.caption("Prepare for a fresh install: restore sleep settings and absorbed icons, remove workers and launch at login, reset privacy permissions, and delete saved settings, shortcuts, requests, responses, logs, and caches. Jimmy Tweaks then quits."), to: reset)
        let resetButton = action("Reset Permissions and Uninstall Workers…", id: "permissions.reset", description: "Remove Jimmy Tweaks’ workers, privacy permissions, saved settings, shortcuts, requests, responses, logs, and caches, then quit for a fresh install.", keywords: ["remove", "clear", "reset", "testing", "tcc", "privacy", "uninstall", "workers", "fresh install"], to: reset) { [weak self] in
            self?.context.confirm?("Reset Permissions and Uninstall Workers?", "This permanently deletes Jimmy Tweaks’ saved settings, custom shortcuts, requests, responses, logs, and caches. It restores the sleep setting, releases absorbed icons, removes the power worker and launch-at-login registration, resets this app’s macOS privacy permissions, and quits. The application itself stays installed. If cleanup fails, the app will report what remains.") { [weak self] in
                self?.context.resetAndUninstallWorkers?()
            }
        }
        resetButton.hasDestructiveAction = true
        let access = card(PermissionEntry.accessibility.title)
        metadata(access, id: PermissionEntry.accessibility.controlID, label: PermissionEntry.accessibility.title, description: "Required for Window Move & Resize, Icon Absorber, and Absorbing shortcuts.", keywords: ["permission", "accessibility", "device control", "data access", "window", "menu bar", "absorbing"], section: PermissionEntry.accessibility.title)
        addGuide(for: .accessibility, to: access)
        add(UI.label("Enable Jimmy Tweaks in Device Control and Data Access to control windows, discover menu bar applications, and intercept Absorbing shortcuts."), to: access)
        let status = UI.caption(""); status.identifier = NSUserInterfaceItemIdentifier("permissions.accessibility.status"); add(status, to: access)
        addActions(for: .accessibility, to: access)
        refreshers.append { [weak self, weak status] in
            guard let self, let status else { return }
            UI.updateSystemAccessStatus(status, permissions: self.context.permissions)
        }

        let input = card(PermissionEntry.inputMonitoring.title)
        metadata(input, id: PermissionEntry.inputMonitoring.controlID, label: "Input Monitoring", description: "Observe Transparent shortcuts and record global keyboard and mouse combinations.", keywords: ["permission", "keyboard", "mouse", "listen", "transparent", "recorder"], section: "Input Monitoring")
        addGuide(for: .inputMonitoring, to: input)
        add(UI.caption("Used for Transparent shortcuts and the global shortcut recorder without broader device control. Device Control and Data Access already covers input observation. Request always asks macOS for Input Monitoring access and opens its settings; macOS may suppress a new prompt. If Jimmy Tweaks is missing, use + in System Settings to add this copy."), to: input)
        let inputStatus = UI.caption(""); inputStatus.identifier = NSUserInterfaceItemIdentifier("permissions.inputMonitoring.status"); add(inputStatus, to: input)
        addActions(for: .inputMonitoring, to: input)
        refreshers.append { [weak self, weak inputStatus] in
            guard let self else { return }
            let permissions = self.context.permissions
            if permissions.accessibility {
                inputStatus?.stringValue = "Covered by Device Control and Data Access. Separate Input Monitoring approval is optional and is not confirmed by this status."
            } else {
                inputStatus?.stringValue = permissions.inputMonitoring ? "Input observation available." : "Enable Jimmy Tweaks in Input Monitoring in System Settings."
            }
            inputStatus?.textColor = permissions.accessibility || permissions.inputMonitoring ? .systemGreen : .systemOrange
        }

        let screen = card(PermissionEntry.screenRecording.title)
        metadata(screen, id: PermissionEntry.screenRecording.controlID, label: PermissionEntry.screenRecording.title, description: "Optional access for capturing original menu bar icon pictures. Review capture access for native screenshot actions here.", keywords: ["permission", "screen recording", "screen capture", "clipboard", "screenshot", "icon pictures"], section: PermissionEntry.screenRecording.title)
        addGuide(for: .screenRecording, to: screen)
        add(UI.caption("Optional access for Icon Absorber’s original icon pictures. Use Request to register access with macOS; requesting does not capture an image. If access was denied before, enable Jimmy Tweaks in Screen & System Audio Recording in System Settings. If it is still missing, use the + button there to add it. Native screenshot actions use the macOS screenshot utility."), to: screen)
        let screenStatus = UI.caption(""); screenStatus.identifier = NSUserInterfaceItemIdentifier("permissions.screenRecording.status"); add(screenStatus, to: screen)
        addActions(for: .screenRecording, to: screen)
        refreshers.append { [weak self, weak screenStatus] in
            guard let self else { return }
            let granted = self.context.permissions.screenRecording
            screenStatus?.stringValue = granted ? "Permission granted" : "Enable Jimmy Tweaks in Screen & System Audio Recording in System Settings. Application icons are used until access is granted."
            screenStatus?.textColor = granted ? .systemGreen : .systemOrange
        }
    }
}

final class WindowPageController: SettingsPageController {
    override func build() {
        let prefs = context.preferences
        add(UI.caption("Live control of the window beneath your pointer, including inactive windows where macOS permits it."))
        let enabled = card("")
        toggle("Enable Window Move & Resize", key: .enabled, id: "window.enabled", description: "Enable the window utility. Resize and move gestures can be switched on independently below.", keywords: ["utility", "background", "window"], section: "", to: enabled)
        permissionLink(.accessibility, to: enabled)
        let areas = card("Activation Areas")
        number("Edge Zone Size", key: .edgeZoneSize, id: "window.edgeZoneSize", description: "Measured inward from every window edge in points. Command + right-drag in this outer band resizes from the nearest corner; Command + left-drag in the centre moves. The areas meet without gaps or overlaps. Defaults to 200 points (8–400). Small windows narrow the band automatically to keep a usable moving centre.", section: "Activation Areas", to: areas,
               enabled: { prefs.bool(.enabled) && (prefs.bool(.resizeEnabled) || prefs.bool(.moveEnabled)) })
        let resize = card("Resize Windows")
        toggle("Resize Windows", key: .resizeEnabled, id: "window.resize.enabled", description: "Hold Command (⌘) and right-click in the outer edge zone, then drag. The nearest corner resizes and the opposite corner stays in place.", keywords: ["cmd", "right click", "all four corners", "edge", "anchor"], section: "Resize Windows", to: resize, enabled: { prefs.bool(.enabled) })
        let popup = ActionPopup(items: ["Immediate", "After Small Drag"]) { prefs.set($0 == 0 ? "immediate" : "threshold", for: .activation) }
        add(UI.horizontal([UI.label("Activation"), NSView(), popup]), to: resize)
        metadata(popup, id: "window.resize.activation", label: "Resize Activation", description: "Immediate claims an eligible right-click without a drag threshold. After Small Drag preserves unclaimed clicks by delaying them briefly.", keywords: ["immediate", "small drag", "activation", "threshold"], section: "Resize Windows", value: { prefs.string(.activation) == "immediate" ? "Immediate" : "After Small Drag" })
        refreshers.append { [weak popup] in popup?.selectItem(at: prefs.string(.activation) == "immediate" ? 0 : 1); popup?.isEnabled = prefs.bool(.enabled) && prefs.bool(.resizeEnabled) }
        number("Drag Threshold", key: .resizeThreshold, id: "window.resize.threshold", description: "Used only for After Small Drag. Measured from mouse-down in logical screen points.", section: "Resize Windows", to: resize,
               enabled: { prefs.bool(.enabled) && prefs.bool(.resizeEnabled) && prefs.string(.activation) == "threshold" })
        let move = card("Window Moving")
        toggle("Move Windows", key: .moveEnabled, id: "window.move.enabled", description: "Hold Command (⌘), left-click in the centre beyond the shared edge zone, and drag. The initial distance between the pointer and the window stays fixed.", keywords: ["cmd", "left click", "left drag", "interior", "centre", "move"], section: "Window Moving", to: move, enabled: { prefs.bool(.enabled) })
        number("Drag Threshold", key: .moveThreshold, id: "window.move.threshold", description: "Moving always starts after a small drag. Its threshold is independent of resize activation and defaults to 5 points.", section: "Window Moving", to: move,
               enabled: { prefs.bool(.enabled) && prefs.bool(.moveEnabled) })
        let feedback = card("Cursor")
        toggle("Change Cursor During Gestures", key: .cursor, id: "window.feedback.cursor", description: "Show a diagonal resize cursor or a hand when the pointer is over an eligible area. Other applications may replace the cursor.", keywords: ["pointer", "hand", "diagonal", "feedback"], section: "Cursor", to: feedback)
        let behavior = card("Gesture Behavior")
        add(UI.caption("Release the mouse button to finish moving or resizing. Keep Command held to leave the effect idling at the window. Release Command to let wind gusts drift away, lightning fizzle out, and other effects disperse into grey smoke. Press Escape during a gesture to try restoring the original frame. Windows may move partly off-screen, and inactive windows are not deliberately activated."), to: behavior)
        add(UI.caption("The original window stays selected throughout a drag, even when the pointer leaves it or moves over another window. If macOS limits the window's size or position, keep dragging or reverse direction to continue."), to: behavior)
        add(UI.caption("Edge Zone Size sets the shared boundary between resizing and moving, measured from the outer window frame. Threshold activation briefly delays ordinary Command-clicks; long-press timing and synthetic-input handling can vary by app. Control-click is not a right-button shortcut."), to: behavior)
        add(UI.caption("macOS and individual applications can constrain or reject window changes. Permission changes take effect automatically when possible. Closing Settings keeps enabled features running."), to: behavior)
        action("Reset Window Move & Resize…", id: "window.reset", description: "Restore this utility's defaults. Master suspension, permissions, login preference, and logs are preserved.", keywords: ["defaults", "reset", "restore"], to: behavior) { [weak self] in
            self?.context.confirm?("Reset Window Move & Resize?", "This restores resize, moving, and feedback defaults. An active gesture ends at its current frame. Suspend All and other application settings are preserved.") { [weak self] in self?.context.runtime.endGestureForReset(); self?.context.preferences.resetWindow() }
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
        let icon = NSImageView(image: BrandIcon.applicationImage(size: 256))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignCenter
        icon.setAccessibilityLabel("Jimmy Tweaks app icon")
        icon.heightAnchor.constraint(equalToConstant: 256).isActive = true
        add(icon)
        let card = card("Jimmy Tweaks")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let label = UI.label("Version \(version) (\(build))", size: 17, weight: .medium); add(label, to: card)
        metadata(label, id: "about.version", label: "Application Version", description: label.stringValue, keywords: ["version", "build", "Jimmy Tweaks"])
        let platform = UI.caption("Native Swift and AppKit · macOS 27 or later · Apple silicon"); add(platform, to: card)
        metadata(platform, id: "about.platform", label: "Supported Platform", description: platform.stringValue, keywords: ["macOS", "27", "system", "requirements"])
        add(UI.label("Small window gestures. Native settings. Quiet background operation."), to: card)
        add(UI.caption("Window resizing and moving run locally with your permission. Recurring Requests sends only the HTTP/API calls you configure, manually or on a schedule. No account, analytics, or telemetry is used."), to: card)
    }
}
