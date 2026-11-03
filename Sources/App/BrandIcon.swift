import AppKit

/// The application artwork is a carved, living-wood J. This simplified outline
/// keeps the same curled silhouette legible at menu bar size.
enum BrandIcon {
    static var letter: CGPath {
        let path = CGMutablePath()

        let crown = CGMutablePath()
        crown.move(to: CGPoint(x: 297, y: 753))
        crown.addCurve(to: CGPoint(x: 762, y: 753),
                       control1: CGPoint(x: 435, y: 793), control2: CGPoint(x: 642, y: 788))
        path.addPath(crown.copy(strokingWithWidth: 96, lineCap: .round, lineJoin: .round,
                               miterLimit: 2))

        let trunk = CGMutablePath()
        trunk.move(to: CGPoint(x: 627, y: 748))
        trunk.addLine(to: CGPoint(x: 627, y: 294))
        trunk.addCurve(to: CGPoint(x: 392, y: 154),
                       control1: CGPoint(x: 627, y: 160), control2: CGPoint(x: 506, y: 109))
        trunk.addCurve(to: CGPoint(x: 284, y: 362),
                       control1: CGPoint(x: 265, y: 199), control2: CGPoint(x: 233, y: 306))
        trunk.addCurve(to: CGPoint(x: 372, y: 329),
                       control1: CGPoint(x: 316, y: 407), control2: CGPoint(x: 384, y: 391))
        path.addPath(trunk.copy(strokingWithWidth: 105, lineCap: .round, lineJoin: .round,
                               miterLimit: 2))
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

    private static let bundledArtwork = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    static func applicationImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            if let bundledArtwork {
                bundledArtwork.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                // Keep the settings guide usable when run outside the app bundle.
                let tile = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.04, dy: size * 0.04),
                                        xRadius: size * 0.22, yRadius: size * 0.22)
                NSColor(calibratedRed: 0.02, green: 0.28, blue: 0.13, alpha: 1).setFill()
                tile.fill()
                drawLetter(in: rect.insetBy(dx: size * 0.22, dy: size * 0.17),
                           color: NSColor(calibratedRed: 0.68, green: 0.42, blue: 0.18, alpha: 1))
            }
            return true
        }
    }

    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            drawLetter(in: NSRect(x: 3, y: 1, width: 14, height: 18), color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Jimmy Tweaks — Celtic J"
        return image
    }
}
