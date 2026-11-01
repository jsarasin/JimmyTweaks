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
            expect("\(corner.name) corner hit", WindowGeometry.corner(at: corner.point(in: frame), frame: frame, size: 24) == corner)
        }
        expect("Center is not resize corner", WindowGeometry.corner(at: CGPoint(x: frame.midX, y: frame.midY), frame: frame, size: 24) == nil)
        expect("Tiny-window tie is stable", WindowGeometry.corner(at: CGPoint(x: 5, y: 5), frame: CGRect(x: 0, y: 0, width: 10, height: 10), size: 24) == .topLeft)
        expect("Interior excludes title bar", !WindowGeometry.interiorContains(CGPoint(x: 100, y: 20), frame: CGRect(x: 0, y: 0, width: 300, height: 300)))
        expect("Interior accepts content", WindowGeometry.interiorContains(CGPoint(x: 100, y: 60), frame: CGRect(x: 0, y: 0, width: 300, height: 300)))
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
                    readFrame: { frame }, readSize: { frame.size },
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
                readFrame: { moved }, readSize: { moved.size }, setPosition: { moved.origin = $0 },
                setSize: { _ in expect("Moving never resizes", false) })
            expect("Moving follows outside pointer and returns to origin", accepted == seed.desiredFrame(at: pointer))
        }
    }
    static func preferences() {
        let defaults = MemoryDefaults()
        defaults.set(999, forKey: PreferenceKey.moveThreshold.rawValue)
        defaults.set("bad", forKey: PreferenceKey.enabled.rawValue)
        defaults.set("unknown", forKey: PreferenceKey.activation.rawValue)
        let p = PreferenceStore(defaults: defaults)
        expect("Default corner size is 200 points", p.int(.cornerSize) == 200 && GesturePreferences().cornerSize == 200)
        p.set(200, for: .cornerSize)
        expect("Corner range permits the new default", p.int(.cornerSize) == 200)
        expect("Stored threshold clamped", p.int(.moveThreshold) == 30)
        expect("Wrong type restored", p.bool(.enabled))
        expect("Unknown activation restored", p.string(.activation) == "immediate")
        expect("Repair surfaced", p.repairMessage != nil)
        expect("Menu bar icon defaults on", p.bool(.showMenuBarIcon))
        p.set(false, for: .showMenuBarIcon)
        expect("Menu bar icon preference persists", !PreferenceStore(defaults: defaults).bool(.showMenuBarIcon))
        p.set(true, for: .suspended); p.set(false, for: .enabled); p.resetWindow()
        expect("Utility reset preserves suspension", p.bool(.suspended) && p.bool(.enabled))
        expect("Window reset preserves menu bar choice", !p.bool(.showMenuBarIcon))
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
