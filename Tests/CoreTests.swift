import Foundation
import CoreGraphics

@main struct CoreTests {
    static var checks = 0
    static var failures: [String] = []
    static func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
        checks += 1; if !condition() { failures.append(name); print("FAIL: " + name) }
    }
    static func main() throws {
        geometry(); gestures(); preferences(); search(); scripts(); retry()
        try frameTransactions()
        try logging(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("\(checks - failures.count)/\(checks) focused checks passed.")
        if !failures.isEmpty { exit(1) }
    }
    static func geometry() {
        let frame = CGRect(x: -280.5, y: 140.25, width: 500, height: 340)
        for corner in WindowCorner.allCases {
            let seed = GestureSeed(frame: frame, pointer: corner.point(in: frame), kind: .resize(corner))
            for offset in [CGPoint(x: 45.5, y: -20.25), CGPoint(x: -800, y: 1000), .zero] {
                let desired = seed.desiredFrame(at: CGPoint(x: seed.pointer.x + offset.x, y: seed.pointer.y + offset.y))
                expect("\(corner.name) dimensions remain positive", desired.width >= 1 && desired.height >= 1)
                expect("\(corner.name) opposite anchor fixed", WindowGeometry.distance(corner.anchor(in: desired), corner.anchor(in: frame)) < 0.001)
            }
            expect("\(corner.name) corner hit", WindowGeometry.activationKind(at: corner.point(in: frame), frame: frame, edgeZoneSize: 24) == .resize(corner))
        }
        expect("Center moves", WindowGeometry.activationKind(at: CGPoint(x: frame.midX, y: frame.midY), frame: frame, edgeZoneSize: 24) == .move)
        expect("Tiny windows retain a usable moving centre", WindowGeometry.activationKind(at: CGPoint(x: 5, y: 5), frame: CGRect(x: 0, y: 0, width: 10, height: 10), edgeZoneSize: 24) == .move)
        // Exercise every edge's exact boundary and both neighbours at fractional, negative coordinates.
        for size in [8.0, 24, 200, 400] {
            let large = CGRect(x: -900.5, y: -700.25, width: 1200, height: 1000)
            for depth in [size - 0.001, size, size + 0.001] {
                for point in [CGPoint(x: large.minX + depth, y: large.midY),
                              CGPoint(x: large.maxX - depth, y: large.midY),
                              CGPoint(x: large.midX, y: large.minY + depth),
                              CGPoint(x: large.midX, y: large.maxY - depth)] {
                    let kind = WindowGeometry.activationKind(at: point, frame: large, edgeZoneSize: size)
                    expect("Shared boundary has no gap or overlap", kind != nil && (kind == .move) == (depth > size))
                }
            }
            for bounds in [large, frame, CGRect(x: -10, y: -20, width: 10, height: 6)] {
                for x in 0...20 {
                    for y in 0...20 {
                        let point = CGPoint(x: bounds.minX + bounds.width * Double(x) / 20,
                                            y: bounds.minY + bounds.height * Double(y) / 20)
                        let kind = WindowGeometry.activationKind(at: point, frame: bounds, edgeZoneSize: size)
                        let inset = WindowGeometry.effectiveEdgeZoneSize(frame: bounds, requested: size)
                        let inCentre = point.x > bounds.minX + inset && point.x < bounds.maxX - inset &&
                            point.y > bounds.minY + inset && point.y < bounds.maxY - inset
                        expect("Every point belongs to exactly one activation area", kind != nil && (kind == .move) == inCentre)
                    }
                }
            }
            for point in [CGPoint(x: large.minX - 0.501, y: large.midY), CGPoint(x: large.maxX + 0.501, y: large.midY),
                          CGPoint(x: large.midX, y: large.minY - 0.501), CGPoint(x: large.midX, y: large.maxY + 0.501)] {
                expect("Outside the window is ineligible", WindowGeometry.activationKind(at: point, frame: large, edgeZoneSize: size) == nil)
            }
        }
        let square = CGRect(x: 0, y: 0, width: 300, height: 300)
        expect("Shared inset replaces separate title-bar exclusion", WindowGeometry.activationKind(at: CGPoint(x: 100, y: 20), frame: square, edgeZoneSize: 8) == .move)
        expect("Edge middle selects nearest corner with stable tie", WindowGeometry.activationKind(at: CGPoint(x: 150, y: 0), frame: square, edgeZoneSize: 8) == .resize(.topLeft))
        expect("Invalid window rejected", WindowGeometry.activationKind(at: .zero, frame: .zero, edgeZoneSize: 8) == nil)
        expect("Moving keeps cursor offset", GestureSeed(frame: frame, pointer: CGPoint(x: -200, y: 200), kind: .move).desiredFrame(at: CGPoint(x: -150, y: 230)) == frame.offsetBy(dx: 50, dy: 30))
        expect("Euclidean threshold", abs(WindowGeometry.distance(.zero, CGPoint(x: 3, y: 4)) - 5) < 0.0001)
        var random: UInt64 = 42
        for _ in 0..<500 {
            random = random &* 1664525 &+ 1013904223
            let delta = Double(random % 4000) - 2000
            for c in WindowCorner.allCases {
                let s = GestureSeed(frame: frame, pointer: .zero, kind: .resize(c))
                let r = s.desiredFrame(at: CGPoint(x: delta, y: -delta * 0.7))
                expect("Random anchored geometry", WindowGeometry.distance(c.anchor(in: r), c.anchor(in: frame)) < 0.001 && WindowGeometry.valid(r))
            }
        }
    }
    static func gestures() {
        let modifiers = Modifiers(command: true, extra: false)
        var p = GesturePreferences(), m = GestureMachine()
        let down = m.handle(.down(.left, .zero, modifiers), preferences: p, accepting: true)
        expect("Candidate down is held", down.suppress && down.effects.contains(.holdDown))
        let id = m.token!
        _ = m.resolved(id: id, kind: .move)
        expect("Moving uses threshold", m.phase == .pending)
        let below = m.handle(.drag(.left, CGPoint(x: 4.99, y: 0)), preferences: p, accepting: true)
        expect("Below threshold remains pending", below.suppress && m.phase == .pending)
        let at = m.handle(.drag(.left, CGPoint(x: 3, y: 4)), preferences: p, accepting: true)
        expect("Exact threshold activates", m.phase == .active && at.effects.contains(.began(.move)))
        let commandUp = m.handle(.flags(Modifiers(command: false, extra: false)), preferences: p, accepting: true)
        expect("Command release drains", m.phase == .draining && commandUp.effects.contains(.end(flush: false, reason: "command-up")))
        _ = m.handle(.flags(modifiers), preferences: p, accepting: true)
        expect("Repress cannot resume drain", m.phase == .draining)
        let up = m.handle(.up(.left, CGPoint(x: 4, y: 4)), preferences: p, accepting: true)
        expect("Owned up consumed", up.suppress && m.phase == .idle)

        m = GestureMachine(); _ = m.handle(.down(.left, .zero, modifiers), preferences: p, accepting: true)
        _ = m.resolved(id: m.token!, kind: .move)
        let click = m.handle(.up(.left, CGPoint(x: 1, y: 0)), preferences: p, accepting: true)
        expect("Subthreshold click is balanced replay plus live up", !click.suppress && click.effects.contains(.replay) && m.phase == .idle)

        m = GestureMachine(); _ = m.handle(.down(.right, .zero, modifiers), preferences: p, accepting: true)
        let immediate = m.resolved(id: m.token!, kind: .resize(.bottomRight))
        expect("Immediate resize has no threshold", m.phase == .active && immediate.effects.contains(.began(.resize(.bottomRight))))
        let escape = m.handle(.escapeDown, preferences: p, accepting: true)
        expect("Escape restores and owns key pair", escape.suppress && escape.effects.contains(.restore) && m.escapeOwned)
        _ = m.handle(.up(.right, .zero), preferences: p, accepting: true)
        expect("Escape ownership outlives mouse up", m.escapeOwned)
        expect("Escape key up consumed", m.handle(.escapeUp, preferences: p, accepting: true).suppress && !m.escapeOwned)

        p.immediateResize = false; m = GestureMachine()
        _ = m.handle(.down(.right, .zero, modifiers), preferences: p, accepting: true); _ = m.resolved(id: m.token!, kind: .resize(.topLeft))
        expect("Alternate resize mode waits", m.phase == .pending)
        let interrupted = m.handle(.interrupt, preferences: p, accepting: true)
        expect("Unrelated input relinquishes before forwarding", !interrupted.suppress && interrupted.effects.contains(.replay) && m.phase == .passThrough)
        expect("Relinquished up passes", !m.handle(.up(.right, .zero), preferences: p, accepting: true).suppress)

        m = GestureMachine(); let ordinary = m.handle(.down(.left, .zero, Modifiers(command: false, extra: false)), preferences: p, accepting: true)
        expect("Ordinary input untouched", !ordinary.suppress && m.phase == .idle)
        expect("Extra modifiers untouched", !m.handle(.down(.left, .zero, Modifiers(command: true, extra: true)), preferences: p, accepting: true).suppress)
        expect("Suspension closes admission", !m.handle(.down(.left, .zero, modifiers), preferences: p, accepting: false).suppress)

        m = GestureMachine(); _ = m.handle(.down(.left, .zero, modifiers), preferences: p, accepting: true)
        let token = m.token!; _ = m.timeout(id: token)
        expect("Timeout releases candidate", m.phase == .passThrough)
        expect("Late resolution cannot activate", m.resolved(id: token, kind: .move).effects.isEmpty && m.phase == .passThrough)

        m = GestureMachine(); _ = m.handle(.down(.left, .zero, modifiers), preferences: p, accepting: true); _ = m.resolved(id: m.token!, kind: .move)
        var changed = p; changed.moveThreshold = 30
        _ = m.handle(.drag(.left, CGPoint(x: 5, y: 0)), preferences: changed, accepting: true)
        expect("Gesture settings snapshotted at down", m.phase == .active)
        let cancelled = m.cancel(replayPending: true, reason: "suspend")
        expect("Suspend keeps frame and drains without click replay", m.phase == .draining && !cancelled.effects.contains(.replay))
        m.clearReleasedOwnership(mouseReleased: true, escapeReleased: true)
        expect("Physical cleanup cannot swallow next click", m.phase == .idle)

        // A global drag stays owned by its initial window/corner beyond every edge.
        for kind in [GestureKind.move] + WindowCorner.allCases.map({ .resize($0) }) {
            let button: MouseButton = kind == .move ? .left : .right
            m = GestureMachine()
            _ = m.handle(.down(button, CGPoint(x: 200, y: 200), modifiers), preferences: p, accepting: true)
            let id = m.token!
            _ = m.resolved(id: id, kind: kind)
            for point in [CGPoint(x: -2000, y: -1000), CGPoint(x: 4000, y: 3000), CGPoint(x: 200, y: 200)] {
                let drag = m.handle(.drag(button, point), preferences: p, accepting: true)
                expect("Outside drag keeps original target and corner", m.phase == .active && m.token == id && m.session?.kind == kind && drag.suppress && drag.effects.contains(.apply(point)))
                expect("Outside drag never hit-tests a replacement", !drag.effects.contains { if case .resolve = $0 { return true }; return false })
            }
            expect("Outside mouse-up ends owned drag", m.handle(.up(button, CGPoint(x: 4000, y: 3000)), preferences: p, accepting: true).suppress && m.phase == .idle)
        }
    }
    static func frameTransactions() throws {
        let original = CGRect(x: 100, y: 100, width: 500, height: 340)
        for corner in WindowCorner.allCases {
            let seed = GestureSeed(frame: original, pointer: corner.point(in: original), kind: .resize(corner))
            var frame = original, constrainedPosition = true, writes = 0
            func apply(_ pointer: CGPoint, check: () throws -> Void = {}) throws -> CGRect {
                try WindowFrameTransaction.apply(seed: seed, pointer: pointer, check: check,
                    readFrame: { frame },
                    setPosition: { point in
                        writes += 1
                        frame.origin = constrainedPosition ? CGPoint(x: max(120, point.x), y: max(120, point.y)) : point
                    }, setSize: { size in
                        writes += 1
                        frame.size = CGSize(width: min(650, max(200, size.width)), height: min(500, max(180, size.height)))
                    })
            }
            let outside = CGPoint(x: seed.pointer.x + (corner.isLeft ? -2000 : 2000),
                                  y: seed.pointer.y + (corner.isTop ? -2000 : 2000))
            for _ in 0..<3 {
                writes = 0
                let accepted = try apply(outside)
                expect("Clamped outside resize stays responsive", accepted.size == CGSize(width: 650, height: 500))
                expect("Anchor reconciliation remains bounded", writes <= 3)
            }
            constrainedPosition = false
            let returned = try apply(seed.pointer)
            expect("Returning to initial pointer restores original frame", WindowGeometry.approximatelyEqual(returned, original))
            let reversed = try apply(CGPoint(x: seed.pointer.x + (corner.isLeft ? 50 : -50),
                                             y: seed.pointer.y + (corner.isTop ? 50 : -50)))
            expect("Reversing after an outside clamp resizes again", reversed.size == CGSize(width: 450, height: 290))
            expect("Reversed resize preserves original opposite corner", WindowGeometry.distance(corner.anchor(in: reversed), corner.anchor(in: original)) < 0.001)
            enum Cancelled: Error { case cancelled }
            writes = 0
            do {
                _ = try apply(outside, check: { throw Cancelled.cancelled })
                expect("Cancelled frame transaction fails", false)
            } catch Cancelled.cancelled {
                expect("Cancelled frame transaction never writes", writes == 0)
            }
        }
        var moved = original
        let seed = GestureSeed(frame: original, pointer: CGPoint(x: 200, y: 200), kind: .move)
        for pointer in [CGPoint(x: -2000, y: -1000), CGPoint(x: 4000, y: 3000), seed.pointer] {
            let accepted = try WindowFrameTransaction.apply(seed: seed, pointer: pointer, check: {},
                readFrame: { moved }, setPosition: { moved.origin = $0 },
                setSize: { _ in expect("Moving never resizes", false) })
            expect("Moving follows outside pointer and returns to origin", accepted == seed.desiredFrame(at: pointer))
        }
        // Model a foreign app that clips AXSize to the space remaining between
        // its current origin and the screen/Dock, and constrains AXPosition too.
        // A valid final frame can still fail if size is written at the old origin.
        for bounds in [CGRect(x: 0, y: 24, width: 1440, height: 800),
                       CGRect(x: -1200, y: -860, width: 1000, height: 760)] {
            for corner in WindowCorner.allCases {
                let original = CGRect(x: corner.isLeft ? bounds.maxX - 500 : bounds.minX,
                                      y: corner.isTop ? bounds.maxY - 340 : bounds.minY,
                                      width: 500, height: 340)
                let seed = GestureSeed(frame: original, pointer: corner.point(in: original), kind: .resize(corner))
                var frame = original, writes = 0
                func apply(_ pointer: CGPoint, restoring: Bool = false, check: () throws -> Void = {}) throws -> CGRect {
                    writes = 0
                    return try WindowFrameTransaction.apply(seed: seed, pointer: pointer, restoring: restoring, check: check,
                        readFrame: { frame },
                        setPosition: { point in
                            writes += 1
                            frame.origin = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - frame.width),
                                                   y: min(max(point.y, bounds.minY), bounds.maxY - frame.height))
                        }, setSize: { size in
                            writes += 1
                            frame.size = CGSize(width: min(size.width, bounds.maxX - frame.minX),
                                                height: min(size.height, bounds.maxY - frame.minY))
                        })
                }
                for delta in [CGSize(width: 80, height: 70), CGSize(width: -60, height: 90),
                              CGSize(width: 90, height: -60), CGSize(width: -50, height: -40)] {
                    let pointer = CGPoint(x: seed.pointer.x + (corner.isLeft ? -delta.width : delta.width),
                                          y: seed.pointer.y + (corner.isTop ? -delta.height : delta.height))
                    let desired = seed.desiredFrame(at: pointer)
                    let accepted = try apply(pointer)
                    expect("\(corner.name) edge/Dock constraint accepts reachable size", WindowGeometry.approximatelyEqual(accepted, desired))
                    expect("\(corner.name) edge/Dock constraint preserves opposite corner", WindowGeometry.distance(corner.anchor(in: accepted), corner.anchor(in: original)) < 0.5)
                    expect("Edge/Dock reconciliation is bounded", writes <= 4)
                    _ = try apply(pointer)
                    expect("An accepted resize is not written again", writes == 0)
                    _ = try apply(pointer, restoring: true)
                    expect("Escape restores edge/Dock frame", WindowGeometry.approximatelyEqual(frame, original))
                }
                let pointer = CGPoint(x: seed.pointer.x + (corner.isLeft ? -80 : 80),
                                      y: seed.pointer.y + (corner.isTop ? -70 : 70))
                _ = try apply(pointer)
                _ = try apply(seed.pointer)
                expect("Reversing to the initial pointer restores edge/Dock frame", WindowGeometry.approximatelyEqual(frame, original))
                enum Cancelled: Error { case cancelled }
                do {
                    _ = try apply(pointer, check: { if writes > 0 { throw Cancelled.cancelled } })
                    expect("Cancellation between edge/Dock writes fails the transaction", false)
                } catch Cancelled.cancelled {
                    expect("Cancellation prevents all subsequent geometry writes", writes == 1)
                }
            }
        }
    }
    static func preferences() {
        let defaults = MemoryDefaults()
        defaults.set(999, forKey: PreferenceKey.moveThreshold.rawValue)
        defaults.set("bad", forKey: PreferenceKey.enabled.rawValue)
        defaults.set("unknown", forKey: PreferenceKey.activation.rawValue)
        let p = PreferenceStore(defaults: defaults)
        expect("Default shared edge size is 200 points", p.int(.edgeZoneSize) == 200 && GesturePreferences().edgeZoneSize == 200)
        let legacy = MemoryDefaults(); legacy.set(72, forKey: "windowResizer.cornerSizePoints")
        expect("Existing corner choice becomes shared edge size", PreferenceStore(defaults: legacy).gesture.edgeZoneSize == 72)
        p.set(1, for: .edgeZoneSize)
        expect("Shared edge size clamps to minimum", p.gesture.edgeZoneSize == 8)
        p.set(500, for: .edgeZoneSize)
        expect("Shared edge size clamps to maximum", p.gesture.edgeZoneSize == 400)
        expect("Original effects remain defaults", p.gesture.resizeEffect == .iridescentEnergy && p.gesture.moveEffect == .blueMist)
        expect("Both gesture effects default on", p.gesture.effectsEnabled(for: .resize(.topLeft)) && p.gesture.effectsEnabled(for: .move))
        p.set(WindowEffect.furiousLightning.rawValue, for: .resizeEffect)
        p.set(WindowEffect.auroraVeil.rawValue, for: .moveEffect)
        p.set(WindowEffect.none.rawValue, for: .resizeEffect)
        let effects = PreferenceStore(defaults: defaults).gesture
        expect("Independent effect selections persist", effects.resizeEffect == .none && effects.moveEffect == .auroraVeil)
        expect("No Effect disables resizing visuals independently", !effects.effectsEnabled(for: .resize(.topLeft)) && effects.effectsEnabled(for: .move))
        let oldChoices = MemoryDefaults()
        oldChoices.set(WindowEffect.furiousLightning.rawValue, forKey: PreferenceKey.resizeEffect.rawValue)
        oldChoices.set(false, forKey: "windowResizer.resizeEffectsEnabled")
        expect("An old unchecked switch migrates to No Effect", PreferenceStore(defaults: oldChoices).gesture.resizeEffect == .none)
        expect("Legacy effect switches are removed after migration", oldChoices.object(forKey: "windowResizer.resizeEffectsEnabled") == nil)
        p.set("unknown-effect", for: .resizeEffect)
        p.set(WindowEffect.furiousLightning.rawValue, for: .moveEffect)
        expect("Unknown and wrong-gesture effects use safe defaults", p.gesture.resizeEffect == .iridescentEnergy && p.gesture.moveEffect == .blueMist)
        expect("Stored threshold clamped", p.int(.moveThreshold) == 30)
        expect("Wrong type restored", p.bool(.enabled))
        expect("Unknown activation restored", p.string(.activation) == "immediate")
        expect("Repair surfaced", p.repairMessage != nil)
        expect("Menu bar icon defaults on", p.bool(.showMenuBarIcon))
        p.set(false, for: .showMenuBarIcon)
        expect("Menu bar icon preference persists", !PreferenceStore(defaults: defaults).bool(.showMenuBarIcon))
        p.set(true, for: .suspended); p.set(false, for: .enabled); p.resetWindow()
        expect("Utility reset preserves suspension", p.bool(.suspended) && p.bool(.enabled))
        expect("Utility reset restores shared edge size", p.gesture.edgeZoneSize == 200)
        expect("Utility reset restores both effect choices", p.gesture.resizeEffect == .iridescentEnergy && p.gesture.moveEffect == .blueMist && !p.gesture.normalWindowEffects)
        expect("Window reset preserves menu bar choice", !p.bool(.showMenuBarIcon))
        expect("Static effects default off", p.staticEffect == .none)
        p.set(StaticEffect.fireflies.rawValue, for: .staticEffect)
        p.set(77, for: .fireflyAmount); p.set(21, for: .rainAmount)
        let saved = PreferenceStore(defaults: defaults)
        expect("Static effect choice and independent options persist", saved.staticEffect == .fireflies && saved.int(.fireflyAmount) == 77 && saved.int(.rainAmount) == 21)
        p.resetWindow()
        expect("Window reset preserves Static settings", p.staticEffect == .fireflies && p.int(.fireflyAmount) == 77)
        defaults.set("snowfall", forKey: PreferenceKey.staticEffect.rawValue)
        let upgraded = PreferenceStore(defaults: defaults)
        expect("Retired Snowfall selections upgrade to Snow Storm", upgraded.staticEffect == .snowStorm &&
               defaults.string(forKey: PreferenceKey.staticEffect.rawValue) == StaticEffect.snowStorm.rawValue)
        p.set("unknown-effect", for: .staticEffect)
        expect("Unknown Static effect safely disables decoration", p.staticEffect == .none)
        p.set(900, for: .fireflySpeed); p.set(-5, for: .rainSize); p.set(true, for: .fireflyAmount)
        expect("Static options normalize bounds and types", p.int(.fireflySpeed) == 100 && p.int(.rainSize) == 1 && p.int(.fireflyAmount) == 50)
        p.finishAssistant(skipped: true); p.resetAll()
        expect("Reset all restores defaults", !p.bool(.suspended) && p.bool(.moveEnabled) && p.int(.moveThreshold) == 5)
        expect("Reset all preserves assistant disposition", !p.needsAssistant)
        expect("Reset all restores menu bar icon", p.bool(.showMenuBarIcon))
        let newer = MemoryDefaults(); newer.set(99, forKey: "preferences.schemaVersion"); newer.set("kept", forKey: "future.key")
        let np = PreferenceStore(defaults: newer)
        expect("Future schema preserved", np.newerSchema && newer.integer(forKey: "preferences.schemaVersion") == 99 && newer.string(forKey: "future.key") == "kept")
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: .preferencesChanged, object: p, queue: nil) { _ in notifications += 1 }
        p.batch { p.set(false, for: .enabled); p.set(true, for: .suspended); p.resetWindow() }
        NotificationCenter.default.removeObserver(observer)
        expect("Reset batch publishes one change", notifications == 1)
    }
    static func search() {
        let c = SearchCatalog()
        c.register(ControlMetadata(id: "move", label: "Move Drag Threshold", description: "Independent movement distance", keywords: ["Command", "five points"], section: "Window Moving", destination: SearchDestination(page: .window, controlID: "move")))
        c.register(ControlMetadata(id: "resize", label: "Resize Activation", description: "Immediate or after a small drag threshold", keywords: ["corner"], section: "Resize", destination: SearchDestination(page: .window, controlID: "resize")))
        expect("Token matches across fields", c.search("command distance").first?.id == "move")
        expect("Label outranks description", c.search("threshold").first?.id == "move")
        expect("Case and diacritics normalized", c.search("résize").first?.id == "resize")
        expect("Unknown token means empty", c.search("missingword").isEmpty)
        expect("Whitespace means no query", c.search("  \n ").isEmpty)
        c.register(ControlMetadata(id: "move", label: "Move Drag Threshold", description: "updated", keywords: [], section: "", destination: SearchDestination(page: .window, controlID: "move")))
        expect("Stable ID registration does not duplicate", c.entries.count == 2)
    }
    static func scripts() {
        let p = ScriptsPreview(); expect("Three samples and static histories", p.scripts.count == 3 && p.history.count == 3 && !p.enabled)
        let originalHistory = p.history.count, id = p.add(); _ = p.duplicate(id)
        expect("Preview changes never append runs", p.history.count == originalHistory)
        expect("HTTPS syntax accepts sample", ScriptsPreview.validURL("https://example.org/scripts/test.sh"))
        for invalid in ["file:///tmp/test.sh", "http://example.com/test.sh", "https://", "https://user:password@example.org/test.sh", "https://example.org/a b"] {
            expect("Reject invalid preview URL", !ScriptsPreview.validURL(invalid))
        }
        p.reset(); expect("Preview reset restores seed", p.scripts.count == 3 && p.history.count == 3)
    }
    static func retry() {
        var b = RetryBudget()
        expect("Retry delay 1", b.nextDelay(now: 0) == 1); expect("Retry delay 2", b.nextDelay(now: 1) == 2)
        expect("Retry delay 4", b.nextDelay(now: 3) == 4); expect("Retry bounded", b.nextDelay(now: 7) == nil)
        b.reset(); expect("Deliberate retry resets budget", b.nextDelay(now: 8) == 1)
    }
    static func logging(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().date(from: "2026-10-29T18:00:00Z")!
        let formatter = ISO8601DateFormatter()
        func line(_ date: Date, _ message: String) -> String { "\(formatter.string(from: date))\tINFO\ttest\tevent\t\(message)\n" }
        let expired = directory.appendingPathComponent("Jimmy-Tweaks-2026-10-21.log")
        let boundary = directory.appendingPathComponent("Jimmy-Tweaks-2026-10-22.log")
        let future = directory.appendingPathComponent("Jimmy-Tweaks-2099-01-01.log")
        let unrelated = directory.appendingPathComponent("notes.txt")
        try line(now.addingTimeInterval(-190 * 3600), "expired").write(to: expired, atomically: true, encoding: .utf8)
        try (line(now.addingTimeInterval(-169 * 3600), "old") + line(now.addingTimeInterval(-167 * 3600), "kept")).write(to: boundary, atomically: true, encoding: .utf8)
        try line(now.addingTimeInterval(10000), "future").write(to: future, atomically: true, encoding: .utf8)
        try "unrelated".write(to: unrelated, atomically: true, encoding: .utf8)
        try LogRetention.clean(directory: directory, active: nil, now: now)
        expect("Expired segment deleted", !FileManager.default.fileExists(atPath: expired.path))
        let boundaryText = try String(contentsOf: boundary, encoding: .utf8)
        expect("Boundary records pruned precisely", !boundaryText.contains("\told") && boundaryText.contains("\tkept"))
        expect("Future segment kept", FileManager.default.fileExists(atPath: future.path))
        expect("Unrelated file untouched", FileManager.default.fileExists(atPath: unrelated.path))
        let logger = FileLogger(directory: directory.appendingPathComponent("writer"), clock: { now }, maintenance: false)
        for i in 0..<48 { logger.log("test", "append", "record-\(i)") }
        var result: Result<URL, Error>?
        logger.flush { result = $0 }
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        if case .success(let url) = result {
            let text = try String(contentsOf: url, encoding: .utf8)
            expect("Serialized logger retains every append", text.components(separatedBy: "\tappend\t").count - 1 == 48)
            expect("Logger keeps plain-text records", text.contains("\tINFO\ttest\tappend\t"))
        } else { expect("Logger flush succeeded", false) }
        // An explicit flush/shutdown must recover diagnostics buffered during
        // failure, even while automatic appends are still in their retry cooldown.
        for useShutdown in [false, true] {
            let blocked = directory.appendingPathComponent(useShutdown ? "blocked-shutdown" : "blocked-flush")
            try "not a directory".write(to: blocked, atomically: true, encoding: .utf8)
            let recovering = FileLogger(directory: blocked, clock: { now }, maintenance: false)
            recovering.log("test", "recovery", "buffered-one")
            recovering.log("test", "recovery", "buffered-two")
            var failure: Result<URL, Error>?
            recovering.flush { failure = $0 }
            let failedDeadline = Date().addingTimeInterval(5)
            while failure == nil && Date() < failedDeadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            if case .failure = failure { expect("Blocked log writer reports failure", true) }
            else { expect("Blocked log writer reports failure", false) }
            try FileManager.default.moveItem(at: blocked, to: blocked.appendingPathExtension("saved"))
            var completed = false
            if useShutdown { recovering.shutdown { completed = true } }
            else { recovering.flush { recovered in
                if case .success = recovered { completed = true }
            } }
            let recoveredDeadline = Date().addingTimeInterval(5)
            while !completed && Date() < recoveredDeadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            expect("Explicit log recovery completes", completed)
            let log = blocked.appendingPathComponent("Jimmy-Tweaks-2026-10-29.log")
            let recoveredText = try String(contentsOf: log, encoding: .utf8)
            expect("Recovery preserves each buffered record exactly once and in order",
                   recoveredText.components(separatedBy: "buffered-one").count == 2 &&
                   recoveredText.components(separatedBy: "buffered-two").count == 2 &&
                   recoveredText.range(of: "buffered-one")!.lowerBound < recoveredText.range(of: "buffered-two")!.lowerBound)
        }
    }
}
