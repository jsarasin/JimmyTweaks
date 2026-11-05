import AppKit
import QuartzCore

enum CursorSnowCapture {
    static func current() -> CursorSnowShape? {
        guard let cursor = NSCursor.currentSystem,
              let image = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let alpha = (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).map { x in
                UInt8((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255)
            }
        }
        return CursorSnowShape(size: cursor.image.size, hotSpot: cursor.hotSpot,
                               pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh, alpha: alpha)
    }
}

/// Reads geometry and stacking metadata. Only title presence is checked; no
/// title text or window pictures are retained.
enum SnowStormWindowQuery {
    static func canDecorate(level: Int, hasTitle: Bool,
                            ownerPolicy: NSApplication.ActivationPolicy?) -> Bool {
        level == 0 && (hasTitle || ownerPolicy == .regular)
    }
    static func read(excluding: Set<Int>, desktopTop: Double) -> [SnowStormWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let highestLevel = Int(CGWindowLevelForKey(.floatingWindow))
        return list.compactMap { entry -> SnowStormWindow? in
            guard let number = entry[kCGWindowNumber as String] as? Int, !excluding.contains(number),
                  let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let level = entry[kCGWindowLayer as String] as? Int, level >= 0, level <= highestLevel,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let values = entry[kCGWindowBounds as String] as? [String: NSNumber],
                  let x = values["X"]?.doubleValue, let y = values["Y"]?.doubleValue,
                  let width = values["Width"]?.doubleValue, let height = values["Height"]?.doubleValue,
                  width >= 70, height >= 45, width <= 32_768, height <= 32_768 else { return nil }
            // The Window Server omits some other apps' titles. Their normal
            // windows are recognized by the festive validator when needed.
            let title = (entry[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SnowStormWindow(id: UInt32(number), owner: owner,
                frame: CGRect(x: x, y: desktopTop - y - height, width: width, height: height), level: level,
                decoratable: canDecorate(level: level, hasTitle: !title.isEmpty, ownerPolicy: nil))
        }.prefix(SnowStormSimulation.maximumWindows).map { $0 }
    }
}

enum ChristmasWindowMatching {
    static func contains(_ window: SnowStormWindow, in frames: [CGRect]) -> Bool {
        frames.contains { frame in
            abs(frame.minX - window.frame.minX) <= 12 && abs(frame.minY - window.frame.minY) <= 12 &&
            abs(frame.width - window.frame.width) <= 12 && abs(frame.height - window.frame.height) <= 12
        }
    }
}

/// AX lists actual application windows without inspecting their titles or pixels.
/// Cache by Window Server ID so a drag needs only one successful read.
final class ChristmasWindowValidator {
    private struct Result { let owner: Int32; let valid: Bool; let checkedAt: TimeInterval }
    private var results: [UInt32: Result] = [:]
    private let regularOwners: () -> Set<Int32>
    private let accessibilityTrusted: () -> Bool

    init(regularOwners: @escaping () -> Set<Int32> = {
        Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
    }, accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.regularOwners = regularOwners
        self.accessibilityTrusted = accessibilityTrusted
    }

    func validate(_ windows: [SnowStormWindow], desktopTop: Double) -> [SnowStormWindow] {
        guard windows.contains(where: { !$0.decoratable && $0.level == 0 &&
            $0.frame.width >= 210 && $0.frame.height >= 90 }) else { return windows }
        let regularOwners = regularOwners()
        let accessibilityTrusted = accessibilityTrusted()
        let now = ProcessInfo.processInfo.systemUptime
        let ids = Set(windows.map(\.id))
        results = results.filter { ids.contains($0.key) }
        var framesByOwner: [Int32: [CGRect]] = [:]
        return windows.map { window in
            guard !window.decoratable, window.level == 0,
                  window.frame.width >= 210, window.frame.height >= 90 else { return window }
            if regularOwners.contains(window.owner) {
                var verified = window; verified.decoratable = true; return verified
            }
            guard accessibilityTrusted else { return window }
            if let cached = results[window.id], cached.owner == window.owner,
               cached.valid || now - cached.checkedAt < 1 {
                var verified = window; verified.decoratable = cached.valid; return verified
            }
            if framesByOwner[window.owner] == nil {
                framesByOwner[window.owner] = Self.applicationFrames(pid: window.owner, desktopTop: desktopTop)
            }
            let valid = ChristmasWindowMatching.contains(window, in: framesByOwner[window.owner] ?? [])
            results[window.id] = Result(owner: window.owner, valid: valid, checkedAt: now)
            var verified = window; verified.decoratable = valid; return verified
        }
    }

    private static func applicationFrames(pid: Int32, desktopTop: Double) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let elements = raw as? [AnyObject] else { return [] }
        return elements.compactMap { object -> CGRect? in
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            let element = object as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.05)
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element,
                [kAXPositionAttribute, kAXSizeAttribute] as CFArray, [], &values) == .success,
                let pair = values as? [AnyObject], pair.count == 2,
                CFGetTypeID(pair[0]) == AXValueGetTypeID(), CFGetTypeID(pair[1]) == AXValueGetTypeID() else { return nil }
            var position = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(pair[0] as! AXValue, .cgPoint, &position),
                  AXValueGetValue(pair[1] as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(x: position.x, y: desktopTop - position.y - size.height,
                          width: size.width, height: size.height)
        }
    }
}

private final class StormPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // These click-through overlays use desktop coordinates. AppKit's normal
        // menu-bar constraint would shift the entire strip down when its
        // transparent headroom extends above the display, detaching the artwork.
        frameRect
    }
}

/// Drawing is shared by the live overlays and the standalone preview fixture.
enum SnowStormDrawing {
    static func clipWindows(_ windows: [SnowStormWindow], in context: CGContext, origin: CGPoint) {
        let bounds = context.boundingBoxOfClipPath
        let worldRect = bounds.offsetBy(dx: origin.x, dy: origin.y)
        for window in windows where window.frame.intersects(worldRect) {
            context.beginPath()
            context.addRect(bounds)
            context.addRect(window.frame.offsetBy(dx: -origin.x, dy: -origin.y))
            context.clip(using: .evenOdd)
        }
    }
    static func drift(_ drift: StormDrift, in context: CGContext, origin: CGPoint,
                      occludingWindows: [SnowStormWindow] = []) {
        guard drift.mass > 0.01 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // A roof bank belongs above its own window, including its rounded
        // corners. Only windows in front of that host can cover its snow.
        // Mask snow separately so lights and decorations keep their placement.
        if let host = drift.window, let index = occludingWindows.firstIndex(where: { $0.id == host.id }) {
            clipWindows(Array(occludingWindows.prefix(index)), in: context, origin: origin)
        } else {
            clipWindows(occludingWindows, in: context, origin: origin)
        }
        if let shape = drift.cursorShape {
            cursorDrift(drift, shape: shape, in: context, origin: origin)
            return
        }
        let baseline = drift.frame.maxY - origin.y
        let left = drift.frame.minX - origin.x, width = drift.cellWidth
        let heights = drift.heights
        let tipInset = min(StormDrift.cornerBlank, drift.frame.width * 0.25)
        let leftTipX = drift.frame.minX + tipInset
        let rightTipX = drift.frame.maxX - tipInset
        guard let leftTipY = drift.supportY(at: leftTipX),
              let rightTipY = drift.supportY(at: rightTipX) else { return }
        let path = CGMutablePath()
        let leftTip = CGPoint(x: leftTipX - origin.x, y: leftTipY - origin.y)
        let rightTip = CGPoint(x: rightTipX - origin.x, y: rightTipY - origin.y)
        path.move(to: leftTip)
        // Midpoint quadratic interpolation merges deposits into a soft bank;
        // the first and last points are thin tips inside the rounded corners.
        var previous = leftTip
        for i in heights.indices {
            let x = drift.frame.minX + (Double(i) + 0.5) * width
            guard x > leftTipX, x < rightTipX, let base = drift.supportY(at: x) else { continue }
            let support = base - origin.y
            let point = CGPoint(x: x - origin.x, y: support + heights[i])
            let midpoint = CGPoint(x: (point.x + previous.x) * 0.5, y: (point.y + previous.y) * 0.5)
            path.addQuadCurve(to: midpoint, control: previous)
            previous = point
        }
        path.addQuadCurve(to: rightTip, control: previous)
        let inset = min(StormDrift.cornerInset, drift.frame.width * 0.5)
        for step in 1...6 {
            let x = rightTipX - (inset - tipInset) * Double(step) / 6
            path.addLine(to: CGPoint(x: x - origin.x, y: (drift.supportY(at: x) ?? drift.frame.maxY) - origin.y))
        }
        path.addLine(to: CGPoint(x: left + inset, y: baseline))
        for step in 1...6 {
            let x = drift.frame.minX + inset - (inset - tipInset) * Double(step) / 6
            path.addLine(to: CGPoint(x: x - origin.x, y: (drift.supportY(at: x) ?? drift.frame.maxY) - origin.y))
        }
        path.closeSubpath()
        paintBank(path, baseline: baseline, crest: max(4, heights.max() ?? 4), left: left, in: context)
    }
    private static func cursorDrift(_ drift: StormDrift, shape: CursorSnowShape,
                                    in context: CGContext, origin: CGPoint) {
        let width = drift.cellWidth, count = drift.masses.count
        let bases: [Double?] = (0..<count).map { i in
            shape.topY(at: drift.frame.minX + (Double(i) + 0.5) * width, in: drift.frame)
        }
        let raw = drift.heights
        // A short visual spread turns pixel-wide deposits into a soft cap;
        // the actual support and collision height still use the cursor pixels.
        let heights = (0..<count).map { i -> Double in
            guard bases[i] != nil else { return 0 }
            return (max(0, i - 3)...min(count - 1, i + 3)).reduce(0.0) { best, j in
                guard bases[j] != nil else { return best }
                return max(best, raw[j] * (1 - Double(abs(i - j)) / 4))
            }
        }
        var start = 0
        while start < count {
            guard bases[start] != nil else { start += 1; continue }
            var end = start
            while end + 1 < count && bases[end + 1] != nil { end += 1 }
            if heights[start...end].contains(where: { $0 > 0.01 }) {
                let left = drift.frame.minX + Double(start) * width - origin.x
                let right = drift.frame.minX + Double(end + 1) * width - origin.x
                let firstBase = bases[start]! - origin.y, lastBase = bases[end]! - origin.y
                let path = CGMutablePath()
                path.move(to: CGPoint(x: left, y: firstBase))
                for i in start...end {
                    path.addLine(to: CGPoint(x: drift.frame.minX + (Double(i) + 0.5) * width - origin.x,
                                             y: bases[i]! - origin.y))
                }
                path.addLine(to: CGPoint(x: right, y: lastBase))
                path.addLine(to: CGPoint(x: right, y: lastBase + heights[end] * 0.65))
                var previous = CGPoint(x: right, y: lastBase + heights[end] * 0.65)
                for i in (start...end).reversed() {
                    let point = CGPoint(x: drift.frame.minX + (Double(i) + 0.5) * width - origin.x,
                                        y: bases[i]! - origin.y + heights[i])
                    let middle = CGPoint(x: (point.x + previous.x) * 0.5, y: (point.y + previous.y) * 0.5)
                    path.addQuadCurve(to: middle, control: previous)
                    previous = point
                }
                path.addQuadCurve(to: CGPoint(x: left, y: firstBase + heights[start] * 0.65), control: previous)
                path.closeSubpath()
                let baseline = bases[start...end].compactMap { $0 }.min()! - origin.y
                let crest = max(4, zip(bases[start...end], heights[start...end]).compactMap { base, height in
                    base.map { $0 - origin.y + height - baseline }
                }.max() ?? 4)
                paintBank(path, baseline: baseline, crest: crest, left: left, in: context)
            }
            start = end + 1
        }
    }
    private static func paintBank(_ path: CGPath, baseline: Double, crest: Double, left: Double,
                                  in context: CGContext) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor(calibratedRed: 0.3, green: 0.4, blue: 0.6, alpha: 0.3).cgColor)
        context.addPath(path); context.setFillColor(NSColor(calibratedRed: 0.88, green: 0.94, blue: 1, alpha: 1).cgColor); context.fillPath()
        context.setShadow(offset: .zero, blur: 0)
        context.addPath(path); context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(calibratedRed: 0.68, green: 0.8, blue: 0.93, alpha: 1).cgColor,
            NSColor.white.cgColor
        ] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: left, y: baseline - 3),
                end: CGPoint(x: left, y: baseline + crest), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.restoreGState()
    }

    static func flakes(_ flakes: [StormFlake], windows: [SnowStormWindow], in context: CGContext,
                       worldRect: CGRect, time: Double, excluding fireplaceFrame: CGRect? = nil,
                       behindWindows: Bool = false) {
        context.saveGState()
        defer { context.restoreGState() }
        if behindWindows { clipWindows(windows, in: context, origin: worldRect.origin) }
        if let fireplaceFrame, fireplaceFrame.intersects(worldRect) {
            let bounds = CGRect(origin: .zero, size: worldRect.size)
            let fireplace = fireplaceFrame.offsetBy(dx: -worldRect.minX, dy: -worldRect.minY)
            context.beginPath()
            context.addRect(bounds)
            context.addRect(fireplace)
            context.clip(using: .evenOdd)
        }
        // Four entrance-opacity buckets per depth: a handful of batched paths,
        // rather than thousands of image draws and context state changes.
        let groups = Dictionary(grouping: flakes) { p in
            let depth = p.depthWindow.map(UInt64.init) ?? (1 << 32)
            let opacity = UInt64(min(3, max(0, Int(p.age / 0.05))))
            return (depth << 2) | opacity
        }
        for (key, group) in groups {
            context.saveGState()
            let depth = key >> 2
            if !behindWindows, depth != (1 << 32), let index = windows.firstIndex(where: { UInt64($0.id) == depth }) {
                for window in windows.prefix(index) where window.frame.intersects(worldRect) {
                    let occluder = window.frame.offsetBy(dx: -worldRect.minX, dy: -worldRect.minY)
                    context.beginPath(); context.addRect(CGRect(origin: .zero, size: worldRect.size)); context.addRect(occluder)
                    context.clip(using: .evenOdd)
                }
            }
            let dots = CGMutablePath(), arms = CGMutablePath()
            for p in group where worldRect.insetBy(dx: -p.radius * 2, dy: -p.radius * 2).contains(p.position) {
                let x = p.position.x - worldRect.minX, y = p.position.y - worldRect.minY
                dots.addEllipse(in: CGRect(x: x - p.radius * 0.65, y: y - p.radius * 0.65, width: p.radius * 1.3, height: p.radius * 1.3))
                if p.radius > 3 {
                    let angle = p.phase + time * 0.3, dx = cos(angle) * p.radius, dy = sin(angle) * p.radius
                    arms.move(to: CGPoint(x: x - dx, y: y - dy)); arms.addLine(to: CGPoint(x: x + dx, y: y + dy))
                    arms.move(to: CGPoint(x: x + dy, y: y - dx)); arms.addLine(to: CGPoint(x: x - dy, y: y + dx))
                }
            }
            let opacity = Double((key & 3) + 1) * 0.225
            context.setFillColor(red: 0.95, green: 0.98, blue: 1, alpha: opacity)
            context.addPath(dots); context.fillPath()
            context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: opacity * 0.7); context.setLineWidth(0.8)
            context.addPath(arms); context.strokePath()
            context.restoreGState()
        }
    }
}

private final class StormView: NSView {
    var simulation: SnowStormSimulation?
    var christmas: ChristmasScene?
    var worldRect = CGRect.zero
    var driftID: UInt64?
    var revision: UInt64?
    var holidayFrame: Int?
    var fireplaceFrame: CGRect?
    var santaOnly = false
    var snowBehindWindows = false
    var snowOccluders: [SnowStormWindow] = []
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let simulation, let context = NSGraphicsContext.current?.cgContext else { return }
        if santaOnly {
            if let christmas {
                ChristmasDrawing.santaVisit(scene: christmas, windows: simulation.windows, screen: worldRect,
                                            time: simulation.time, in: context, origin: worldRect.origin)
            }
            return
        }
        if let driftID {
            if let drift = simulation.drifts.first(where: { $0.id == driftID }) {
                SnowStormDrawing.drift(drift, in: context, origin: worldRect.origin,
                                       occludingWindows: snowBehindWindows ? simulation.windows : [])
                if let window = drift.window, let christmas, let decoration = christmas.decoration(for: window.id) {
                    ChristmasDrawing.window(window, decoration: decoration, chimney: christmas.hasChimney(window.id),
                        time: simulation.time, scene: christmas, in: context, origin: worldRect.origin)
                }
            }
        } else {
            if let christmas, christmas.yeti != nil {
                ChristmasDrawing.yetiVisit(scene: christmas, windows: simulation.windows, screen: worldRect,
                    time: simulation.time, in: context, origin: worldRect.origin)
            }
            SnowStormDrawing.flakes(simulation.particles, windows: simulation.windows, in: context,
                                    worldRect: worldRect, time: simulation.time, excluding: fireplaceFrame,
                                    behindWindows: snowBehindWindows)
        }
    }
}

final class SnowStormController {
    private(set) var simulation: SnowStormSimulation
    private var settings: SnowStormSettings
    private let screens: () -> [StaticEffectScreen]
    private let cursor: () -> CGPoint?
    private let present: (NSPanel, SnowStormWindow?) -> Void
    private let presentField: (NSPanel, SnowStormWindow?) -> Void
    private let query: (Set<Int>, Double) -> [SnowStormWindow]
    private let currentDate: () -> Date
    private let holidayCalendar: Calendar
    private let holidaySeed: UInt64
    private var nextHolidayCheck = 0.0
    private var holidaySeason: ChristmasSeason
    private var manualSantaStart: Double?
    private var santaTargetID: UInt32?
    private var yeti: YetiEncounter?
    private var consumedCarolers: Set<UInt32> = []
    private var pendingYetiRequest = false
    private var nextYetiTime: Double
    private(set) var christmas: ChristmasScene
    private let worker = DispatchQueue(label: "app.jimmytweaks.snow-window-metadata", qos: .userInteractive)
    private let christmasWindowValidator = ChristmasWindowValidator()
    private var clock: Timer?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var screenPanels: [CGDirectDisplayID: NSPanel] = [:]
    private var santaPanels: [CGDirectDisplayID: NSPanel] = [:]
    private var fieldTargets: [CGDirectDisplayID: UInt64] = [:]
    private var driftPanels: [UInt64: NSPanel] = [:]
    private var stopped = false
    private var queryInFlight = false
    private var windowReanchorRequested = false
    private var windows: [SnowStormWindow] = []
    private var sampleTime = 0.0
    private var previousTick = ProcessInfo.processInfo.systemUptime
    private var lastOrder: [UInt64] = []
    private var fireplace: FireplaceController?
    private var fireplaceEnabled = false
    private var nextDockQuery = 0.0
    private let fireplaceFactory: () -> FireplaceController?
    #if TESTING
    private(set) var bankRedrawRequestsForTesting = 0
    #endif

    init(settings: SnowStormSettings, screens: @escaping () -> [StaticEffectScreen],
         cursor: @escaping () -> CGPoint? = { NSEvent.mouseLocation },
         cursorShape: CursorSnowShape? = nil,
         query: @escaping (Set<Int>, Double) -> [SnowStormWindow] = SnowStormWindowQuery.read,
         present: @escaping (NSPanel, SnowStormWindow?) -> Void = SnowStormController.order,
         presentField: @escaping (NSPanel, SnowStormWindow?) -> Void = SnowStormController.orderField,
         automaticTicks: Bool = true, fireplaceFactory: (() -> FireplaceController?)? = nil,
         currentDate: @escaping () -> Date = Date.init, holidayCalendar: Calendar = .autoupdatingCurrent,
         holidaySeed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        self.settings = settings; self.screens = screens; self.cursor = cursor; self.query = query; self.present = present; self.presentField = presentField
        simulation = SnowStormSimulation(cursorShape: cursorShape)
        self.currentDate = currentDate; self.holidayCalendar = holidayCalendar; self.holidaySeed = holidaySeed
        nextYetiTime = YetiEncounter.nextDelay(seed: holidaySeed)
        holidaySeason = ChristmasSeason.at(currentDate(), calendar: holidayCalendar)
        christmas = ChristmasScene(season: holidaySeason, windows: [], seed: holidaySeed)
        self.fireplaceFactory = fireplaceFactory ?? { FireplaceController(screens: screens) }
        if automaticTicks {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.004; RunLoop.main.add(timer, forMode: .common); clock = timer
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.scheduleWindowReanchor()
                return event
            }
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.scheduleWindowReanchor()
            }
        }
    }
    deinit { shutdown() }
    func update(settings: SnowStormSettings) { self.settings = settings }
    func triggerSanta() {
        guard !stopped else { return }
        guard !christmas.santa.active || christmas.santaPhase(time: simulation.time) >= SantaVisitPose.duration else { return }
        manualSantaStart = simulation.time
        santaTargetID = nil
        let displays = screens()
        refreshChristmas(screens: displays.map(\.frame), force: true)
        render(displays: displays)
    }
    func triggerYeti() {
        guard !stopped, yeti == nil else { return }
        pendingYetiRequest = true
        let displays = screens()
        refreshChristmas(screens: displays.map(\.frame), force: true)
        render(displays: displays)
    }
    func setFireplace(enabled: Bool, widthFraction: Double, height: Double, offset: Double) {
        guard !stopped else { return }
        let changed = fireplaceEnabled != enabled
        fireplaceEnabled = enabled
        if enabled {
            if fireplace == nil { fireplace = fireplaceFactory() }
            else { fireplace?.setEnabled(true) }
            fireplace?.setWidthFraction(widthFraction)
            fireplace?.setHeight(height)
            fireplace?.setOffset(offset)
            if changed { nextDockQuery = 0 }
        } else { fireplace?.setEnabled(false) }
    }
    func takeFireplaceForDeparture() -> FireplaceController? {
        guard let fireplace else { return nil }
        self.fireplace = nil; fireplaceEnabled = false
        if fireplace.finished { fireplace.shutdown(); return nil }
        return fireplace
    }
    func shutdown() {
        stopped = true; clock?.invalidate(); clock = nil
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor); self.globalClickMonitor = nil }
        for panel in allPanels { panel.orderOut(nil) }
        screenPanels.removeAll(); santaPanels.removeAll(); fieldTargets.removeAll(); driftPanels.removeAll()
        simulation = SnowStormSimulation()
        yeti = nil; consumedCarolers.removeAll(); pendingYetiRequest = false
        fireplace?.shutdown(); fireplace = nil
    }
    static func order(_ panel: NSPanel, window: SnowStormWindow?) {
        if let window { panel.level = NSWindow.Level(rawValue: window.level); panel.order(.above, relativeTo: Int(window.id)) }
        else { panel.orderFrontRegardless() }
    }
    static func orderField(_ panel: NSPanel, window: SnowStormWindow?) {
        if let window { panel.level = NSWindow.Level(rawValue: window.level); panel.order(.below, relativeTo: Int(window.id)) }
        else { panel.level = .normal; panel.orderFrontRegardless() }
    }
    private func scheduleWindowReanchor() {
        // Run after AppKit has processed the click that may raise its target.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.windowReanchorRequested = true
            self.sampleWindows(displays: self.screens(), pointer: self.cursor())
        }
    }
    private func reanchorWindowPanels(windows: [SnowStormWindow]) {
        guard !stopped, !driftPanels.isEmpty || !santaPanels.isEmpty else { return }
        // Use the background sample, including its live IDs: a close click can
        // remove a host before the animation has discarded its old strip.
        for target in windows.reversed() {
            guard let panel = driftPanels[UInt64(target.id)] else { continue }
            present(panel, target)
        }
        if let targetID = christmas.target,
           let target = windows.first(where: { $0.id == targetID }) {
            for panel in santaPanels.values { present(panel, target) }
        }
    }
    private func refreshChristmas(screens displayFrames: [CGRect], force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if force || now >= nextHolidayCheck {
            holidaySeason = ChristmasSeason.at(currentDate(), calendar: holidayCalendar)
            nextHolidayCheck = now + 30
        }
        if let start = manualSantaStart, simulation.time - start >= SantaVisitPose.duration { manualSantaStart = nil }
        if let visit = yeti, visit.phase(at: simulation.time) >= YetiEncounter.duration {
            if !visit.temporaryCarolers { consumedCarolers.insert(visit.windowID) }
            yeti = nil
            nextYetiTime = simulation.time + YetiEncounter.nextDelay(seed: holidaySeed ^ UInt64(Int(simulation.time)))
        }
        christmas = ChristmasScene(season: holidaySeason, windows: simulation.windows,
                                   screens: displayFrames, seed: holidaySeed,
                                   decorationsEnabled: settings.decorations, lightsEnabled: settings.lights,
                                   manualSantaStart: manualSantaStart,
                                   preferredTarget: santaTargetID ?? christmas.chimneys.first,
                                   retainedDecorationIDs: christmas.decorations.keys.sorted {
                                       ChristmasScene.hash(UInt64($0) ^ holidaySeed) < ChristmasScene.hash(UInt64($1) ^ holidaySeed)
                                   }, yeti: yeti, consumedCarolers: consumedCarolers)
        if yeti == nil && (pendingYetiRequest || (settings.decorations && simulation.time >= nextYetiTime)) {
            let manual = pendingYetiRequest
            if startYeti(manual: manual) {
                pendingYetiRequest = false
                christmas = ChristmasScene(season: holidaySeason, windows: simulation.windows,
                                           screens: displayFrames, seed: holidaySeed,
                                           decorationsEnabled: settings.decorations, lightsEnabled: settings.lights,
                                           manualSantaStart: manualSantaStart,
                                           preferredTarget: santaTargetID ?? christmas.chimneys.first,
                                           retainedDecorationIDs: Array(christmas.decorations.keys),
                                           yeti: yeti, consumedCarolers: consumedCarolers)
            } else if !manual {
                nextYetiTime = simulation.time + YetiEncounter.nextDelay(seed: holidaySeed ^ UInt64(Int(simulation.time)))
            }
        }
        if christmas.santaPhase(time: simulation.time) < SantaVisitPose.duration {
            // Keep the original destination for this whole visit. If its roof
            // becomes covered, ChristmasScene hides Santa until it is exposed
            // again instead of teleporting him to a different chimney.
            if santaTargetID == nil { santaTargetID = christmas.target }
        } else {
            santaTargetID = nil
        }
    }
    private func startYeti(manual: Bool) -> Bool {
        let windows = simulation.windows
        let existing = windows.compactMap { window -> (SnowStormWindow, Double)? in
            guard !consumedCarolers.contains(window.id),
                  let fraction = christmas.carolerFraction(for: window.id, at: simulation.time),
                  ChristmasScene.roofVisible(on: window, in: windows, fractions: [fraction]) else { return nil }
            return (window, fraction)
        }
        let fallback = manual ? windows.filter { window in
            window.decoratable && window.frame.width >= 210 && window.frame.height >= 90 &&
                ChristmasScene.roofVisible(on: window, in: windows, fractions: [0.5])
        }.map { ($0, 0.5) } : []
        let choices = existing.isEmpty ? fallback : existing
        guard let chosen = choices.min(by: {
            ChristmasScene.hash(UInt64($0.0.id) ^ holidaySeed ^ UInt64(Int(simulation.time))) <
                ChristmasScene.hash(UInt64($1.0.id) ^ holidaySeed ^ UInt64(Int(simulation.time)))
        }) else { return false }
        let direction = ChristmasScene.hash(UInt64(chosen.0.id) ^ holidaySeed ^ UInt64(Int(simulation.time))) & 1 == 0 ? 1.0 : -1.0
        yeti = YetiEncounter(start: simulation.time, windowID: chosen.0.id,
                             carolerFraction: chosen.1, direction: direction,
                             temporaryCarolers: existing.isEmpty)
        nextYetiTime = simulation.time + YetiEncounter.nextDelay(seed: holidaySeed ^ UInt64(Int(simulation.time)))
        return true
    }
    private func sampleWindows(displays: [StaticEffectScreen], pointer: CGPoint?) {
        let now = ProcessInfo.processInfo.systemUptime
        if !queryInFlight {
            queryInFlight = true
            let reanchor = windowReanchorRequested
            windowReanchorRequested = false
            // Include Jimmy Tweaks' ordinary Settings window, but exclude all
            // untitled effect/control surfaces, including gesture overlays.
            let excluded = Set(NSApp.windows.filter { !$0.styleMask.contains(.titled) }.map(\.windowNumber))
            let desktopTop = NSScreen.screens.first?.frame.maxY ?? displays.first?.frame.maxY ?? 0
            let read = query
            let validator = christmasWindowValidator
            let wantsFestive = settings.decorations || settings.lights || holidaySeason == .eve ||
                manualSantaStart != nil || pendingYetiRequest
            let wantsDock = fireplaceEnabled && now >= nextDockQuery
            if wantsDock { nextDockQuery = now + 0.125 }
            worker.async { [weak self] in
                let sampled = read(excluded, desktopTop)
                let result = wantsFestive ? validator.validate(sampled, desktopTop: desktopTop) : sampled
                let dock = wantsDock ? FireplaceDockQuery.read(desktopTop: desktopTop, cursor: pointer) : nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.windows = result; self.sampleTime = now; self.queryInFlight = false
                    // A click arriving during this read needs a newer sample.
                    // Coalesce such clicks into one follow-up, never a queue of
                    // Window Server scans on the animation/input thread.
                    if self.windowReanchorRequested {
                        self.sampleWindows(displays: self.screens(), pointer: self.cursor())
                    } else if reanchor {
                        self.reanchorWindowPanels(windows: result)
                    }
                    if wantsDock && self.fireplaceEnabled { self.fireplace?.updateDock(dock) }
                }
            }
        }
    }
    private func tick() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime, dt = now - previousTick
        previousTick = now
        let displays = screens()
        let pointer = cursor()
        sampleWindows(displays: displays, pointer: pointer)
        simulation.advance(dt: dt, windows: windows, cursor: pointer, screens: displays.map(\.frame), settings: settings, windowSampleTime: sampleTime)
        refreshChristmas(screens: displays.map(\.frame))
        render(displays: displays)
        fireplace?.advance(dt)
    }
    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = StormPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.acceptsMouseMovedEvents = false; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityHidden(true)
        let view = StormView(frame: CGRect(origin: .zero, size: frame.size))
        view.setAccessibilityHidden(true); panel.contentView = view
        return panel
    }
    private func update(_ panel: NSPanel, frame: CGRect, drift: StormDrift?) {
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        guard let view = panel.contentView as? StormView else { return }
        let decorated = drift?.window.flatMap { christmas.decoration(for: $0.id) }
        let hasCarolers = christmas.carolerPlacements(at: simulation.time).contains { $0.windowID == drift?.window?.id } ||
            (christmas.yeti?.windowID == drift?.window?.id && christmas.yeti?.temporaryCarolers == true)
        let hasChimneySanta = drift?.window?.id == christmas.target &&
            christmas.santaPhase(time: simulation.time) >= 12 &&
            christmas.santaPhase(time: simulation.time) < 18.8
        let holidayFrame: Int? = decorated == nil ? nil : Int(simulation.time * (hasCarolers || hasChimneySanta ? 24 : 6))
        let occluders = settings.behindWindows ? simulation.windows : []
        let changed = view.worldRect.size != frame.size || view.driftID != drift?.id || view.revision != drift?.revision || view.holidayFrame != holidayFrame ||
            view.snowBehindWindows != settings.behindWindows || view.snowOccluders != occluders
        view.snowBehindWindows = settings.behindWindows; view.snowOccluders = occluders
        view.worldRect = frame; view.driftID = drift?.id; view.revision = drift?.revision; view.holidayFrame = holidayFrame
        view.fireplaceFrame = drift == nil && fireplace?.model.isVisible == true ? fireplace?.model.layout.frame : nil
        view.simulation = simulation; view.christmas = christmas
        if drift == nil || changed {
            view.needsDisplay = true
            #if TESTING
            if drift != nil { bankRedrawRequestsForTesting += 1 }
            #endif
        }
    }
    private func render(displays: [StaticEffectScreen]) {
        let ids = Set(displays.map(\.id))
        for id in Array(screenPanels.keys) where !ids.contains(id) {
            screenPanels.removeValue(forKey: id)?.orderOut(nil); fieldTargets.removeValue(forKey: id)
        }
        for id in Array(santaPanels.keys) where !ids.contains(id) {
            santaPanels.removeValue(forKey: id)?.orderOut(nil)
        }
        for screen in displays {
            let panel = screenPanels[screen.id] ?? makePanel(frame: screen.frame)
            let isNew = screenPanels[screen.id] == nil
            if isNew { screenPanels[screen.id] = panel }
            let screenWindows = simulation.windows.filter { $0.frame.intersects(screen.frame) }
            let target = settings.behindWindows ? screenWindows.last : screenWindows.first
            let key = target.map { UInt64($0.id) << 32 | UInt64(UInt32(bitPattern: Int32($0.level))) } ?? 0
            // Wait for the first window sample before showing the field, so it
            // cannot flash in front of the foreground window at startup.
            if sampleTime > 0 || !simulation.windows.isEmpty {
                if isNew || fieldTargets[screen.id] != key { presentField(panel, target); fieldTargets[screen.id] = key }
            }
            update(panel, frame: screen.frame, drift: nil)
        }
        let active = Set(simulation.drifts.filter { $0.mass > 0.01 || ($0.window.map { christmas.decoration(for: $0.id) != nil } ?? false) }.map(\.id))
        for id in Array(driftPanels.keys) where !active.contains(id) { driftPanels.removeValue(forKey: id)?.orderOut(nil) }
        // Back to front keeps each snowbank immediately above its own window.
        let order = simulation.windows.map { UInt64($0.id) << 32 | UInt64(UInt32(bitPattern: Int32($0.level))) }
        let orderingChanged = lastOrder != order
        lastOrder = order
        for drift in simulation.drifts.reversed() where active.contains(drift.id) {
            let shapedCursor = drift.cursorShape != nil
            let cornerDrop = drift.window == nil ? 0 : StormDrift.cornerDrop
            let decorated = drift.window.map { christmas.decoration(for: $0.id) != nil } ?? false
            let lowerReach = decorated ? ChristmasDrawing.windowStripDrop : cornerDrop
            let frame = CGRect(x: drift.frame.minX - 4, y: (shapedCursor ? drift.frame.minY : drift.frame.maxY - lowerReach) - 4,
                               width: drift.frame.width + 8,
                               height: shapedCursor ? drift.frame.height + drift.maximumHeight + 8 :
                                   (decorated ? 106 + lowerReach : drift.maximumHeight + 12 + cornerDrop))
            let isNew = driftPanels[drift.id] == nil
            let panel = driftPanels[drift.id] ?? makePanel(frame: frame)
            driftPanels[drift.id] = panel
            if drift.isCursor { panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1) }
            let movedWindow = drift.window != nil && panel.frame != frame
            update(panel, frame: frame, drift: drift)
            // A native drag can raise its window above our already visible
            // overlay without changing the CGWindow list order. Re-anchor that
            // snowbank or decorated strip whenever its frame moves. Clicks
            // re-anchor stationary hosts using a fresh background window sample.
            if isNew || orderingChanged || movedWindow {
                present(panel, drift.window)
            }
        }
        let santaTarget = christmas.target.flatMap { id in simulation.windows.first { $0.id == id } }
        let visiting = christmas.santa.active && christmas.santaPhase(time: simulation.time) < SantaVisitPose.duration
        for screen in displays {
            guard visiting, let santaTarget, santaTarget.frame.intersects(screen.frame) else {
                santaPanels.removeValue(forKey: screen.id)?.orderOut(nil)
                continue
            }
            let isNew = santaPanels[screen.id] == nil
            let panel = santaPanels[screen.id] ?? makePanel(frame: screen.frame)
            santaPanels[screen.id] = panel
            (panel.contentView as? StormView)?.santaOnly = true
            update(panel, frame: screen.frame, drift: nil)
            // Re-anchor after the window's decoration strip, including after a focus change.
            if isNew || orderingChanged { present(panel, santaTarget) }
        }
    }
    var allPanels: [NSPanel] { Array(screenPanels.values) + Array(santaPanels.values) + Array(driftPanels.values) + (fireplace?.allPanels ?? []) }
    #if TESTING
    func advanceForTesting(dt: Double, windows: [SnowStormWindow], cursor: CGPoint?, emit: Bool = false) {
        guard !stopped else { return }
        let displays = screens()
        simulation.advance(dt: dt, windows: windows, cursor: cursor, screens: displays.map(\.frame), settings: settings, emit: emit)
        refreshChristmas(screens: displays.map(\.frame), force: true)
        render(displays: displays)
        fireplace?.advance(dt)
    }
    var timerRunningForTesting: Bool { clock != nil }
    var timerIntervalForTesting: TimeInterval? { clock?.timeInterval }
    var fireplaceForTesting: FireplaceController? { fireplace }
    var santaPanelsForTesting: [NSPanel] { Array(santaPanels.values) }
    func scheduleYetiNowForTesting() { nextYetiTime = simulation.time }
    func reanchorWindowPanelsForTesting() { scheduleWindowReanchor() }
    #endif
}
