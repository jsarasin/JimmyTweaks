import AppKit

struct GestureFeedback {
    let frame: CGRect
    let kind: GestureKind
    let active: Bool
    let preferences: GesturePreferences
}

private final class FeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class OutlineView: NSView {
    var drawCorner: WindowCorner?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath(); path.lineWidth = 2
        if let corner = drawCorner {
            let left = corner.isLeft, top = corner.isTop
            let x = left ? 2.0 : bounds.width - 2, y = top ? bounds.height - 2 : 2.0
            path.move(to: NSPoint(x: x + (left ? 16 : -16), y: y))
            path.line(to: NSPoint(x: x, y: y)); path.line(to: NSPoint(x: x, y: y + (top ? -16 : 16)))
        } else { path.appendRoundedRect(bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5) }
        path.stroke()
    }
}

final class FeedbackController {
    private var panels: [FeedbackPanel] = []
    private var cursorName: String?
    private lazy var diagonalA = diagonalCursor(flipped: false)
    private lazy var diagonalB = diagonalCursor(flipped: true)
    func show(_ feedback: GestureFeedback?) {
        precondition(Thread.isMainThread)
        guard let feedback = feedback else { clear(); return }
        if feedback.preferences.changeCursor {
            let name: String
            let cursor: NSCursor
            switch feedback.kind {
            case .move: name = feedback.active ? "closed" : "open"; cursor = feedback.active ? .closedHand : .openHand
            case .resize(let c):
                let a = c == .topLeft || c == .bottomRight
                name = a ? "diagonalA" : "diagonalB"; cursor = a ? diagonalA : diagonalB
            }
            if cursorName != name { cursor.set(); cursorName = name }
        } else { restoreCursor() }
        let corner: WindowCorner?
        if !feedback.active, feedback.preferences.cornerHints, case .resize(let c) = feedback.kind { corner = c }
        else { corner = nil }
        let showFrame = feedback.active && feedback.preferences.outline
        guard showFrame || corner != nil else { hidePanels(); return }
        // Quartz/AX use the main display's top-left. AppKit screens share a main-screen bottom-left origin.
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let appKitFrame = NSRect(x: feedback.frame.minX, y: mainHeight - feedback.frame.maxY,
                                 width: feedback.frame.width, height: feedback.frame.height)
        var drawings: [(NSScreen, NSRect)] = []
        for screen in NSScreen.screens {
            let intersection = appKitFrame.intersection(screen.frame)
            if !intersection.isNull && !intersection.isEmpty { drawings.append((screen, intersection)) }
        }
        while panels.count < drawings.count {
            let panel = FeedbackPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            let clip = NSView(); clip.wantsLayer = true; clip.layer?.masksToBounds = true
            let outline = OutlineView(); outline.identifier = NSUserInterfaceItemIdentifier("outline"); clip.addSubview(outline); panel.contentView = clip
            panels.append(panel)
        }
        for (index, drawing) in drawings.enumerated() {
            let panel = panels[index]
            panel.setFrame(drawing.1, display: false)
            if let view = panel.contentView?.subviews.first as? OutlineView {
                // Place full-frame drawing in a clipped per-screen content view; no artificial seam borders.
                view.frame = NSRect(x: appKitFrame.minX - drawing.1.minX, y: appKitFrame.minY - drawing.1.minY,
                                    width: appKitFrame.width, height: appKitFrame.height)
                view.drawCorner = corner; view.needsDisplay = true
            }
            panel.orderFrontRegardless()
        }
        for panel in panels.dropFirst(drawings.count) { panel.orderOut(nil) }
    }
    func clear() { hidePanels(); restoreCursor() }
    private func hidePanels() { panels.forEach { $0.orderOut(nil) } }
    private func restoreCursor() { if cursorName != nil { NSCursor.arrow.set(); cursorName = nil } }
    private func diagonalCursor(flipped: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let p = NSBezierPath(); p.lineCapStyle = .round; p.lineJoinStyle = .round
            let a = NSPoint(x: 5, y: flipped ? 5 : 19), b = NSPoint(x: 19, y: flipped ? 19 : 5)
            p.move(to: a); p.line(to: b)
            p.move(to: NSPoint(x: 5, y: flipped ? 11 : 13)); p.line(to: a); p.line(to: NSPoint(x: 11, y: a.y))
            p.move(to: NSPoint(x: 13, y: b.y)); p.line(to: b); p.line(to: NSPoint(x: 19, y: flipped ? 13 : 11))
            NSColor.white.setStroke(); p.lineWidth = 4; p.stroke()
            NSColor.black.setStroke(); p.lineWidth = 2; p.stroke(); return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }
}
