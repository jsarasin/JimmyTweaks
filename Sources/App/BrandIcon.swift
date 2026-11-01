import AppKit

/// The same hand-drawn blackletter J is used in the application and menu bar.
/// Keeping the outline independent of fonts also makes builds reproducible.
enum BrandIcon {
    static var letter: CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 112, y: 658))
        path.addLine(to: CGPoint(x: 190, y: 730))
        path.addLine(to: CGPoint(x: 355, y: 691))
        path.addLine(to: CGPoint(x: 510, y: 738))
        path.addLine(to: CGPoint(x: 468, y: 642))
        path.addLine(to: CGPoint(x: 418, y: 618))
        path.addLine(to: CGPoint(x: 418, y: 265))
        path.addCurve(to: CGPoint(x: 231, y: 53), control1: CGPoint(x: 418, y: 154), control2: CGPoint(x: 336, y: 84))
        path.addCurve(to: CGPoint(x: 67, y: 179), control1: CGPoint(x: 147, y: 68), control2: CGPoint(x: 84, y: 113))
        path.addLine(to: CGPoint(x: 59, y: 222))
        path.addLine(to: CGPoint(x: 137, y: 295))
        path.addLine(to: CGPoint(x: 215, y: 220))
        path.addLine(to: CGPoint(x: 158, y: 163))
        path.addCurve(to: CGPoint(x: 237, y: 129), control1: CGPoint(x: 177, y: 140), control2: CGPoint(x: 207, y: 130))
        path.addCurve(to: CGPoint(x: 299, y: 255), control1: CGPoint(x: 281, y: 146), control2: CGPoint(x: 299, y: 193))
        path.addLine(to: CGPoint(x: 299, y: 605))
        path.addLine(to: CGPoint(x: 188, y: 633))
        path.addLine(to: CGPoint(x: 112, y: 607))
        path.addLine(to: CGPoint(x: 144, y: 655))
        path.closeSubpath()
        return path
    }

    static func drawLetter(in rect: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let path = letter
        let bounds = path.boundingBoxOfPath
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        context.saveGState()
        context.translateBy(x: rect.midX - bounds.width * scale / 2,
                            y: rect.midY - bounds.height * scale / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    static func applicationImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.scaleBy(x: size / 1024, y: size / 1024)
            let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                                    xRadius: 184, yRadius: 184)
            context.saveGState()
            // Quartz shadows use device space, unlike the scaled outline.
            context.setShadow(offset: CGSize(width: 0, height: -12 * size / 1024), blur: 20 * size / 1024,
                              color: NSColor.black.withAlphaComponent(0.22).cgColor)
            NSColor(calibratedWhite: 0.15, alpha: 1).setFill()
            tile.fill()
            context.restoreGState()
            NSGradient(starting: NSColor(calibratedWhite: 0.23, alpha: 1),
                       ending: NSColor(calibratedWhite: 0.115, alpha: 1))!.draw(in: tile, angle: -90)
            NSColor.white.withAlphaComponent(0.12).setStroke()
            tile.lineWidth = 2
            tile.stroke()
            drawLetter(in: NSRect(x: 300, y: 242, width: 424, height: 552),
                       color: NSColor(calibratedRed: 0.95, green: 0.93, blue: 0.88, alpha: 1))
            context.restoreGState()
            return true
        }
    }

    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            drawLetter(in: NSRect(x: 3, y: 1, width: 14, height: 18), color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Jimmy Tweaks — gothic J"
        return image
    }
}
