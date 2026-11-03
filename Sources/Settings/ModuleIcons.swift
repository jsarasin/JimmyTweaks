import AppKit

struct ModuleIconAppearance: Equatable {
    enum Style: String, CaseIterable { case standard, dark, clear, tinted }
    let style: Style
    let dark: Bool
    let tint: NSColor
    static func resolve(theme: String?, systemDark: Bool, tint: NSColor = .controlAccentColor) -> ModuleIconAppearance {
        let supported = ["RegularLight", "RegularDark", "RegularAutomatic", "ClearLight", "ClearDark", "ClearAutomatic", "TintedLight", "TintedDark", "TintedAutomatic"]
        let token = theme.flatMap { supported.contains($0) ? $0 : nil } ?? "RegularLight"
        let dark = token.hasSuffix("Dark") || (token.hasSuffix("Automatic") && systemDark)
        let style: Style = token.hasPrefix("Clear") ? .clear : token.hasPrefix("Tinted") ? .tinted : dark ? .dark : .standard
        return ModuleIconAppearance(style: style, dark: dark, tint: tint.usingColorSpace(.deviceRGB) ?? .systemBlue)
    }
    static func current(appearance: NSAppearance) -> ModuleIconAppearance {
        // These are read-only, best-effort macOS preference tokens, not a public
        // styling API. Unknown/missing values safely use the standard artwork.
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        func string(_ key: String) -> String? {
            CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        }
        let color = string("AppleIconAppearanceTintColor") ?? ""
        let names: [String: NSColor] = ["Blue": .systemBlue, "Purple": .systemPurple, "Pink": .systemPink, "Red": .systemRed,
                                        "Orange": .systemOrange, "Yellow": .systemYellow, "Green": .systemGreen, "Graphite": .systemGray]
        var tint = names[color] ?? NSColor.controlAccentColor
        if color == "Other", let text = string("AppleIconAppearanceCustomTintColor") {
            let parts = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
            if parts.count >= 3, parts.prefix(3).allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
                tint = NSColor(calibratedRed: parts[0], green: parts[1], blue: parts[2], alpha: 1)
            }
        }
        return resolve(theme: string("AppleIconAppearanceTheme"), systemDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, tint: tint)
    }
}

/// Small, code-native doodles retain crisp contours at sidebar sizes. Each has
/// independently rendered dark, translucent clear, and monochrome tinted art.
enum ModuleIcons {
    static func image(for page: SettingsPage, appearance a: ModuleIconAppearance) -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { _ in
            let hues: [SettingsPage: CGFloat] = [.general: 0.59, .permissions: 0.33, .window: 0.54, .visualEffects: 0.77,
                .iconAbsorber: 0.93, .shortcuts: 0.12, .scripts: 0.07, .logging: 0.46, .about: 0.65]
            let color = NSColor(calibratedHue: hues[page] ?? 0.6, saturation: 0.75, brightness: 0.95, alpha: 1)
            let tile = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 56, height: 56), xRadius: 16, yRadius: 16)
            let foreground: NSColor
            let top: NSColor, bottom: NSColor, border: NSColor
            switch a.style {
            case .standard:
                top = color.blended(withFraction: 0.18, of: .white) ?? color
                bottom = color.blended(withFraction: 0.2, of: .black) ?? color
                border = .white.withAlphaComponent(0.35); foreground = .white
            case .dark:
                top = NSColor(white: 0.19, alpha: 1); bottom = NSColor(white: 0.08, alpha: 1)
                border = color.withAlphaComponent(0.45); foreground = color.blended(withFraction: 0.3, of: .white) ?? color
            case .clear:
                top = NSColor(white: a.dark ? 0.22 : 1, alpha: a.dark ? 0.7 : 0.65)
                bottom = NSColor(white: a.dark ? 0.02 : 0.8, alpha: a.dark ? 0.45 : 0.06)
                border = NSColor(white: a.dark ? 1 : 0.45, alpha: 0.55)
                foreground = NSColor(white: a.dark ? 0.97 : 0.2, alpha: 1)
            case .tinted:
                top = a.tint.blended(withFraction: a.dark ? 0.5 : 0.7, of: a.dark ? .black : .white) ?? a.tint
                bottom = a.tint.blended(withFraction: a.dark ? 0.72 : 0.36, of: a.dark ? .black : .white) ?? a.tint
                border = a.tint.withAlphaComponent(0.65)
                foreground = a.tint.blended(withFraction: a.dark ? 0.7 : 0.62, of: a.dark ? .white : .black) ?? a.tint
            }
            NSGradient(starting: top, ending: bottom)?.draw(in: tile, angle: -90)
            border.setStroke(); tile.lineWidth = 1.2; tile.stroke()
            let shine = NSBezierPath(); shine.move(to: NSPoint(x: 14, y: 53)); shine.curve(to: NSPoint(x: 49, y: 53), controlPoint1: NSPoint(x: 22, y: 58), controlPoint2: NSPoint(x: 43, y: 58))
            NSColor.white.withAlphaComponent(a.style == .clear ? 0.7 : 0.28).setStroke(); shine.lineWidth = 1.3; shine.stroke()
            foreground.setStroke(); foreground.setFill()
            func line(_ points: [NSPoint], width: CGFloat = 3) {
                guard let first = points.first else { return }
                let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
                path.move(to: first); points.dropFirst().forEach { path.line(to: $0) }; path.stroke()
            }
            func oval(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, fill: Bool = false) {
                let p = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: width, height: height)); p.lineWidth = 3
                if fill { p.fill() } else { p.stroke() }
            }
            func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat = 4) {
                let p = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: radius, yRadius: radius); p.lineWidth = 3; p.stroke()
            }
            func eyes(_ x: CGFloat, _ y: CGFloat) {
                oval(x, y, 3.8, 5.5, fill: true); oval(x + 9, y + 1, 3.8, 5.5, fill: true)
            }
            func smile(_ x: CGFloat, _ y: CGFloat) {
                let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: y)); p.curve(to: NSPoint(x: x + 12, y: y + 1), controlPoint1: NSPoint(x: x + 3, y: y - 7), controlPoint2: NSPoint(x: x + 10, y: y - 5)); p.lineWidth = 2.2; p.lineCapStyle = .round; p.stroke()
            }
            switch page {
            case .general:
                oval(17, 17, 30, 30)
                for i in 0..<8 { let angle = CGFloat(i) * .pi / 4; line([NSPoint(x: 32 + cos(angle) * 17, y: 32 + sin(angle) * 17), NSPoint(x: 32 + cos(angle) * 21, y: 32 + sin(angle) * 21)], width: 5) }
                eyes(25, 32); smile(26, 27)
            case .permissions:
                box(18, 16, 29, 26)
                let shackle = NSBezierPath(); shackle.move(to: NSPoint(x: 24, y: 42)); shackle.line(to: NSPoint(x: 24, y: 47)); shackle.curve(to: NSPoint(x: 42, y: 47), controlPoint1: NSPoint(x: 24, y: 59), controlPoint2: NSPoint(x: 42, y: 59)); shackle.line(to: NSPoint(x: 42, y: 42)); shackle.lineWidth = 3; shackle.stroke()
                eyes(25, 28); smile(26, 23)
            case .window:
                box(17, 21, 30, 24); line([NSPoint(x: 18, y: 38), NSPoint(x: 46, y: 38)], width: 2)
                eyes(25, 28)
                line([NSPoint(x: 12, y: 42), NSPoint(x: 10, y: 51), NSPoint(x: 19, y: 49)])
                line([NSPoint(x: 44, y: 14), NSPoint(x: 54, y: 12), NSPoint(x: 52, y: 22)])
            case .visualEffects:
                line([NSPoint(x: 18, y: 17), NSPoint(x: 40, y: 39)], width: 5)
                line([NSPoint(x: 23, y: 23), NSPoint(x: 28, y: 28)], width: 6)
                for (x, y, r) in [(CGFloat(41), CGFloat(44), CGFloat(10)), (20, 43, 5), (46, 21, 5)] {
                    line([NSPoint(x: x - r, y: y), NSPoint(x: x, y: y + r), NSPoint(x: x + r, y: y), NSPoint(x: x, y: y - r), NSPoint(x: x - r, y: y)], width: 2)
                }
            case .iconAbsorber:
                oval(18, 17, 31, 31); eyes(27, 34)
                let mouth = NSBezierPath(); mouth.move(to: NSPoint(x: 25, y: 29)); mouth.curve(to: NSPoint(x: 43, y: 29), controlPoint1: NSPoint(x: 31, y: 14), controlPoint2: NSPoint(x: 38, y: 15)); mouth.lineWidth = 3; mouth.stroke()
                for (x, y, r) in [(CGFloat(12), CGFloat(34), CGFloat(3)), (16, 47, 4), (8, 21, 2)] { oval(x - r, y - r, r * 2, r * 2, fill: true) }
            case .shortcuts:
                box(13, 17, 38, 26)
                for y in [CGFloat(25), 33] { for x in stride(from: CGFloat(20), through: 44, by: 8) { oval(x - 1.5, y - 1.5, 3, 3, fill: true) } }
                line([NSPoint(x: 38, y: 52), NSPoint(x: 30, y: 42), NSPoint(x: 37, y: 42), NSPoint(x: 29, y: 32)], width: 2.6)
            case .scripts:
                box(18, 15, 28, 36, radius: 5); line([NSPoint(x: 23, y: 42), NSPoint(x: 29, y: 37), NSPoint(x: 23, y: 32)], width: 2.5)
                line([NSPoint(x: 33, y: 31), NSPoint(x: 40, y: 31)], width: 2.3)
                oval(32, 12, 20, 20); line([NSPoint(x: 42, y: 27), NSPoint(x: 42, y: 21), NSPoint(x: 47, y: 19)], width: 2)
            case .logging:
                box(16, 14, 32, 37); line([NSPoint(x: 23, y: 15), NSPoint(x: 23, y: 50)], width: 2)
                for y in [CGFloat(24), 32, 40] { line([NSPoint(x: 29, y: y), NSPoint(x: 41, y: y)], width: 2) }
                line([NSPoint(x: 43, y: 12), NSPoint(x: 52, y: 34)], width: 4)
            case .about:
                oval(14, 14, 36, 36); oval(30, 39, 5, 5, fill: true)
                line([NSPoint(x: 29, y: 32), NSPoint(x: 34, y: 32), NSPoint(x: 31, y: 23), NSPoint(x: 37, y: 23)], width: 3.2)
                line([NSPoint(x: 50, y: 47), NSPoint(x: 53, y: 52)], width: 2)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = page.title
        return image
    }
}
