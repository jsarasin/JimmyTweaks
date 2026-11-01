import AppKit

/// A condensed, noninteractive illustration, using no account information from the Mac.
final class SystemAccessGuide: NSView {
    let permission: PermissionEntry
    private let portrait = Bundle.main.url(forResource: "PermissionGuidePortrait", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    private let appIcon = BrandIcon.applicationImage(size: 64)
    private var panelTitle: String {
        switch permission {
        case .accessibility: return "Device Control and Data Access"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen & System Audio Recording"
        }
    }
    private var panelDescription: String {
        switch permission {
        case .accessibility:
            return "Apps with this access can view and send email, edit contacts and photos, monitor your keyboard, track websites, record your screen, control any app on your Mac, and more."
        case .inputMonitoring:
            return "Allow the applications below to monitor input from your keyboard, mouse or trackpad, even while using other applications."
        case .screenRecording:
            return "Allow the applications below to record the content of your screen and audio, even while using other applications."
        }
    }
    init(permission: PermissionEntry) {
        self.permission = permission
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("\(permission.controlID).guide")
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Example System Settings: \(panelTitle). Enable the Jimmy Tweaks switch. Alex Morgan is a fictional account; this illustration does not show your account or current permission state.")
    }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 205) }
    private func text(_ string: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, wraps: Bool = false) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        (string as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let background = NSColor(calibratedWhite: dark ? 0.14 : 0.97, alpha: 1)
        let sidebar = NSColor(calibratedWhite: dark ? 0.18 : 0.93, alpha: 1)
        let foreground = NSColor(calibratedWhite: dark ? 0.94 : 0.12, alpha: 1)
        let secondary = NSColor(calibratedWhite: dark ? 0.65 : 0.43, alpha: 1)
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5), shell = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState(); shell.addClip(); background.setFill(); frame.fill()
        let sideWidth: CGFloat = bounds.width < 540 ? 144 : 162
        sidebar.setFill(); NSRect(x: 0, y: 0, width: sideWidth, height: bounds.height).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill(); NSBezierPath(ovalIn: NSRect(x: 13 + CGFloat(index) * 13, y: bounds.height - 23, width: 8, height: 8)).fill()
        }
        let titleX = sideWidth + 16
        text(panelTitle, in: NSRect(x: titleX, y: bounds.height - 32, width: bounds.width - titleX - 12, height: 20), size: 12, weight: .semibold, color: foreground)
        let search = NSRect(x: 10, y: bounds.height - 57, width: sideWidth - 20, height: 23)
        NSColor(calibratedWhite: dark ? 0.28 : 0.86, alpha: 1).setFill(); NSBezierPath(roundedRect: search, xRadius: 7, yRadius: 7).fill()
        text("⌕  Search", in: search.insetBy(dx: 8, dy: 3), size: 10, color: secondary)
        let avatar = NSRect(x: 12, y: bounds.height - 107, width: 34, height: 34)
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(ovalIn: avatar).addClip()
        if let portrait { portrait.draw(in: avatar) }
        else { NSColor.systemBlue.setFill(); avatar.fill(); text("AM", in: avatar.insetBy(dx: 6, dy: 8), size: 13, weight: .semibold, color: .white) }
        NSGraphicsContext.restoreGraphicsState()
        text("Alex Morgan", in: NSRect(x: 53, y: avatar.minY + 16, width: sideWidth - 59, height: 17), size: 11, weight: .semibold, color: foreground)
        text("Apple Account", in: NSRect(x: 53, y: avatar.minY + 3, width: sideWidth - 59, height: 14), size: 9, color: secondary)
        for (index, name) in ["Wi-Fi", "Bluetooth", "Privacy & Security"].enumerated() {
            let row = NSRect(x: 9, y: bounds.height - 138 - CGFloat(index) * 25, width: sideWidth - 18, height: 22)
            if index == 2 { NSColor.controlAccentColor.withAlphaComponent(dark ? 0.38 : 0.16).setFill(); NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill() }
            let badge = NSRect(x: row.minX + 5, y: row.minY + 3, width: 16, height: 16)
            NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            if index == 1 {
                let rune = NSBezierPath(); rune.lineWidth = 1.1
                rune.move(to: NSPoint(x: badge.minX + 4, y: badge.minY + 4))
                for point in [NSPoint(x: 12, y: 11), NSPoint(x: 8, y: 14), NSPoint(x: 8, y: 2), NSPoint(x: 12, y: 5), NSPoint(x: 4, y: 12)] {
                    rune.line(to: NSPoint(x: badge.minX + point.x, y: badge.minY + point.y))
                }
                NSColor.white.setStroke(); rune.stroke()
            } else {
                let symbol = index == 0 ? "wifi" : "hand.raised.fill"
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.white]))?.draw(in: badge.insetBy(dx: 2, dy: 2))
            }
            text(name, in: NSRect(x: row.minX + 25, y: row.minY + 3, width: row.width - 28, height: 17), size: 10, color: foreground)
        }
        text(panelDescription, in: NSRect(x: titleX, y: bounds.height - 125, width: bounds.width - titleX - 16, height: 81), size: 11, color: secondary, wraps: true)
        let appRow = NSRect(x: titleX, y: bounds.height - 185, width: bounds.width - titleX - 16, height: 48)
        NSColor(calibratedWhite: dark ? 0.29 : 0.88, alpha: 1).setFill(); NSBezierPath(roundedRect: appRow, xRadius: 7, yRadius: 7).fill()
        let icon = NSRect(x: appRow.minX + 10, y: appRow.midY - 12, width: 24, height: 24)
        appIcon.draw(in: icon.insetBy(dx: -3, dy: -3))
        text("Jimmy Tweaks", in: NSRect(x: icon.maxX + 8, y: appRow.midY - 9, width: max(60, appRow.width - 111), height: 19), size: 12, weight: .semibold, color: foreground)
        let toggle = NSRect(x: appRow.maxX - 43, y: appRow.midY - 9, width: 32, height: 18)
        NSColor.systemOrange.setFill(); NSBezierPath(roundedRect: toggle, xRadius: 9, yRadius: 9).fill()
        NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: toggle.maxX - 16, y: toggle.minY + 2, width: 14, height: 14)).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke(); shell.lineWidth = 0.5; shell.stroke()
    }
}
