import AppKit
import QuartzCore

struct FeedbackWindow: Equatable {
    let number: Int
    let level: Int
    /// Public Window Server metadata only: no title, screenshot, or private AX API.
    static func match(pid: pid_t, frame: CGRect) -> FeedbackWindow? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let matches = windows.compactMap { info -> FeedbackWindow? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: NSNumber],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  WindowGeometry.approximatelyEqual(CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue), frame, tolerance: 2),
                  let number = info[kCGWindowNumber as String] as? Int,
                  let level = info[kCGWindowLayer as String] as? Int else { return nil }
            return FeedbackWindow(number: number, level: level)
        }
        // Identical stacked windows are ambiguous; never guess which one to follow.
        return matches.count == 1 ? matches[0] : nil
    }
}

struct GestureFeedback {
    let frame: CGRect
    let kind: GestureKind
    let active: Bool
    var preferences: GesturePreferences
    var window: FeedbackWindow? = nil
    var sampleTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var idle = false
    var dismissing = false
    var passive = false
}

private final class FeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The fallback has no animation, display link, or simulation work.
private final class StaticFeedbackView: NSView {
    var target = CGRect.zero
    var corner: WindowCorner?
    var showFrame = false
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        if showFrame {
            accent.withAlphaComponent(0.85).setStroke()
            let path = NSBezierPath(roundedRect: target.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            path.lineWidth = 2; path.stroke()
        }
        guard let corner else { return }
        let x = corner.isLeft ? target.minX : target.maxX
        let y = corner.isTop ? target.maxY : target.minY
        let path = NSBezierPath(); path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: NSPoint(x: x + (corner.isLeft ? 32 : -32), y: y))
        path.line(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x, y: y + (corner.isTop ? -32 : 32)))
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow(); glow.shadowColor = accent; glow.shadowBlurRadius = 8; glow.shadowOffset = .zero; glow.set()
        accent.setStroke(); path.lineWidth = 3; path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        (accent.blended(withFraction: 0.65, of: .white) ?? accent).setStroke(); path.lineWidth = 1.2; path.stroke()
    }
}

private final class DisplayFeedback {
    let panel: FeedbackPanel
    let still = StaticFeedbackView()
    var surface: EffectSurface?
    init(screen: NSScreen) {
        panel = FeedbackPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityHidden(true)
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true; root.layer?.masksToBounds = true
        root.setAccessibilityHidden(true)
        root.addSubview(still); panel.contentView = root
    }
    func hide() {
        surface?.isHidden = true; panel.orderOut(nil)
        // Release drawable backing stores on unused displays. The stationary panel is reused.
        surface?.removeFromSuperview(); surface = nil
    }
}

private struct DissolvingFeedback {
    static let smokeFadeDuration: TimeInterval = 1.0
    static let colourTransitionDuration = smokeFadeDuration / 3
    var duration: TimeInterval {
        switch effect {
        case .cartoonWind: return 2.6
        case .crystalFrost: return 2.1
        default: return Self.colourTransitionDuration + Self.smokeFadeDuration
        }
    }
    let renderer: ProceduralEffects
    let rect: CGRect
    let windowRect: CGRect
    let source: CGPoint
    let arms: SIMD2<Float>
    let mist: Bool
    let effect: WindowEffect
    let motion: EffectMotion
    let started: TimeInterval
    let displays: Set<CGDirectDisplayID>
}

final class FeedbackController {
    private var displays: [CGDirectDisplayID: DisplayFeedback] = [:]
    private var visitedDisplays = Set<CGDirectDisplayID>()
    private var cursorName: String?
    private lazy var diagonalA = diagonalCursor(flipped: false)
    private lazy var diagonalB = diagonalCursor(flipped: true)
    private var renderer: ProceduralEffects?
    private var rendererRequested = false
    private var rendererFailed = false
    private var clock: Timer?
    private var latest: GestureFeedback?
    private var motion = EffectMotion()
    private var previousTick = ProcessInfo.processInfo.systemUptime
    private var effectRect = CGRect.zero
    private var windowRect = CGRect.zero
    private var source = CGPoint.zero
    private var previousActivationSource: CGPoint?
    private var arms = SIMD2<Float>.zero
    private var mist = false
    private var effect: WindowEffect = .iridescentEnergy
    private var animating = false
    private var liveEffectVisible = false
    private var dissolving: [DissolvingFeedback] = []
    private var lastCompositedLayers = 0
    private var previousSmokeCursor: CGPoint?
    #if TESTING
    private var smokeCursorStrokes = 0
    #endif
    private let reducedMotion: () -> Bool
    private let cursorPosition: () -> CGPoint
    private var observers: [NSObjectProtocol] = []

    init(reducedMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         cursorPosition: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.reducedMotion = reducedMotion
        self.cursorPosition = cursorPosition
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        for name in [NSApplication.didChangeScreenParametersNotification, NSColor.systemColorsDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }
    deinit {
        clock?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for display in displays.values { display.panel.orderOut(nil) }
    }

    func show(_ feedback: GestureFeedback?) {
        precondition(Thread.isMainThread)
        if let feedback, feedback.dismissing {
            if !feedback.preferences.animatedEffects || !feedback.preferences.effectsEnabled(for: feedback.kind) ||
                (feedback.passive && !feedback.preferences.normalWindowEffectsActive) {
                clear()
            } else { dismiss() }
            return
        }
        // A late final AX callback may send another nil after Command release.
        // It must not erase a smoke transition that is already in progress.
        if feedback == nil, latest == nil, !dissolving.isEmpty { return }
        guard let feedback, WindowGeometry.valid(feedback.frame) else { clear(); return }
        if feedback.passive && (!feedback.preferences.normalWindowEffectsActive || reducedMotion()) { clear(); return }
        let changed = latest?.window != feedback.window || latest?.kind != feedback.kind || latest == nil ||
            latest?.preferences.effect(for: feedback.kind) != feedback.preferences.effect(for: feedback.kind)
        if changed {
            retireCurrentEffect()
            motion = EffectMotion(); renderer?.restart(); visitedDisplays.removeAll(); previousActivationSource = nil
        }
        latest = feedback
        effect = feedback.preferences.effect(for: feedback.kind)
        if feedback.preferences.changeCursor && !feedback.idle && !feedback.passive {
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
        // Window geometry is Quartz top-left; the overlay desktop uses AppKit bottom-left.
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let frame = NSRect(x: feedback.frame.minX, y: mainHeight - feedback.frame.maxY, width: feedback.frame.width, height: feedback.frame.height)
        windowRect = frame
        let corner: WindowCorner?
        // Hover can change the cursor, but only an admitted resize may start visuals.
        // Idle feedback is produced only after a real gesture has already begun.
        if (feedback.preferences.cornerHints || feedback.passive), feedback.active || feedback.idle,
           case .resize(let c) = feedback.kind { corner = c } else { corner = nil }
        mist = (feedback.active || feedback.idle) && feedback.kind == .move && feedback.preferences.effectsEnabled(for: .move)
        if let corner {
            source = CGPoint(x: corner.isLeft ? frame.minX : frame.maxX, y: corner.isTop ? frame.maxY : frame.minY)
            arms = SIMD2(corner.isLeft ? 1 : -1, corner.isTop ? -1 : 1)
            // The heat field stays fixed across the whole desktop. Moving the source must
            // never move a simulation boundary through its existing flame trail.
            effectRect = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        } else {
            source = CGPoint(x: frame.midX, y: frame.midY); arms = .zero
            effectRect = mist && effect == .cartoonWind ? NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) } : frame
        }
        motion.sample(source, at: feedback.sampleTime)
        let effectsEnabled = feedback.preferences.effectsEnabled(for: feedback.kind)
        let wantsAnimation = effectsEnabled && feedback.preferences.animatedEffects && !reducedMotion() && (corner != nil || mist)
        if !effectsEnabled || !feedback.preferences.animatedEffects || reducedMotion() { dissolving.removeAll() }
        if wantsAnimation { prepareRenderer() }
        let canAnimate = wantsAnimation && renderer != nil && !rendererFailed
        let showFrame = !feedback.passive && (feedback.active || feedback.idle) && (feedback.preferences.outline || (mist && !canAnimate))
        guard corner != nil || mist || showFrame || !dissolving.isEmpty else { liveEffectVisible = false; hideDisplays(); return }
        liveEffectVisible = canAnimate
        animating = canAnimate || !dissolving.isEmpty
        // Panels encompass whole displays and move only when the display layout changes.
        // This rectangle only decides when to first activate a display. It never clips
        // rendering or heat; visited displays stay active until the gesture ends.
        var activationRect = frame
        if mist && effect == .cartoonWind { activationRect = frame.insetBy(dx: -900, dy: -600) }
        if corner != nil {
            if effect == .furiousLightning { activationRect = frame.insetBy(dx: -560, dy: -560) }
            let reach: CGFloat = effect == .furiousLightning ? 620 : effect == .crystalFrost ? 420 : 288
            activationRect = activationRect.union(CGRect(x: source.x - reach, y: source.y - reach, width: reach * 2, height: reach * 2))
            if let previous = previousActivationSource {
                activationRect = activationRect.union(CGRect(x: previous.x - reach, y: previous.y - reach, width: reach * 2, height: reach * 2))
            }
        }
        previousActivationSource = source
        let visualRect = activationRect.union(showFrame ? frame.insetBy(dx: -2, dy: -2) : .null)
        var used = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            let intersection = visualRect.intersection(screen.frame)
            let intersects = !intersection.isNull && !intersection.isEmpty
            let smokeHere = dissolving.contains { $0.displays.contains(id) }
            guard intersects || (canAnimate && (!mist || effect == .cartoonWind) && visitedDisplays.contains(id)) || smokeHere else { continue }
            let fragment = intersects ? intersection : screen.frame
            used.insert(id)
            if canAnimate && (!mist || effect == .cartoonWind) { visitedDisplays.insert(id) }
            let display = displays[id] ?? DisplayFeedback(screen: screen); displays[id] = display
            if display.panel.frame != screen.frame { display.panel.setFrame(screen.frame, display: false) }
            let local = fragment.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            display.still.frame = local
            display.still.target = frame.offsetBy(dx: -fragment.minX, dy: -fragment.minY)
            display.still.corner = canAnimate ? nil : corner; display.still.showFrame = showFrame
            display.still.isHidden = !intersects || (!showFrame && (canAnimate || corner == nil))
            display.still.needsDisplay = true
            if canAnimate || smokeHere, let renderer {
                if display.surface == nil {
                    let surface = EffectSurface(renderer: renderer)
                    display.panel.contentView?.addSubview(surface, positioned: .below, relativeTo: display.still)
                    display.surface = surface
                }
                // Both the MTKView and its native-resolution drawable fill the stationary
                // display window. Shader transparency, rather than a moving view, bounds the effect.
                if let surface = display.surface {
                    let bounds = NSRect(origin: .zero, size: screen.frame.size)
                    if surface.frame != bounds { surface.frame = bounds }
                    surface.worldRect = screen.frame; surface.isHidden = false
                    let size = CGSize(width: ceil(screen.frame.width * screen.backingScaleFactor), height: ceil(screen.frame.height * screen.backingScaleFactor))
                    if surface.drawableSize != size { surface.drawableSize = size }
                }
            } else {
                display.surface?.removeFromSuperview(); display.surface = nil
            }
            if let window = feedback.window {
                display.panel.level = NSWindow.Level(rawValue: window.level)
                display.panel.order(.above, relativeTo: window.number)
            } else {
                // Some apps expose ambiguous metadata. Preserve the previous floating-overlay fallback.
                display.panel.level = .floating; display.panel.orderFrontRegardless()
            }
        }
        for (id, display) in displays where !used.contains(id) { display.hide() }
        let connected = Set(NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value })
        for id in Array(displays.keys) where !connected.contains(id) { displays.removeValue(forKey: id)?.hide() }
        if animating && !used.isEmpty { startClock() } else { stopClock() }
    }

    private func retireCurrentEffect() {
        guard liveEffectVisible, let renderer, renderer.frameCount > 0,
              latest?.preferences.animatedEffects == true, !reducedMotion() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        dissolving.removeAll { now - $0.started >= $0.duration }
        if dissolving.isEmpty { previousSmokeCursor = cursorPosition() }
        // Observation is polled separately; fading panels never receive or consume input.
        for display in displays.values {
            display.panel.ignoresMouseEvents = true
            display.panel.acceptsMouseMovedEvents = false
        }
        dissolving.append(DissolvingFeedback(renderer: renderer, rect: effectRect, windowRect: windowRect, source: source, arms: arms, mist: mist, effect: effect,
            motion: motion, started: now, displays: Set(displays.compactMap { $0.value.panel.isVisible ? $0.key : nil })))
        // Bound memory and GPU work even if inputs alternate faster than display refresh.
        if dissolving.count > 4 { dissolving.removeFirst(dissolving.count - 4) }
        self.renderer = renderer.makeSibling()
        liveEffectVisible = false
    }

    private func dismiss() {
        retireCurrentEffect()
        latest = nil; liveEffectVisible = false; restoreCursor()
        guard !dissolving.isEmpty else { clear(); return }
        animating = true
        startClock()
    }

    private func prepareRenderer() {
        guard !rendererRequested else { return }; rendererRequested = true
        // Metal shader compilation never blocks the mouse event tap or the first gesture frame.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let renderer = ProceduralEffects()
            DispatchQueue.main.async { [weak self] in self?.renderer = renderer; self?.refresh() }
        }
    }
    private func refresh() {
        if reducedMotion() { dissolving.removeAll(); if latest == nil { clear(); return } }
        if let latest { show(latest) }
    }
    private func startClock() {
        guard clock == nil else { return }
        renderer?.restart(); previousTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.002; clock = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }
    private func tick() {
        guard animating else { return }
        let now = ProcessInfo.processInfo.systemUptime
        motion.settle(at: now, dt: Float(min(1 / 30.0, max(0, now - previousTick)))); previousTick = now
        dissolving.removeAll { now - $0.started >= $0.duration }
        var layers: [ProceduralEffects] = []
        var cursorStroke: SmokeCursorStroke?
        if !dissolving.isEmpty {
            let current = cursorPosition()
            if let previous = previousSmokeCursor, hypot(current.x - previous.x, current.y - previous.y) > 0.01 {
                cursorStroke = SmokeCursorStroke(start: previous, end: current)
                #if TESTING
                smokeCursorStrokes += 1
                #endif
            }
            previousSmokeCursor = current
        } else { previousSmokeCursor = nil }
        for smoke in dissolving {
            let progress = Float((now - smoke.started) / smoke.duration)
            if smoke.renderer.configure(rect: smoke.rect, source: smoke.source, arms: smoke.arms, mist: smoke.mist, motion: smoke.motion, smoke: progress, cursor: cursorStroke, effect: smoke.effect, windowRect: smoke.windowRect) {
                layers.append(smoke.renderer)
            }
        }
        if liveEffectVisible, let renderer {
            guard renderer.configure(rect: effectRect, source: source, arms: arms, mist: mist, motion: motion, effect: effect, windowRect: windowRect) else {
                rendererFailed = true; dissolving.removeAll(); stopClock(); refresh(); return
            }
            layers.append(renderer)
        }
        guard let compositor = layers.last else { lastCompositedLayers = 0; hideDisplays(); return }
        for underlay in layers.dropLast() { _ = underlay.render(surfaces: [], at: now) }
        let surfaces = displays.values.compactMap { $0.surface }.filter { !$0.isHidden }
        for surface in surfaces { surface.renderer = compositor }
        lastCompositedLayers = layers.count
        guard compositor.render(surfaces: surfaces, at: now, underlays: Array(layers.dropLast())) else {
            rendererFailed = true; dissolving.removeAll(); stopClock(); refresh(); return
        }
    }
    private func stopClock() { clock?.invalidate(); clock = nil; animating = false }
    private func hideDisplays() { stopClock(); displays.values.forEach { $0.hide() } }
    func clear() { latest = nil; liveEffectVisible = false; dissolving.removeAll(); previousSmokeCursor = nil; lastCompositedLayers = 0; hideDisplays(); renderer?.restart(); motion = EffectMotion(); visitedDisplays.removeAll(); previousActivationSource = nil; restoreCursor() }
    private func restoreCursor() { if cursorName != nil { NSCursor.arrow.set(); cursorName = nil } }

    #if TESTING
    var effectFramesForTesting: Int { renderer?.frameCount ?? 0 }
    var timerRunningForTesting: Bool { clock != nil }
    var panelsForTesting: [NSWindow] { displays.values.map { $0.panel } }
    var rendererReadyForTesting: Bool { rendererRequested && renderer != nil }
    var presentedFramesForTesting: Int { renderer?.presentedFrames ?? 0 }
    var averageGPUTimeForTesting: Double { guard let renderer, renderer.completedFrames > 0 else { return 0 }; return renderer.gpuSeconds / Double(renderer.completedFrames) }
    var simulationBoundsForTesting: CGRect { effectRect }
    var smokeCountForTesting: Int { dissolving.count }
    var compositedLayersForTesting: Int { lastCompositedLayers }
    var smokeCursorStrokesForTesting: Int { smokeCursorStrokes }
    #endif

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
