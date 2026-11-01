import AppKit
import QuartzCore

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
    private var drawCorner: WindowCorner?
    private var feedbackVisible = false
    private let neon = CAShapeLayer()
    private let core = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for stroke in [neon, core] {
            stroke.fillColor = nil
            stroke.lineCap = .round; stroke.lineJoin = .round
            layer?.addSublayer(stroke)
        }
        neon.lineWidth = 3
        neon.shadowOffset = .zero; neon.shadowOpacity = 1; neon.shadowRadius = 8
        core.lineWidth = 1.2
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStyle), name: NSColor.systemColorsDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshStyle), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refreshStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(corner: WindowCorner?, visible: Bool) {
        drawCorner = corner; feedbackVisible = visible
        CATransaction.begin(); CATransaction.setDisableActions(true)
        neon.isHidden = corner == nil; core.isHidden = corner == nil
        if let corner = corner {
            // Keep the halo inside the window and retain the real corner on each display.
            let x = corner.isLeft ? 10.0 : bounds.width - 10
            let y = corner.isTop ? bounds.height - 10 : 10.0
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x + (corner.isLeft ? 32 : -32), y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + (corner.isTop ? -32 : 32)))
            neon.path = path; core.path = path
        }
        CATransaction.commit()
        refreshStyle(); needsDisplay = true
    }

    func stopAnimation() {
        feedbackVisible = false
        neon.removeAnimation(forKey: "neonPulse")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyle(); needsDisplay = true
    }

    @objc private func refreshStyle() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            neon.strokeColor = accent.cgColor; neon.shadowColor = accent.cgColor
            core.strokeColor = (accent.blended(withFraction: 0.65, of: .white) ?? accent).cgColor
        }
        CATransaction.commit()
        guard feedbackVisible, drawCorner != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            neon.removeAnimation(forKey: "neonPulse")
            return
        }
        guard neon.animation(forKey: "neonPulse") == nil else { return }
        let brightness = CABasicAnimation(keyPath: "opacity")
        brightness.fromValue = 0.55; brightness.toValue = 1.0; brightness.duration = 1.1
        let bloom = CABasicAnimation(keyPath: "shadowRadius")
        bloom.fromValue = 5.0; bloom.toValue = 10.0; bloom.duration = 1.1
        let pulse = CAAnimationGroup()
        pulse.animations = [brightness, bloom]; pulse.duration = 1.1
        pulse.autoreverses = true; pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // All display fragments share a phase, even if a window crosses a screen edge.
        pulse.beginTime = 1
        neon.add(pulse, forKey: "neonPulse")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard drawCorner == nil else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath(); path.lineWidth = 2
        path.appendRoundedRect(bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
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
                view.configure(corner: corner, visible: true)
            }
            panel.orderFrontRegardless()
        }
        for panel in panels.dropFirst(drawings.count) { hide(panel) }
    }
    func clear() { hidePanels(); restoreCursor() }
    private func hidePanels() { panels.forEach(hide) }
    private func hide(_ panel: FeedbackPanel) {
        (panel.contentView?.subviews.first as? OutlineView)?.stopAnimation()
        panel.orderOut(nil)
    }
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
