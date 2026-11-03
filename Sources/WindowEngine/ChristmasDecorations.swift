import AppKit

/// Local calendar classification is used only for automatic Santa visits.
enum ChristmasSeason: Equatable {
    case none, week, eve
    static func at(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> ChristmasSeason {
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard parts.month == 12, let day = parts.day, (18...25).contains(day) else { return .none }
        return day == 24 ? .eve : .week
    }
}

struct ChristmasDecoration: Equatable {
    enum Kind: Int, CaseIterable {
        case tree, presents, snowman, carolers, candyCanes, northPoleSign, mistletoe
        case gingerbreadHouse, toyTrain, lanterns, wreath
        case nutcracker, rockingHorse, snowGlobe, holidayMailbox
    }
    let id: UInt32
    let kind: Kind?
    let extras: [Kind]
    let lights: Bool
    let offset: Double
}

struct CarolerPlacement {
    enum Stage { case resting, walking, departing, arriving }
    let sourceID: UInt32
    let windowID: UInt32
    let fraction: Double
    let stage: Stage
    let opacity: Double
}

enum SantaSchedule: Equatable {
    case none, automatic, manual(start: Double)
    var active: Bool { self != .none }
    func phase(at time: Double) -> Double {
        switch self {
        case .none: return .infinity
        case .automatic: return time.truncatingRemainder(dividingBy: 45)
        case .manual(let start): return max(0, time - start)
        }
    }
}

struct SantaVisitPose {
    enum Stage { case riding, dismounting, walking, climbing, descending, inside, resurfacing, returning, remounting, departing }
    static let duration = 22.5
    // The fourth reindeer is 233 points ahead of the sleigh origin. Start the
    // entire team outside the display, with room for its animation and reins.
    static let arrivalStartInset = 280.0
    let sleigh: CGPoint
    let santa: CGPoint
    let stage: Stage
    var carriesPresent: Bool {
        switch stage {
        case .dismounting, .walking, .climbing, .descending: return true
        case .riding, .inside, .resurfacing, .returning, .remounting, .departing: return false
        }
    }
    private static func ease(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
    static func at(_ phase: Double, target: SnowStormWindow, screen: CGRect) -> SantaVisitPose? {
        guard phase >= 0, phase < duration else { return nil }
        let roof = target.frame.maxY
        let chimneyX = ChristmasScene.chimneyX(on: target)
        let landingX = chimneyX - 53, landingY = roof + 2
        let sleigh: CGPoint
        if phase < 8.5 {
            let progress = phase / 8.5
            // Cross the open sky quickly, then ease into the roof landing.
            let eased = 1 - pow(1 - progress, 3.4)
            let startY = max(roof + 60, min(screen.maxY - 45, roof + 125))
            let startX = screen.minX - Self.arrivalStartInset
            sleigh = CGPoint(x: startX + (landingX - startX) * eased,
                             y: startY + (landingY - startY) * eased + sin(phase * 3.5) * 3 * (1 - eased))
        } else if phase < 19.5 {
            sleigh = CGPoint(x: landingX, y: landingY)
        } else {
            let departure = (phase - 19.5) / (duration - 19.5)
            let endX = screen.maxX + 220
            sleigh = CGPoint(x: landingX + (endX - landingX) * departure,
                             y: landingY + 105 * departure + sin(departure * .pi * 3) * 4)
        }
        if phase < 9.4 {
            return SantaVisitPose(sleigh: sleigh, santa: CGPoint(x: sleigh.x - 3, y: sleigh.y + 9), stage: .riding)
        }
        if phase < 10.6 {
            let progress = ease((phase - 9.4) / 1.2)
            return SantaVisitPose(sleigh: sleigh,
                santa: CGPoint(x: landingX - 3 + (chimneyX - 44 - landingX + 3) * progress,
                               y: roof + 11 - 9 * progress), stage: .dismounting)
        }
        if phase < 12 {
            let progress = ease((phase - 10.6) / 1.4)
            return SantaVisitPose(sleigh: sleigh,
                santa: CGPoint(x: chimneyX - 44 + 26 * progress, y: roof + 2), stage: .walking)
        }
        if phase < 13.2 {
            let progress = ease((phase - 12) / 1.2)
            return SantaVisitPose(sleigh: sleigh,
                santa: CGPoint(x: chimneyX - 18 + 18 * progress, y: roof + 2 + 42 * progress), stage: .climbing)
        }
        if phase < 14.4 {
            let progress = ease((phase - 13.2) / 1.2)
            return SantaVisitPose(sleigh: sleigh,
                santa: CGPoint(x: chimneyX, y: roof + 44 - 50 * progress), stage: .descending)
        }
        if phase < 16 {
            return SantaVisitPose(sleigh: sleigh, santa: CGPoint(x: chimneyX, y: roof - 6), stage: .inside)
        }
        if phase < 17.2 {
            let progress = ease((phase - 16) / 1.2)
            return SantaVisitPose(sleigh: sleigh,
                santa: CGPoint(x: chimneyX, y: roof - 6 + 50 * progress), stage: .resurfacing)
        }
        if phase < 18.8 {
            let progress = (phase - 17.2) / 1.6
            if progress < 0.35 {
                let down = ease(progress / 0.35)
                return SantaVisitPose(sleigh: sleigh,
                    santa: CGPoint(x: chimneyX - 18 * down, y: roof + 44 - 42 * down), stage: .returning)
            }
            let along = ease((progress - 0.35) / 0.65)
            return SantaVisitPose(sleigh: sleigh,
                santa: CGPoint(x: chimneyX - 18 + (landingX - 3 - chimneyX + 18) * along,
                               y: roof + 2), stage: .returning)
        }
        if phase < 19.5 {
            let progress = ease((phase - 18.8) / 0.7)
            return SantaVisitPose(sleigh: sleigh,
                santa: CGPoint(x: landingX - 3, y: roof + 2 + 9 * progress), stage: .remounting)
        }
        return SantaVisitPose(sleigh: sleigh,
            santa: CGPoint(x: sleigh.x - 3, y: sleigh.y + 9), stage: .departing)
    }
}

/// A brief roof-level encounter. Natural visits are deliberately many minutes
/// apart; the Lights label can summon the same animation immediately.
struct YetiEncounter: Equatable {
    static let duration = 3.2
    static let biteTime = 1.42
    let start: Double
    let windowID: UInt32
    let carolerFraction: Double
    let direction: Double
    let temporaryCarolers: Bool
    func phase(at time: Double) -> Double { max(0, time - start) }
    static func nextDelay(seed: UInt64) -> Double {
        480 + ChristmasScene.unit(seed ^ 0x7E71) * 480
    }
}

struct YetiPose {
    let center: CGPoint
    let biting: Bool
    static func at(_ phase: Double, encounter: YetiEncounter, target: SnowStormWindow,
                   screen: CGRect) -> YetiPose? {
        guard phase >= 0, phase < YetiEncounter.duration else { return nil }
        let targetX = target.frame.minX + target.frame.width * encounter.carolerFraction
        let contactX = targetX - encounter.direction * 13
        let startX = encounter.direction > 0 ? screen.minX - 50 : screen.maxX + 50
        let exitX = encounter.direction > 0 ? screen.maxX + 50 : screen.minX - 50
        let x: Double
        if phase < 1.15 {
            x = startX + (contactX - startX) * phase / 1.15
        } else if phase < 1.65 {
            x = contactX + sin((phase - 1.15) * 43) * 2.5
        } else {
            x = contactX + (exitX - contactX) * (phase - 1.65) / (YetiEncounter.duration - 1.65)
        }
        let step = Int(floor(phase * 12))
        return YetiPose(center: CGPoint(x: x, y: target.frame.maxY + 1 + (step % 3 == 1 ? 2 : 0)),
                        biting: phase >= 1.15 && phase < 1.65)
    }
}

enum YetiAnimation {
    static let runningFrames = 6
    static let frameCount = 8
    static func frame(at phase: Double, biting: Bool) -> Int {
        let step = max(0, Int(floor(phase * 12)))
        if biting { return 6 + (step & 1) }
        // Deliberately non-sequential: the original game's short sprite loop
        // snaps between different reaches and kicks rather than interpolating.
        let order = [0, 3, 1, 5, 2, 4, 1, 3]
        return order[step % order.count]
    }
}

/// Stable selection avoids decorations jumping between windows on focus changes.
struct ChristmasScene {
    let season: ChristmasSeason
    let decorations: [UInt32: ChristmasDecoration]
    let chimneys: [UInt32]
    let target: UInt32?
    let seed: UInt64
    let santa: SantaSchedule
    let yeti: YetiEncounter?
    let consumedCarolers: Set<UInt32>
    static func chimneyX(on window: SnowStormWindow) -> Double {
        window.frame.minX + window.frame.width * 0.72
    }
    /// The complete dismount path must be visible above the roof, not just
    /// the window body. A covered roof made Santa appear beside another chimney.
    static func landingVisible(on target: SnowStormWindow, in windows: [SnowStormWindow]) -> Bool {
        let offsets = [-56.0, -30.0, 0.0].map { 0.72 + $0 / Double(target.frame.width) }
        return roofVisible(on: target, in: windows, fractions: offsets)
    }
    static func roofVisible(on target: SnowStormWindow, in windows: [SnowStormWindow],
                            fractions: [Double]) -> Bool {
        guard let index = windows.firstIndex(where: { $0.id == target.id }), index > 0 else { return false }
        let roofY = target.frame.maxY + 3
        return !windows.prefix(index).contains { front in
            fractions.contains { front.frame.contains(CGPoint(x: target.frame.minX + target.frame.width * $0, y: roofY)) }
        }
    }
    init(season: ChristmasSeason, windows: [SnowStormWindow], screens: [CGRect] = [], seed: UInt64,
         decorationsEnabled: Bool = false, lightsEnabled: Bool = false, manualSantaStart: Double? = nil,
         preferredTarget: UInt32? = nil, retainedDecorationIDs: [UInt32] = [],
         yeti: YetiEncounter? = nil, consumedCarolers: Set<UInt32> = []) {
        self.season = season; self.seed = seed
        self.yeti = yeti; self.consumedCarolers = consumedCarolers
        santa = manualSantaStart.map(SantaSchedule.manual(start:)) ?? (season == .eve ? .automatic : .none)
        guard decorationsEnabled || lightsEnabled || santa.active || yeti != nil else {
            decorations = [:]; chimneys = []; target = nil; return
        }
        let eligible = windows.filter { window in
            (window.decoratable || retainedDecorationIDs.contains(window.id)) &&
            window.frame.width >= 210 && window.frame.height >= 90 && (screens.isEmpty || screens.contains { screen in
                window.frame.intersects(screen) && window.frame.maxY >= screen.minY + 2 &&
                    window.frame.maxY <= screen.maxY + ChristmasDrawing.windowStripDrop
            })
        }
        let retained = retainedDecorationIDs.compactMap { id in eligible.first { $0.id == id } }
        let retainedSet = Set(retained.map(\.id))
        let picked = retained + eligible.filter { !retainedSet.contains($0.id) }
            .sorted { Self.hash(UInt64($0.id) ^ seed) < Self.hash(UInt64($1.id) ^ seed) }
        var contents: [UInt32: ChristmasDecoration] = [:]
        for window in picked where decorationsEnabled || lightsEnabled {
            // Identity, rather than the window's current rank, fixes its art.
            // Focusing or opening another window cannot swap its decorations.
            let variant = Int((UInt64(window.id) &+ seed) % UInt64(ChristmasDecoration.Kind.allCases.count))
            let kind = decorationsEnabled ? ChristmasDecoration.Kind(rawValue: variant) : nil
            let extras: [ChristmasDecoration.Kind] = decorationsEnabled ? [
                ChristmasDecoration.Kind.allCases[(variant + 2 + Int(Self.hash(UInt64(window.id) ^ seed &+ 31) % 3)) % ChristmasDecoration.Kind.allCases.count]
            ] + (window.frame.width >= 330 ? [ChristmasDecoration.Kind.allCases[(variant + 5) % ChristmasDecoration.Kind.allCases.count]] : []) : []
            let lights = lightsEnabled
            guard kind != nil || lights else { continue }
            contents[window.id] = ChristmasDecoration(id: window.id,
                kind: kind, extras: extras, lights: lights,
                offset: 0.18 + Self.unit(UInt64(window.id) ^ seed &+ 17) * 0.15)
        }
        let chimneyCandidates = picked.filter { window in
            screens.isEmpty || screens.contains { screen in
                screen.intersects(window.frame) && window.frame.maxY + 110 <= screen.maxY
            }
        }
        // Prefer open sky for Santa, but still dress roofs when every window
        // reaches the top of the display.
        let fallback = picked.filter { window in !chimneyCandidates.contains(where: { $0.id == window.id }) }
        let frontmost = windows.first?.id
        let openSky = Set(chimneyCandidates.map(\.id))
        let exposed = Set(picked.filter { Self.landingVisible(on: $0, in: windows) }.map(\.id))
        let orderedChimneys = (chimneyCandidates + fallback).sorted { a, b in
            let aRank = (a.id == frontmost ? 4 : 0) + (exposed.contains(a.id) ? 0 : 2) + (openSky.contains(a.id) ? 0 : 1)
            let bRank = (b.id == frontmost ? 4 : 0) + (exposed.contains(b.id) ? 0 : 2) + (openSky.contains(b.id) ? 0 : 1)
            return aRank == bRank ? Self.hash(UInt64(a.id) ^ seed) < Self.hash(UInt64(b.id) ^ seed) : aRank < bRank
        }
        // Decorations keep one chimney in place between visits. Santa uses
        // that existing chimney instead of adding a second one on arrival.
        let chimneyID = preferredTarget.flatMap { preferred in
            picked.first(where: { $0.id == preferred })?.id
        } ?? orderedChimneys.first?.id
        let selectedChimneys = decorationsEnabled || santa.active ? chimneyID.map { [$0] } ?? [] : []
        for id in selectedChimneys where contents[id] == nil {
            contents[id] = ChristmasDecoration(id: id, kind: nil, extras: [], lights: false, offset: 0.72)
        }
        if let yeti, yeti.temporaryCarolers, contents[yeti.windowID] == nil {
            contents[yeti.windowID] = ChristmasDecoration(id: yeti.windowID, kind: nil, extras: [], lights: false, offset: 0.5)
        }
        decorations = contents
        chimneys = selectedChimneys
        target = santa.active ? selectedChimneys.first(where: { exposed.contains($0) }) : nil
    }
    func decoration(for id: UInt32) -> ChristmasDecoration? { decorations[id] }
    private func carolerSources() -> [(UInt32, Double)] {
        decorations.keys.sorted().compactMap { id in
            guard let decoration = decorations[id] else { return nil }
            let kinds = decoration.kind.map { [$0] + decoration.extras } ?? []
            guard let index = kinds.enumerated().first(where: { $0.element == .carolers && (!hasChimney(id) || $0.offset < 2) })?.offset else { return nil }
            let fraction = index == 0 ? decoration.offset : index == 1 ? (hasChimney(id) ? 0.49 : 0.68) : 0.86
            return (id, fraction)
        }
    }
    func carolerPlacements(at time: Double) -> [CarolerPlacement] {
        let hosts = decorations.keys.sorted()
        guard !hosts.isEmpty else { return [] }
        return carolerSources().flatMap { source, original in
            guard !consumedCarolers.contains(source), let start = hosts.firstIndex(of: source) else { return [CarolerPlacement]() }
            // Keep the caroler at the Yeti's chosen bite point for the whole encounter.
            if let yeti, !yeti.temporaryCarolers, yeti.windowID == source {
                return [CarolerPlacement(sourceID: source, windowID: source, fraction: yeti.carolerFraction,
                                         stage: .resting, opacity: 1)]
            }
            let elapsed = max(0, time) + Self.unit(UInt64(source) ^ seed &+ 0xCA80) * 1.8
            let cycle = Int(elapsed / 15)
            let phase = elapsed.truncatingRemainder(dividingBy: 15)
            let host = hosts[(start + cycle) % hosts.count]
            let next = hosts[(start + cycle + 1) % hosts.count]
            let homeStart = min(0.66, max(0.20, original))
            let from = host == source ? homeStart : 0.35
            let to = min(0.78, from + 0.30)
            if phase < 3.8 { return [CarolerPlacement(sourceID: source, windowID: host, fraction: from, stage: .resting, opacity: 1)] }
            if phase < 8.2 {
                let progress = (phase - 3.8) / 4.4
                return [CarolerPlacement(sourceID: source, windowID: host, fraction: from + (to - from) * progress, stage: .walking, opacity: 1)]
            }
            if phase < 14.2 { return [CarolerPlacement(sourceID: source, windowID: host, fraction: to, stage: .resting, opacity: 1)] }
            if phase < 14.6 {
                return [CarolerPlacement(sourceID: source, windowID: host, fraction: to, stage: .departing,
                                         opacity: max(0, 1 - (phase - 14.2) / 0.4))]
            }
            return [CarolerPlacement(sourceID: source, windowID: next,
                                     fraction: next == source ? homeStart : 0.35, stage: .arriving,
                                     opacity: min(1, (phase - 14.6) / 0.4))]
        }
    }
    func carolerFraction(for id: UInt32, at time: Double = 0) -> Double? {
        carolerPlacements(at: time).first { $0.sourceID == id && $0.windowID == id && $0.stage == .resting }?.fraction
    }
    func hasChimney(_ id: UInt32) -> Bool { chimneys.contains(id) }
    /// Automatic visits repeat every 45 seconds; manual visits run once.
    func santaPhase(time: Double) -> Double { santa.phase(at: time) }
    static func hash(_ value: UInt64) -> UInt64 {
        var x = value &+ 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        return x ^ (x >> 31)
    }
    static func unit(_ value: UInt64) -> Double { Double(hash(value) >> 11) / 9_007_199_254_740_992 }
}

/// Small transparent textures are drawn at one screen point per pixel. They
/// are cached once and reused by every window and every animation frame.
enum ChristmasPixels {
    static let leadReindeerIndex = 3
    private static let ink = NSColor(calibratedRed: 0.12, green: 0.09, blue: 0.10, alpha: 1).cgColor
    private static let darkRed = NSColor(calibratedRed: 0.48, green: 0.055, blue: 0.065, alpha: 1).cgColor
    private static let red = NSColor(calibratedRed: 0.85, green: 0.11, blue: 0.12, alpha: 1).cgColor
    private static let redLight = NSColor(calibratedRed: 1, green: 0.32, blue: 0.25, alpha: 1).cgColor
    private static let gold = NSColor(calibratedRed: 0.91, green: 0.68, blue: 0.28, alpha: 1).cgColor
    private static let cream = NSColor(calibratedRed: 0.97, green: 0.93, blue: 0.80, alpha: 1).cgColor
    private static let snow = NSColor(calibratedRed: 0.90, green: 0.96, blue: 1, alpha: 1).cgColor
    private static let silver = NSColor(calibratedRed: 0.62, green: 0.72, blue: 0.77, alpha: 1).cgColor
    private static let brown = NSColor(calibratedRed: 0.49, green: 0.29, blue: 0.15, alpha: 1).cgColor
    private static let brownLight = NSColor(calibratedRed: 0.72, green: 0.48, blue: 0.25, alpha: 1).cgColor
    private static let brownDark = NSColor(calibratedRed: 0.27, green: 0.16, blue: 0.12, alpha: 1).cgColor
    private static func texture(_ width: Int, _ height: Int, paint: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setAllowsAntialiasing(false); context.setShouldAntialias(false)
        paint(context)
        return context.makeImage()!
    }
    private static func block(_ c: CGContext, _ color: CGColor, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        c.setFillColor(color); c.fill(CGRect(x: x, y: y, width: w, height: h))
    }
    private static func pixelLine(_ c: CGContext, _ color: CGColor, _ points: [(Int, Int)]) {
        guard let first = points.first else { return }
        c.setStrokeColor(color); c.setLineWidth(2); c.setLineCap(.square); c.setLineJoin(.miter)
        c.move(to: CGPoint(x: Double(first.0) + 0.5, y: Double(first.1) + 0.5))
        for point in points.dropFirst() {
            c.addLine(to: CGPoint(x: Double(point.0) + 0.5, y: Double(point.1) + 0.5))
        }
        c.strokePath()
    }
    static func draw(_ image: CGImage, in c: CGContext, x: Double, y: Double) {
        c.saveGState(); c.interpolationQuality = .none
        c.draw(image, in: CGRect(x: x.rounded(), y: y.rounded(), width: Double(image.width), height: Double(image.height)))
        c.restoreGState()
    }
    static let sleigh: CGImage = texture(55, 27) { c in
        block(c, ink, 1, 2, 52, 2); block(c, silver, 2, 4, 50, 2)
        block(c, silver, 6, 6, 2, 5); block(c, silver, 47, 6, 2, 5)
        block(c, ink, 4, 9, 47, 6); block(c, darkRed, 5, 10, 44, 8)
        block(c, darkRed, 8, 7, 36, 4); block(c, red, 8, 10, 38, 8)
        block(c, red, 11, 18, 37, 4); block(c, redLight, 11, 17, 35, 2)
        block(c, ink, 10, 20, 36, 2); block(c, gold, 11, 20, 34, 1)
        block(c, gold, 47, 12, 3, 7); block(c, redLight, 14, 13, 17, 2)
        block(c, brownDark, 5, 17, 15, 8); block(c, brown, 7, 19, 12, 6)
        block(c, brownLight, 9, 22, 8, 2); block(c, gold, 12, 24, 3, 2)
        for x in stride(from: 9, through: 44, by: 7) { block(c, gold, x, 11, 2, 2) }
    }
    static let reindeer: [[CGImage]] = (0..<4).map { animal in (0..<2).map { pose in texture(43, 37) { c in
        // Separate leg frames give each animal its own gallop phase.
        let front = pose == 0 ? 4 : 9, rear = pose == 0 ? 9 : 4
        block(c, brownDark, 10, rear, 3, 12 - rear); block(c, brownDark, 27, front, 3, 13 - front)
        block(c, brown, 12, rear + 1, 2, 11 - rear); block(c, brown, 28, front + 1, 2, 12 - front)
        block(c, ink, 8, rear - 1, 6, 2); block(c, ink, 26, front - 1, 6, 2)
        block(c, brownDark, 7, 13, 25, 11); block(c, brown, 9, 15, 23, 9)
        block(c, brownLight, 11, 21, 17, 2); block(c, brownLight, 14, 16, 11, 2)
        if animal == 1 { block(c, cream, 15, 17, 7, 2); block(c, brownDark, 23, 21, 3, 2) }
        if animal == 2 { block(c, brownLight, 10, 17, 7, 5); block(c, cream, 27, 18, 4, 3) }
        if animal == 3 { block(c, brownDark, 13, 18, 8, 3); block(c, cream, 22, 16, 5, 2) }
        block(c, brownDark, 29, 20, 6, 8); block(c, brown, 31, 22, 6, 8)
        block(c, brownDark, 31, 27, 10, 6); block(c, brownLight, 33, 29, 8, 3)
        block(c, brownLight, 36, 32, 3, 2); block(c, ink, 37, 30, 2, 2)
        block(c, cream, 39, 27, 4, 2); block(c, ink, 40, 27, 2, 1)
        block(c, brownLight, 4, 22, 6, 3); block(c, brownDark, 2, 24, 4, 2)
        // A little branching silhouette makes the antlers legible at tiny size.
        block(c, brownDark, 33, 33, 2, 4); block(c, brownDark, 27, 35, 8, 2)
        block(c, brownDark, 29, 32, 2, 4); block(c, brownDark, 35, 34, 4, 2)
        block(c, brownDark, 37, 32, 2, 3)
        if animal == leadReindeerIndex { block(c, redLight, 39, 28, 3, 2) }
    } } }
    static let chimney: CGImage = texture(34, 48) { c in
        block(c, ink, 3, 0, 28, 43); block(c, darkRed, 5, 1, 24, 42)
        for row in 0..<5 {
            let y = 4 + row * 8
            block(c, brownDark, 5, y, 24, 1)
            let seam = row % 2 == 0 ? 13 : 20
            block(c, brownDark, seam, y + 1, 1, 7)
            block(c, red, 6, y + 2, 4, 2); block(c, redLight, 22, y + 3, 4, 1)
        }
        block(c, ink, 0, 39, 34, 6); block(c, darkRed, 1, 40, 32, 5)
        block(c, red, 2, 42, 30, 2); block(c, ink, 7, 44, 20, 4)
        block(c, snow, 1, 45, 8, 3); block(c, snow, 27, 45, 6, 3)
        block(c, cream, 2, 47, 5, 1); block(c, cream, 28, 47, 4, 1)
    }
    static let gifts: [CGImage] = (0..<12).map { variant in
        let sizes = [(14, 14), (28, 16), (16, 25), (23, 21), (31, 18), (12, 12),
                     (21, 27), (29, 13), (18, 23), (26, 24), (19, 16), (25, 19)]
        let (width, height) = sizes[variant]
        return texture(width, height) { c in
            let wraps: [CGColor] = [red, NSColor(calibratedRed: 0.11, green: 0.52, blue: 0.28, alpha: 1).cgColor,
                                    NSColor(calibratedRed: 0.22, green: 0.46, blue: 0.80, alpha: 1).cgColor,
                                    NSColor(calibratedRed: 0.59, green: 0.30, blue: 0.70, alpha: 1).cgColor,
                                    gold, NSColor(calibratedRed: 0.98, green: 0.48, blue: 0.23, alpha: 1).cgColor]
            let ribbons: [CGColor] = [gold, cream, redLight, silver, cream, brownDark]
            let wrap = wraps[variant % wraps.count], ribbon = ribbons[(variant * 3 + 1) % ribbons.count]
            let bodyTop = height - 5, rounded = variant % 4 == 2
            if rounded {
                block(c, ink, 3, 1, width - 6, bodyTop - 1)
                block(c, ink, 1, 3, width - 2, bodyTop - 4)
                block(c, wrap, 3, 2, width - 6, bodyTop - 3)
                block(c, wrap, 2, 4, width - 4, bodyTop - 6)
            } else {
                block(c, ink, 1, 1, width - 2, bodyTop)
                block(c, wrap, 2, 2, width - 4, bodyTop - 2)
            }
            block(c, brownDark, width - 4, 2, 2, max(2, bodyTop - 2))
            block(c, ink, 0, bodyTop - 1, width, 3)
            block(c, wrap, 1, bodyTop, width - 2, 2)
            let middle = width / 2
            block(c, ribbon, middle - 1, 2, 3, bodyTop + 1)
            if variant % 3 != 1 { block(c, ribbon, 2, max(3, bodyTop / 2), width - 4, 2) }
            if variant % 3 == 0 {
                for x in stride(from: 4, to: width - 3, by: 5) {
                    block(c, cream, x, 4 + x % max(2, bodyTop - 7), 2, 2)
                }
            } else if variant % 3 == 1 {
                for x in stride(from: 4, to: width - 3, by: 6) {
                    block(c, redLight, x, 3, 2, max(2, bodyTop - 5))
                }
            } else {
                block(c, cream, 3, bodyTop - 4, 3, 2)
                block(c, cream, width - 6, 4, 2, 2)
            }
            // Oversized, asymmetrical bow loops make the tiny packages read as gifts.
            block(c, ink, middle - 6, height - 4, 5, 3)
            block(c, ink, middle + 2, height - 3, 5, 2)
            block(c, ribbon, middle - 5, height - 3, 4, 2)
            block(c, ribbon, middle + 2, height - 2, 4, 1)
            block(c, cream, middle, height - 4, 2, 3)
            block(c, redLight, 2, bodyTop, min(4, width - 4), 1)
        }
    }
    static let candyCane: CGImage = texture(20, 33) { c in
        block(c, ink, 2, 1, 7, 24); block(c, snow, 3, 2, 5, 23)
        block(c, ink, 4, 24, 6, 7); block(c, snow, 6, 25, 5, 6)
        block(c, ink, 10, 28, 6, 5); block(c, snow, 10, 29, 5, 3)
        block(c, ink, 15, 24, 4, 6); block(c, snow, 15, 25, 3, 4)
        for y in stride(from: 3, through: 22, by: 6) {
            block(c, red, 3, y, 5, 3); block(c, redLight, 3, y + 2, 2, 1)
        }
        block(c, red, 5, 26, 4, 3); block(c, red, 10, 29, 4, 2)
        block(c, red, 16, 25, 2, 3); block(c, cream, 4, 5, 1, 17)
    }
    static let gingerbreadHouses: [CGImage] = (0..<4).map { style in texture(38, 35) { c in
        let walls = [brown, brownLight, brownDark, brown][style]
        let sweets = [redLight, gold, silver, red][style]
        block(c, ink, 3, 1, 32, 22); block(c, walls, 4, 2, 30, 20)
        for step in 0..<10 {
            block(c, ink, step + 1, 21 + step, 36 - step * 2, 2)
            block(c, brown, step + 2, 22 + step, 34 - step * 2, 1)
            if step % 3 == 0 { block(c, snow, step + 1, 23 + step, 36 - step * 2, 1) }
        }
        block(c, snow, 0, 21, 38, 3)
        block(c, ink, 14, 2, 10, 14); block(c, [red, darkRed, brownDark, redLight][style], 15, 2, 8, 13)
        block(c, cream, 15, 15, 8, 2); block(c, gold, 20, 7, 2, 2)
        for x in [6, 27] {
            block(c, cream, x, 11, 6, 7); block(c, NSColor(calibratedRed: 0.95, green: 0.77, blue: 0.30, alpha: 1).cgColor, x + 1, 12, 4, 5)
            block(c, walls, x + 2, 12, 1, 5); block(c, walls, x + 1, 14, 4, 1)
        }
        for x in stride(from: 4, through: 32, by: 7) { block(c, sweets, x, 22, 3, 3) }
        block(c, snow, 6, 3, 5, 2); block(c, snow, 27, 4, 5, 2)
    } }
    static let toyTrains: [CGImage] = (0..<4).map { style in texture(47, 27) { c in
        let paint = [red, NSColor(calibratedRed: 0.15, green: 0.46, blue: 0.25, alpha: 1).cgColor,
                     NSColor(calibratedRed: 0.17, green: 0.40, blue: 0.70, alpha: 1).cgColor, gold][style]
        block(c, ink, 0, 3, 47, 2); block(c, silver, 1, 5, 45, 1)
        block(c, ink, 2, 7, 29, 12); block(c, paint, 3, 8, 27, 10)
        block(c, ink, 5, 17, 12, 8); block(c, paint, 6, 18, 10, 6)
        block(c, cream, 8, 19, 5, 4); block(c, ink, 22, 18, 5, 8); block(c, silver, 23, 20, 3, 5)
        block(c, ink, 32, 8, 13, 10); block(c, brownLight, 33, 9, 11, 8)
        block(c, paint, 35, 16, 8, 2); block(c, gold, 37, 11, 2, 6)
        block(c, ink, 29, 10, 4, 2); block(c, gold, 29, 11, 4, 1)
        for x in [7, 22, 35, 43] {
            block(c, ink, x - 2, 3, 6, 6); block(c, silver, x - 1, 4, 4, 4); block(c, ink, x, 5, 2, 2)
        }
        block(c, gold, 2, 11, 3, 4); block(c, cream, 2, 13, 2, 2)
        if style % 2 == 0 { block(c, snow, 18, 24, 6, 2); block(c, silver, 20, 26, 3, 1) }
    } }
    static let lanternPairs: [CGImage] = (0..<4).map { style in texture(39, 35) { c in
        let metal = [darkRed, brownDark, NSColor(calibratedRed: 0.05, green: 0.29, blue: 0.16, alpha: 1).cgColor, brown][style]
        for (x, height) in [(3, 27), (25, 21 + style % 3 * 2)] {
            block(c, ink, x + 6, 0, 2, height)
            block(c, metal, x + 5, 1, 4, height - 3)
            block(c, ink, x + 1, height - 13, 12, 13)
            block(c, gold, x + 3, height - 11, 8, 9)
            block(c, cream, x + 5, height - 9, 4, 6)
            block(c, metal, x + 1, height - 13, 2, 13)
            block(c, metal, x + 11, height - 13, 2, 13)
            block(c, metal, x + 2, height, 10, 2)
            block(c, snow, x + 2, height + 2, 9, 2)
        }
        block(c, red, 18, 4, 3, 3); block(c, NSColor(calibratedRed: 0.07, green: 0.42, blue: 0.16, alpha: 1).cgColor, 19, 7, 2, 3)
    } }
    static let wreaths: [CGImage] = (0..<4).map { style in texture(34, 35) { c in
        let foliage = [NSColor(calibratedRed: 0.03, green: 0.34, blue: 0.12, alpha: 1).cgColor,
                       NSColor(calibratedRed: 0.04, green: 0.42, blue: 0.18, alpha: 1).cgColor,
                       NSColor(calibratedRed: 0.09, green: 0.28, blue: 0.16, alpha: 1).cgColor,
                       NSColor(calibratedRed: 0.08, green: 0.37, blue: 0.12, alpha: 1).cgColor][style]
        block(c, brownDark, 15, 1, 4, 14); block(c, brown, 10, 1, 14, 2)
        block(c, ink, 5, 15, 24, 16); block(c, ink, 8, 12, 18, 22)
        block(c, foliage, 6, 16, 22, 14); block(c, foliage, 9, 13, 16, 20)
        c.clear(CGRect(x: 13, y: 19, width: 8, height: 9))
        block(c, [red, gold, redLight, cream][style], 12, 13, 10, 4)
        block(c, [redLight, cream, red, gold][style], 16, 11, 3, 8)
        for (x, y) in [(8, 21), (23, 25), (11, 30), (25, 18)] {
            block(c, style % 2 == 0 ? red : gold, x, y, 3, 3)
        }
        block(c, snow, 9, 31, 5, 2); block(c, snow, 21, 29, 4, 2)
    } }
    static let nutcrackers: [CGImage] = (0..<4).map { style in texture(26, 45) { c in
        let coat = [red, NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.65, alpha: 1).cgColor,
                    NSColor(calibratedRed: 0.13, green: 0.45, blue: 0.26, alpha: 1).cgColor, darkRed][style]
        block(c, ink, 5, 0, 6, 4); block(c, ink, 15, 0, 6, 4)
        block(c, brownDark, 6, 3, 4, 11); block(c, brownDark, 16, 3, 4, 11)
        block(c, ink, 3, 13, 20, 18); block(c, coat, 4, 14, 18, 16)
        block(c, gold, 11, 14, 4, 16); block(c, ink, 1, 15, 4, 13); block(c, ink, 21, 15, 4, 13)
        block(c, coat, 2, 17, 3, 9); block(c, coat, 21, 17, 3, 9)
        block(c, cream, 2, 13, 3, 4); block(c, cream, 21, 13, 3, 4)
        block(c, ink, 5, 29, 16, 10); block(c, cream, 6, 30, 14, 8)
        block(c, ink, 8, 34, 3, 2); block(c, ink, 16, 34, 3, 2)
        block(c, ink, 9, 29, 8, 3); block(c, snow, 10, 30, 6, 2)
        block(c, ink, 4, 38, 18, 6); block(c, [darkRed, brownDark, ink, red][style], 5, 39, 16, 4)
        block(c, gold, 5, 42, 16, 2); block(c, gold, 11, 22, 4, 2)
        if style % 2 == 0 { block(c, snow, 8, 44, 10, 1) }
    } }
    static let rockingHorses: [CGImage] = (0..<4).map { style in texture(45, 31) { c in
        let hide = [brownLight, cream, brown, silver][style]
        pixelLine(c, ink, [(2, 6), (8, 3), (36, 3), (42, 6)])
        pixelLine(c, brown, [(3, 7), (10, 4), (35, 4), (41, 7)])
        block(c, ink, 12, 7, 3, 8); block(c, ink, 32, 7, 3, 8)
        block(c, ink, 9, 14, 28, 13); block(c, hide, 10, 15, 26, 11)
        block(c, ink, 5, 22, 10, 8); block(c, hide, 6, 23, 8, 6)
        block(c, ink, 3, 20, 8, 3); block(c, hide, 4, 21, 6, 2)
        block(c, ink, 8, 26, 3, 3); block(c, ink, 35, 23, 5, 5)
        block(c, [red, darkRed, NSColor(calibratedRed: 0.13, green: 0.39, blue: 0.26, alpha: 1).cgColor, gold][style], 17, 21, 13, 5)
        block(c, gold, 17, 25, 13, 1); block(c, ink, 10, 26, 2, 2)
        block(c, cream, 10, 27, 2, 1)
        pixelLine(c, darkRed, [(35, 25), (40, 20), (39, 17)])
    } }
    static let snowGlobes: [CGImage] = (0..<4).map { style in texture(36, 36) { c in
        let sky = [NSColor(calibratedRed: 0.36, green: 0.67, blue: 0.82, alpha: 1).cgColor,
                   NSColor(calibratedRed: 0.23, green: 0.45, blue: 0.73, alpha: 1).cgColor,
                   NSColor(calibratedRed: 0.53, green: 0.71, blue: 0.88, alpha: 1).cgColor,
                   NSColor(calibratedRed: 0.28, green: 0.57, blue: 0.68, alpha: 1).cgColor][style]
        block(c, ink, 7, 1, 22, 5); block(c, brownDark, 8, 2, 20, 3)
        block(c, gold, 9, 5, 18, 2)
        block(c, ink, 11, 7, 14, 2); block(c, ink, 8, 9, 20, 3)
        block(c, ink, 6, 12, 24, 15); block(c, ink, 8, 27, 20, 3)
        block(c, ink, 11, 30, 14, 3)
        block(c, sky, 12, 8, 12, 2); block(c, sky, 9, 10, 18, 3)
        block(c, sky, 7, 13, 22, 14); block(c, sky, 9, 27, 18, 3)
        block(c, sky, 12, 30, 12, 2)
        block(c, snow, 9, 10, 18, 5); block(c, silver, 8, 14, 3, 9)
        block(c, brown, 16, 15, 4, 6)
        for row in 0..<3 { block(c, [NSColor(calibratedRed: 0.05, green: 0.35, blue: 0.19, alpha: 1).cgColor,
                                   NSColor(calibratedRed: 0.04, green: 0.42, blue: 0.19, alpha: 1).cgColor][style % 2], 12 + row * 2, 20 + row * 3, 12 - row * 4, 4) }
        block(c, gold, 17, 30, 2, 3)
        for (x, y) in [(11, 19), (24, 21), (22, 27)] { block(c, snow, x + style % 2, y, 2, 2) }
        block(c, cream, 11, 3, 14, 1)
    } }
    static let holidayMailboxes: [CGImage] = (0..<4).map { style in texture(38, 35) { c in
        let metal = [red, darkRed, NSColor(calibratedRed: 0.06, green: 0.36, blue: 0.19, alpha: 1).cgColor,
                     NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.59, alpha: 1).cgColor][style]
        block(c, ink, 16, 0, 5, 11); block(c, brownDark, 17, 1, 3, 9)
        block(c, ink, 3, 10, 32, 17); block(c, ink, 7, 25, 24, 6)
        block(c, metal, 4, 11, 30, 15); block(c, metal, 8, 26, 22, 4)
        block(c, darkRed, 5, 11, 8, 15); block(c, ink, 11, 15, 2, 10)
        block(c, snow, 6, 29, 26, 3); block(c, snow, 3, 26, 32, 3)
        block(c, cream, 18, 16, 10, 7); block(c, gold, 20, 18, 6, 2)
        block(c, ink, 31, 22, 3, 12); block(c, [redLight, gold, cream, redLight][style], 27, 30, 7, 3)
        block(c, cream, 7, 19, 4, 3)
    } }
    private struct YetiLimbFrame {
        let leftElbow: (Int, Int), leftWrist: (Int, Int)
        let rightElbow: (Int, Int), rightWrist: (Int, Int)
        let leftKnee: (Int, Int), leftFoot: (Int, Int)
        let rightKnee: (Int, Int), rightFoot: (Int, Int)
    }
    private static let yetiLimbFrames: [YetiLimbFrame] = [
        YetiLimbFrame(leftElbow: (10, 60), leftWrist: (5, 72), rightElbow: (56, 59), rightWrist: (62, 71),
                      leftKnee: (21, 8), leftFoot: (13, 1), rightKnee: (45, 9), rightFoot: (53, 1)),
        YetiLimbFrame(leftElbow: (11, 36), leftWrist: (8, 22), rightElbow: (55, 63), rightWrist: (62, 77),
                      leftKnee: (15, 15), leftFoot: (8, 10), rightKnee: (43, 7), rightFoot: (48, 1)),
        YetiLimbFrame(leftElbow: (10, 49), leftWrist: (2, 43), rightElbow: (55, 39), rightWrist: (60, 22),
                      leftKnee: (25, 8), leftFoot: (28, 1), rightKnee: (51, 15), rightFoot: (61, 11)),
        YetiLimbFrame(leftElbow: (11, 64), leftWrist: (3, 78), rightElbow: (56, 51), rightWrist: (64, 47),
                      leftKnee: (21, 8), leftFoot: (12, 1), rightKnee: (47, 16), rightFoot: (54, 11)),
        YetiLimbFrame(leftElbow: (10, 30), leftWrist: (4, 18), rightElbow: (55, 66), rightWrist: (62, 79),
                      leftKnee: (12, 15), leftFoot: (5, 10), rightKnee: (47, 7), rightFoot: (52, 1)),
        YetiLimbFrame(leftElbow: (8, 53), leftWrist: (1, 57), rightElbow: (56, 35), rightWrist: (63, 27),
                      leftKnee: (19, 6), leftFoot: (11, 1), rightKnee: (50, 13), rightFoot: (59, 7)),
        YetiLimbFrame(leftElbow: (10, 47), leftWrist: (2, 42), rightElbow: (56, 50), rightWrist: (64, 47),
                      leftKnee: (22, 8), leftFoot: (15, 2), rightKnee: (48, 13), rightFoot: (57, 7)),
        YetiLimbFrame(leftElbow: (12, 60), leftWrist: (5, 70), rightElbow: (55, 40), rightWrist: (64, 35),
                      leftKnee: (18, 12), leftFoot: (10, 7), rightKnee: (44, 7), rightFoot: (49, 1))
    ]
    static let yeti: [CGImage] = yetiLimbFrames.map { frame in texture(66, 82) { c in
        // A small, sharply stepped version of the raised-arm figure in the
        // reference: twig fingers, a square dark face, and a plain grey belly.
        let black = NSColor(calibratedWhite: 0.025, alpha: 1).cgColor
        let grey = NSColor(calibratedWhite: 0.73, alpha: 1).cgColor
        let face = NSColor(calibratedWhite: 0.29, alpha: 1).cgColor
        let redEye = NSColor(calibratedRed: 0.96, green: 0.12, blue: 0.12, alpha: 1).cgColor
        let teeth = NSColor(calibratedRed: 1, green: 0.94, blue: 0.08, alpha: 1).cgColor
        // The torso stays recognizable while independently drawn limbs snap
        // between high-kick, planted, raised-claw, and low-swing silhouettes.
        for (hip, knee, foot) in [((25, 18), frame.leftKnee, frame.leftFoot),
                                  ((42, 18), frame.rightKnee, frame.rightFoot)] {
            pixelLine(c, black, [hip, knee, foot])
            for toe in [-5, 0, 5] {
                pixelLine(c, black, [foot, (foot.0 + toe, max(0, foot.1 - 2 + (toe == 0 ? 1 : 0)))])
            }
        }

        let body = CGMutablePath()
        body.move(to: CGPoint(x: 22, y: 51))
        for point in [CGPoint(x: 18, y: 45), CGPoint(x: 18, y: 28), CGPoint(x: 21, y: 20),
                      CGPoint(x: 27, y: 15), CGPoint(x: 39, y: 15), CGPoint(x: 46, y: 22),
                      CGPoint(x: 48, y: 30), CGPoint(x: 48, y: 45), CGPoint(x: 44, y: 51)] {
            body.addLine(to: point)
        }
        body.closeSubpath()
        c.addPath(body); c.setFillColor(grey); c.fillPath()
        c.addPath(body); c.setStrokeColor(black); c.setLineWidth(2); c.strokePath()

        for (shoulder, elbow, wrist) in [((20, 47), frame.leftElbow, frame.leftWrist),
                                         ((46, 47), frame.rightElbow, frame.rightWrist)] {
            pixelLine(c, black, [shoulder, elbow, wrist])
            let up = wrist.1 >= 47 ? 1 : -1
            for finger in [-4, 0, 4] {
                pixelLine(c, black, [wrist, (wrist.0 + finger, wrist.1 + up * (finger == 0 ? 6 : 4))])
            }
        }

        block(c, black, 24, 52, 19, 22)
        block(c, face, 26, 54, 15, 17)
        block(c, black, 26, 70, 3, 3); block(c, black, 38, 70, 3, 3)
        pixelLine(c, black, [(27, 69), (31, 65), (34, 65)])
        pixelLine(c, black, [(40, 69), (36, 65), (33, 65)])
        block(c, redEye, 29, 63, 3, 3); block(c, redEye, 36, 63, 3, 3)
        block(c, black, 27, 54, 13, 7)
        block(c, teeth, 29, 55, 3, 5); block(c, teeth, 35, 55, 3, 5)
        block(c, black, 32, 55, 3, 3)
    } }
}

/// A continuous contact–passing–contact cycle. One foot stays planted while
/// the other lifts and crosses underneath the body, then they trade roles.
struct StickWalkPose {
    let leftFootX: Double, rightFootX: Double
    let leftLift: Double, rightLift: Double
    let hipBob: Double, armSwing: Double
    static func at(_ phase: Double, stride: Double, walking: Bool) -> StickWalkPose {
        guard walking else {
            return StickWalkPose(leftFootX: -5, rightFootX: 5, leftLift: 0, rightLift: 0,
                                 hipBob: 0, armSwing: 0)
        }
        let passing = sin(phase), reach = cos(phase)
        return StickWalkPose(leftFootX: -stride * reach, rightFootX: stride * reach,
                             leftLift: max(0, passing) * 2.8,
                             rightLift: max(0, -passing) * 2.8,
                             hipBob: abs(passing) * 0.75,
                             armSwing: reach * min(5, stride * 0.78))
    }
}

/// Santa uses the same planted-foot walk cycle as the carolers. The joint
/// positions at the ends of each action match the next action, so boarding
/// and chimney work do not snap back to a straight-legged pose.
struct SantaArticulation {
    let gait: StickWalkPose
    let crouch: Double
    let lean: Double
    let handLift: Double
    let handReach: Double

    private static func ease(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
    private static func board(_ progress: Double) -> SantaArticulation {
        let p = ease(progress), step = sin(.pi * p)
        return SantaArticulation(
            gait: StickWalkPose(leftFootX: -5 - 1.5 * p - 2 * step,
                                rightFootX: 5 + 1.5 * p + 4 * step,
                                leftLift: 6 * (1 - p) + 2 * step,
                                rightLift: 6 * (1 - p) + 8 * step,
                                hipBob: step * 0.8, armSwing: 2 * step),
            crouch: 4 * (1 - p) + 1.5 * step,
            lean: 1.5 * (1 - p) + 2 * step,
            handLift: 2 * (1 - p) + 3 * step,
            handReach: 1.5 * (1 - p) + 2 * step)
    }
    private static func walking(_ progress: Double, stride: Double = 6.5) -> SantaArticulation {
        let p = ease(progress)
        return SantaArticulation(gait: StickWalkPose.at(p * 2 * .pi, stride: stride, walking: true),
                                 crouch: 0, lean: 0, handLift: 0, handReach: 0)
    }
    private static func climbing(_ progress: Double, leavingRoof: Bool) -> SantaArticulation {
        let p = ease(progress)
        let stride = leavingRoof ? 6.5 - 2 * p : 4.5 + 2 * p
        let gait = StickWalkPose.at(p * 2 * .pi, stride: stride, walking: true)
        let grip = leavingRoof ? p : 1 - p
        return SantaArticulation(
            gait: StickWalkPose(leftFootX: gait.leftFootX, rightFootX: gait.rightFootX,
                                leftLift: gait.leftLift * (1 + grip), rightLift: gait.rightLift * (1 + grip),
                                hipBob: gait.hipBob, armSwing: gait.armSwing * 0.45),
            crouch: 1.5 * sin(.pi * p), lean: 1.5 * sin(.pi * p),
            handLift: 16 * grip, handReach: 2.5 * grip)
    }
    private static func inChimney(_ progress: Double) -> SantaArticulation {
        let p = ease(progress)
        let gait = StickWalkPose.at(p * 2 * .pi, stride: 4.5, walking: true)
        return SantaArticulation(
            gait: StickWalkPose(leftFootX: gait.leftFootX, rightFootX: gait.rightFootX,
                                leftLift: gait.leftLift * 2, rightLift: gait.rightLift * 2,
                                hipBob: gait.hipBob, armSwing: gait.armSwing * 0.45),
            crouch: 0, lean: 0, handLift: 16, handReach: 2.5)
    }
    static func at(_ phase: Double) -> SantaArticulation {
        if phase < 9.4 { return board(0) }
        if phase < 10.6 { return board((phase - 9.4) / 1.2) }
        if phase < 12 { return walking((phase - 10.6) / 1.4) }
        if phase < 13.2 { return climbing((phase - 12) / 1.2, leavingRoof: true) }
        if phase < 14.4 { return inChimney((phase - 13.2) / 1.2) }
        if phase < 16 { return inChimney(1) }
        if phase < 17.2 { return inChimney((phase - 16) / 1.2) }
        if phase < 18.8 {
            let progress = (phase - 17.2) / 1.6
            return progress < 0.35 ? climbing(progress / 0.35, leavingRoof: false) :
                walking((progress - 0.35) / 0.65)
        }
        if phase < 19.5 { return board(1 - (phase - 18.8) / 0.7) }
        return board(0)
    }
}

/// Native vector details are intentionally tiny so every eligible window can be decorated.
enum ChristmasDrawing {
    static let windowStripDrop = 34.0
    private static func stroke(_ context: CGContext, _ color: NSColor, _ width: Double = 1.3) {
        context.setStrokeColor(color.cgColor); context.setLineWidth(width); context.setLineCap(.round); context.setLineJoin(.round)
    }
    private static func fill(_ context: CGContext, _ color: NSColor) { context.setFillColor(color.cgColor) }
    private static func line(_ context: CGContext, _ a: CGPoint, _ b: CGPoint) {
        context.move(to: a); context.addLine(to: b); context.strokePath()
    }
    private static func figure(_ c: CGContext, x: Double, y: Double, coat: NSColor, motion: Double,
                               singing: Bool = false, walking: Bool = true, stride: Double = 6.5,
                               bookMotion: Double? = nil, santaMotion: SantaArticulation? = nil,
                               carryingGift: Bool = false) {
        let pose = santaMotion?.gait ?? StickWalkPose.at(motion, stride: stride, walking: walking)
        let pageMotion = bookMotion ?? motion
        let sway = walking ? sin(motion) * 0.55 : 0
        let crouch = santaMotion?.crouch ?? 0
        let lean = santaMotion?.lean ?? 0
        let handLift = santaMotion?.handLift ?? 0
        let handReach = santaMotion?.handReach ?? 0
        let hip = CGPoint(x: x, y: y + 14 + pose.hipBob - crouch * 0.45)
        let shoulder = CGPoint(x: x - 0.4 + sway + lean, y: y + 27 + pose.hipBob - crouch)
        let leftFoot = CGPoint(x: x + pose.leftFootX, y: y + pose.leftLift)
        let rightFoot = CGPoint(x: x + pose.rightFootX, y: y + pose.rightLift)
        let leftKnee = CGPoint(x: x + pose.leftFootX * 0.52 + pose.leftLift * 0.45,
                               y: y + 7 + pose.hipBob * 0.5 + pose.leftLift * 0.5)
        let rightKnee = CGPoint(x: x + pose.rightFootX * 0.52 + pose.rightLift * 0.45,
                                y: y + 7 + pose.hipBob * 0.5 + pose.rightLift * 0.5)
        let leftElbow = CGPoint(x: x - 4 + pose.armSwing * 0.35,
                                y: y + 21 + pose.hipBob - crouch * 0.5 + handLift * 0.45)
        let rightElbow = CGPoint(x: x + 4 - pose.armSwing * 0.35,
                                 y: y + 21 + pose.hipBob - crouch * 0.5 + handLift * 0.45)
        let giftCenter = CGPoint(x: x + lean, y: y + 20 + pose.hipBob - crouch * 0.45)
        let leftHand = carryingGift ? CGPoint(x: giftCenter.x - 5, y: giftCenter.y) :
            CGPoint(x: x - 7 - handReach + pose.armSwing, y: y + 17 + pose.hipBob + handLift)
        let rightHand = carryingGift ? CGPoint(x: giftCenter.x + 5, y: giftCenter.y) :
            singing ? CGPoint(x: x + 6 - pose.armSwing * 0.2,
                                          y: y + 21 + pose.hipBob + sin(pageMotion * 0.7) * 0.7) :
            CGPoint(x: x + 7 + handReach - pose.armSwing, y: y + 17 + pose.hipBob + handLift)
        let outline = NSColor(calibratedWhite: 0.075, alpha: 1)
        stroke(c, outline, 3.1)
        for (a, b) in [(hip, leftKnee), (leftKnee, leftFoot), (hip, rightKnee), (rightKnee, rightFoot)] { line(c, a, b) }
        stroke(c, coat, 2.5)
        line(c, hip, shoulder)
        for (a, b) in [(shoulder, leftElbow), (leftElbow, leftHand), (shoulder, rightElbow), (rightElbow, rightHand)] { line(c, a, b) }
        fill(c, outline)
        for joint in [hip, shoulder, leftKnee, rightKnee, leftElbow, rightElbow] {
            c.fillEllipse(in: CGRect(x: joint.x - 1.4, y: joint.y - 1.4, width: 2.8, height: 2.8))
        }
        if carryingGift {
            let gift = ChristmasPixels.gifts[5]
            ChristmasPixels.draw(gift, in: c, x: giftCenter.x - Double(gift.width) * 0.5,
                                 y: giftCenter.y - Double(gift.height) * 0.5)
            fill(c, .white)
            c.fillEllipse(in: CGRect(x: leftHand.x - 2, y: leftHand.y - 1.5, width: 3, height: 3))
            c.fillEllipse(in: CGRect(x: rightHand.x - 1, y: rightHand.y - 1.5, width: 3, height: 3))
        }
        fill(c, NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.68, alpha: 1))
        let headX = x + sway + lean, headY = y + 29 + pose.hipBob - crouch
        c.fillEllipse(in: CGRect(x: headX - 4.1, y: headY, width: 8.2, height: 8.2))
        stroke(c, outline, 0.85); c.strokeEllipse(in: CGRect(x: headX - 4.1, y: headY, width: 8.2, height: 8.2))
        fill(c, outline); c.fillEllipse(in: CGRect(x: headX + 1.1, y: headY + 4, width: 0.9, height: 1.2))
        if singing {
            c.fillEllipse(in: CGRect(x: headX + 1, y: headY + 1.5, width: 1.4, height: 1.6))
            fill(c, NSColor(calibratedWhite: 0.94, alpha: 1))
            c.saveGState()
            c.translateBy(x: rightHand.x + 0.5, y: rightHand.y + 0.5)
            c.rotate(by: sin(pageMotion * 0.7 + x) * (walking ? 0.09 : 0.18))
            c.fill(CGRect(x: -3.5, y: -3.5, width: 7, height: 7))
            stroke(c, outline, 0.7)
            line(c, CGPoint(x: 0, y: -3.5), CGPoint(x: 0, y: 3.5))
            c.restoreGState()
        }
    }
    #if TESTING
    static func walkFigure(in c: CGContext, x: Double, y: Double, phase: Double, singing: Bool) {
        figure(c, x: x, y: y, coat: singing ? .systemBlue : .systemRed,
               motion: phase, singing: singing, walking: true, stride: singing ? 6.2 : 6.5)
    }
    #endif
    static func window(_ window: SnowStormWindow, decoration: ChristmasDecoration, chimney: Bool,
                       time: Double, scene: ChristmasScene, in context: CGContext, origin: CGPoint) {
        let roof = window.frame.maxY - origin.y, left = window.frame.minX - origin.x, width = window.frame.width
        context.saveGState()
        if decoration.lights { lights(window: window, roof: roof, left: left, time: time, scene: scene, in: context) }
        let kinds = decoration.kind.map { [$0] + decoration.extras } ?? []
        let encounter = scene.yeti?.windowID == window.id ? scene.yeti : nil
        let taken = scene.consumedCarolers.contains(window.id) ||
            encounter.map { $0.phase(at: time) >= YetiEncounter.biteTime } == true
        for (index, kind) in kinds.enumerated() where !chimney || index < 2 {
            let offset = index == 0 ? decoration.offset : index == 1 ? (chimney ? 0.49 : 0.68) : 0.86
            let x = left + width * offset, y = roof + 3
            let style = Int(ChristmasScene.hash(UInt64(window.id) ^ scene.seed &+ UInt64(index + 1) &* 73) % 4)
            switch kind {
            case .tree: tree(context, x: x, y: y, style: style)
            case .presents: presents(context, x: x, y: y, variant: Int(window.id) + index + Int(scene.seed % 12))
            case .snowman: snowman(context, x: x, y: y, style: style)
            case .carolers: break // The group walks between windows below.
            case .candyCanes: candyCanes(context, x: x, y: y, style: style)
            case .northPoleSign: northPoleSign(context, x: x, y: y, style: style)
            case .mistletoe: mistletoe(context, x: x, y: y, style: style)
            case .gingerbreadHouse: pixelDecoration(context, ChristmasPixels.gingerbreadHouses[style], x: x, y: y)
            case .toyTrain: pixelDecoration(context, ChristmasPixels.toyTrains[style], x: x, y: y)
            case .lanterns: pixelDecoration(context, ChristmasPixels.lanternPairs[style], x: x, y: y)
            case .wreath: pixelDecoration(context, ChristmasPixels.wreaths[style], x: x, y: y)
            case .nutcracker: pixelDecoration(context, ChristmasPixels.nutcrackers[style], x: x, y: y)
            case .rockingHorse: pixelDecoration(context, ChristmasPixels.rockingHorses[style], x: x, y: y)
            case .snowGlobe: pixelDecoration(context, ChristmasPixels.snowGlobes[style], x: x, y: y)
            case .holidayMailbox: pixelDecoration(context, ChristmasPixels.holidayMailboxes[style], x: x, y: y)
            }
        }
        for placement in scene.carolerPlacements(at: time) where placement.windowID == window.id {
            let x = left + width * placement.fraction, y = roof + 3
            let clock = max(0, time) + ChristmasScene.unit(UInt64(placement.sourceID) ^ scene.seed &+ 0xCA80) * 1.8
            let walkSeconds = max(0, min(4.4, clock.truncatingRemainder(dividingBy: 15) - 3.8))
            let cycles = max(2, min(8, Int((width * 0.3 / 24).rounded())))
            context.saveGState()
            context.setAlpha(placement.opacity)
            carolers(context, x: x, y: y, time: time, walking: placement.stage == .walking,
                     walkProgress: walkSeconds / 4.4, cycles: cycles, missingMiddle: taken,
                     style: Int(ChristmasScene.hash(UInt64(placement.sourceID) ^ scene.seed) % 4))
            context.restoreGState()
            if placement.stage == .departing || placement.stage == .arriving {
                snowflakeFlash(context, x: x, y: y + 19, time: time, strength: sin(.pi * placement.opacity))
            }
        }
        if let encounter, encounter.temporaryCarolers {
            let phase = encounter.phase(at: time)
            let opacity = min(1, phase / 0.18, (YetiEncounter.duration - phase) / 0.25)
            if opacity > 0 {
                context.saveGState(); context.setAlpha(opacity)
                carolers(context, x: left + width * encounter.carolerFraction, y: roof + 3,
                         time: time, walking: false, missingMiddle: taken,
                         style: Int(ChristmasScene.hash(UInt64(encounter.windowID) ^ scene.seed) % 4))
                context.restoreGState()
            }
        }
        if chimney {
            let cx = ChristmasScene.chimneyX(on: window) - origin.x
            ChristmasPixels.draw(ChristmasPixels.chimney, in: context, x: cx - 17, y: roof - 2)
            chimneyTrim(context, x: cx, y: roof,
                        style: Int(ChristmasScene.hash(UInt64(window.id) ^ scene.seed &+ 0xC41E) % 4))
            if scene.target == window.id,
               let visit = SantaVisitPose.at(scene.santaPhase(time: time), target: window, screen: window.frame),
               [.climbing, .descending, .inside, .resurfacing, .returning].contains(visit.stage) {
                context.saveGState()
                context.translateBy(x: -origin.x, y: -origin.y)
                santaFigure(visit, target: window, phase: scene.santaPhase(time: time), in: context)
                context.restoreGState()
            }
        }
        context.restoreGState()
    }
    static func lightWireY(roof: Double, fraction: Double, span: Double, windowID: UInt32, seed: UInt64) -> Double {
        let u = min(1, max(0, fraction))
        let anchors = [0.0, 0.31, 0.67, 1.0]
        let section = min(2, max(0, anchors.firstIndex(where: { $0 > u }).map { $0 - 1 } ?? 2))
        let progress = (u - anchors[section]) / (anchors[section + 1] - anchors[section])
        let depth = 7 + 3 * ChristmasScene.unit(UInt64(windowID) ^ seed &+ UInt64(section) &* 37)
        let irregularity = 0.7 * sin(u * 17 + ChristmasScene.unit(UInt64(windowID) ^ seed) * 6)
        let ordinaryY = roof - 3 - depth * sin(.pi * progress) - irregularity
        // Reserve a fixed left-hand title area. The wire and bulbs sit close
        // to the roof for the first 430 points, then regain their normal sag.
        let transition = min(1, max(0, (u * span - 430) / 220))
        let smooth = transition * transition * (3 - 2 * transition)
        let titleY = max(ordinaryY + 14, roof + 1)
        return titleY * (1 - smooth) + ordinaryY * smooth
    }
    private static func lights(window: SnowStormWindow, roof: Double, left: Double, time: Double, scene: ChristmasScene, in context: CGContext) {
        let count = min(22, max(7, Int(window.frame.width / 34)))
        let start = left + 18, span = window.frame.width - 36
        let wire = CGMutablePath()
        for sample in 0...60 {
            let u = Double(sample) / 60
            let point = CGPoint(x: start + span * u,
                                y: lightWireY(roof: roof, fraction: u, span: span, windowID: window.id, seed: scene.seed))
            if sample == 0 { wire.move(to: point) } else { wire.addLine(to: point) }
        }
        stroke(context, NSColor(calibratedRed: 0.015, green: 0.13, blue: 0.055, alpha: 0.98), 2.2)
        context.addPath(wire); context.strokePath()
        stroke(context, NSColor(calibratedRed: 0.16, green: 0.34, blue: 0.15, alpha: 0.78), 0.65)
        context.addPath(wire); context.strokePath()
        for u in [0.0, 0.31, 0.67, 1.0] {
            let x = start + span * u
            stroke(context, NSColor(calibratedRed: 0.02, green: 0.19, blue: 0.08, alpha: 1), 1.5)
            line(context, CGPoint(x: x, y: roof - 1),
                 CGPoint(x: x, y: lightWireY(roof: roof, fraction: u, span: span, windowID: window.id, seed: scene.seed)))
        }
        let burnt = ChristmasScene.hash(UInt64(window.id) ^ scene.seed) % 3 == 0
            ? Int(ChristmasScene.hash(UInt64(window.id) ^ scene.seed &+ 0xB01B) % UInt64(count)) : -1
        let glass: [NSColor] = [
            NSColor(calibratedRed: 0.95, green: 0.19, blue: 0.12, alpha: 1),
            NSColor(calibratedRed: 1, green: 0.64, blue: 0.15, alpha: 1),
            NSColor(calibratedRed: 1, green: 0.91, blue: 0.63, alpha: 1),
            NSColor(calibratedRed: 0.24, green: 0.73, blue: 0.29, alpha: 1),
            NSColor(calibratedRed: 0.25, green: 0.55, blue: 0.92, alpha: 1)
        ]
        for i in 0..<count {
            let jitter = (ChristmasScene.unit(UInt64(window.id) ^ scene.seed &+ UInt64(i) &* 131) - 0.5) * 0.22
            let u = (Double(i) + 0.5 + jitter) / Double(count)
            let x = start + span * u
            let y = lightWireY(roof: roof, fraction: u, span: span, windowID: window.id, seed: scene.seed)
            let size = 0.9 + 0.2 * ChristmasScene.unit(UInt64(window.id) ^ scene.seed &+ UInt64(i) &* 71)
            let flicker = Int(time * 8 + Double(i) * 1.6) % 37 == 0
            let lit = i != burnt && !flicker
            let colorOffset = Int(ChristmasScene.hash(UInt64(window.id) ^ scene.seed &+ 0xC010) % UInt64(glass.count))
            let color = lit ? glass[(i * 2 + colorOffset) % glass.count] : NSColor(calibratedWhite: 0.29, alpha: 1)
            if lit, let halo = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                color.withAlphaComponent(0.34).cgColor, color.withAlphaComponent(0).cgColor
            ] as CFArray, locations: [0, 1]) {
                context.drawRadialGradient(halo, startCenter: CGPoint(x: x, y: y - 6), startRadius: 0,
                                           endCenter: CGPoint(x: x, y: y - 6), endRadius: 10 * size, options: [])
            }
            fill(context, NSColor(calibratedRed: 0.025, green: 0.18, blue: 0.075, alpha: 1))
            context.fill(CGRect(x: x - 2.4 * size, y: y - 4.2 * size, width: 4.8 * size, height: 3.4 * size))
            let top = y - 3.7 * size
            let bulb = CGMutablePath()
            bulb.move(to: CGPoint(x: x - 1.5 * size, y: top))
            bulb.addCurve(to: CGPoint(x: x - 3.2 * size, y: top - 4.2 * size),
                          control1: CGPoint(x: x - 3.2 * size, y: top - 1.1 * size),
                          control2: CGPoint(x: x - 3.8 * size, y: top - 2.6 * size))
            bulb.addCurve(to: CGPoint(x: x, y: top - 8.4 * size),
                          control1: CGPoint(x: x - 3.0 * size, y: top - 6.8 * size),
                          control2: CGPoint(x: x - 1.8 * size, y: top - 8.4 * size))
            bulb.addCurve(to: CGPoint(x: x + 3.2 * size, y: top - 4.2 * size),
                          control1: CGPoint(x: x + 1.8 * size, y: top - 8.4 * size),
                          control2: CGPoint(x: x + 3.0 * size, y: top - 6.8 * size))
            bulb.addCurve(to: CGPoint(x: x + 1.5 * size, y: top),
                          control1: CGPoint(x: x + 3.8 * size, y: top - 2.6 * size),
                          control2: CGPoint(x: x + 3.2 * size, y: top - 1.1 * size))
            bulb.closeSubpath()
            fill(context, color); context.addPath(bulb); context.fillPath()
            stroke(context, NSColor(calibratedWhite: 0.12, alpha: 0.65), 0.55)
            context.addPath(bulb); context.strokePath()
            fill(context, NSColor.white.withAlphaComponent(lit ? 0.7 : 0.2))
            context.fillEllipse(in: CGRect(x: x - 1.9 * size, y: top - 3.5 * size,
                                           width: 1.1 * size, height: 2.6 * size))
        }
    }
    private static func pixelDecoration(_ c: CGContext, _ image: CGImage, x: Double, y: Double) {
        ChristmasPixels.draw(image, in: c, x: x - Double(image.width) / 2, y: y)
    }
    private static func chimneyTrim(_ c: CGContext, x: Double, y: Double, style: Int) {
        let greenery = NSColor(calibratedRed: 0.08, green: 0.34 + Double(style) * 0.035,
                                blue: 0.14, alpha: 1)
        fill(c, greenery)
        for offset in [-8.0, -4.0, 1.0, 5.0] {
            c.fillEllipse(in: CGRect(x: x + offset, y: y + 12 + Double(style % 2),
                                     width: 7, height: 5))
        }
        fill(c, style % 2 == 0 ? .systemRed : .systemYellow)
        for offset in [-7.0, 0.0, 7.0] {
            c.fillEllipse(in: CGRect(x: x + offset, y: y + 14, width: 2.5, height: 2.5))
        }
        if style >= 2 {
            fill(c, .white)
            c.fill(CGRect(x: x - 12, y: y + 29, width: 5, height: 2))
            c.fill(CGRect(x: x + 7, y: y + 23, width: 4, height: 2))
        }
    }
    private static func tree(_ c: CGContext, x: Double, y: Double, style: Int) {
        let rise = [-2.0, 3.0, 8.0, 0.0][style % 4]
        let breadth = [14.0, 18.0, 16.0, 20.0][style % 4]
        fill(c, NSColor(calibratedRed: 0.32, green: 0.15, blue: 0.08, alpha: 1)); c.fill(CGRect(x: x - 2, y: y, width: 4, height: 8))
        for i in 0..<3 {
            let dy = Double(i) * 10, spread = breadth - Double(i) * 3
            let p = CGMutablePath(); p.move(to: CGPoint(x: x, y: y + 37 + rise + dy * 0.3))
            p.addLine(to: CGPoint(x: x - spread, y: y + 6 + dy)); p.addQuadCurve(to: CGPoint(x: x + spread, y: y + 6 + dy), control: CGPoint(x: x, y: y + 11 + dy)); p.closeSubpath()
            fill(c, NSColor(calibratedRed: 0.025, green: 0.20 + Double(i) * 0.045 + Double(style % 3) * 0.025, blue: 0.11, alpha: 1)); c.addPath(p); c.fillPath()
        }
        let baubles: [NSColor] = [.systemRed, .systemYellow, .systemCyan, .systemPink]
        for (index, point) in [(-8.0, 13.0), (7.0, 21.0), (-3.0, 29.0), (9.0, 13.0)].enumerated() {
            let (dx, dy) = point, color = baubles[(index + style) % baubles.count]
            fill(c, color); c.fillEllipse(in: CGRect(x: x + dx - 2, y: y + dy, width: 4, height: 4))
        }
        if style == 2 {
            stroke(c, NSColor(calibratedWhite: 0.94, alpha: 0.8), 1.2)
            line(c, CGPoint(x: x - breadth + 3, y: y + 8), CGPoint(x: x - 4, y: y + 10))
            line(c, CGPoint(x: x + 5, y: y + 19), CGPoint(x: x + breadth - 6, y: y + 17))
        }
        fill(c, style == 3 ? .white : .systemYellow)
        c.fillEllipse(in: CGRect(x: x - 3, y: y + 37 + rise, width: 6, height: 6))
    }
    private static func presents(_ c: CGContext, x: Double, y: Double, variant: Int) {
        let positions: [[(Double, Double)]] = [
            [(-22, 0), (4, 0), (-5, 13)],
            [(-29, 0), (-5, 0), (18, 0), (3, 14)],
            [(-20, 0), (5, 0)],
            [(-33, 0), (-13, 0), (9, 0), (27, 0), (-2, 15)]
        ]
        for (index, position) in positions[variant % positions.count].enumerated() {
            let sprite = ChristmasPixels.gifts[(variant * 7 + index * 5) % ChristmasPixels.gifts.count]
            ChristmasPixels.draw(sprite, in: c, x: x + position.0, y: y + position.1)
        }
    }
    private static func candyCanes(_ c: CGContext, x: Double, y: Double, style: Int) {
        let placements: [[(Double, Double, Double)]] = [
            [(-14, 0, 1), (5, -2, 0.8)],
            [(-17, 0, 0.8), (0, -3, 1.1), (17, -1, 0.7)],
            [(-12, 0, 1.15), (11, -2, 0.75)],
            [(-18, -2, 0.75), (-2, 0, 1), (16, -3, 0.85)]
        ]
        for (dx, dy, size) in placements[style % placements.count] {
            c.saveGState()
            c.translateBy(x: x + dx, y: y + dy)
            c.scaleBy(x: size, y: size)
            ChristmasPixels.draw(ChristmasPixels.candyCane, in: c, x: 0, y: 0)
            c.restoreGState()
        }
    }
    private static func northPoleSign(_ c: CGContext, x: Double, y: Double, style: Int) {
        let direction = style % 2 == 0 ? 1.0 : -1.0
        let labels = ["NORTH POLE", "TOY SHOP", "HOT COCOA", "SANTA WAY"]
        fill(c, NSColor(calibratedRed: 0.35, green: 0.18, blue: 0.08, alpha: 1))
        c.fill(CGRect(x: x - 2, y: y, width: 4, height: 32 + Double(style % 3) * 3))
        let board = CGMutablePath()
        board.move(to: CGPoint(x: x - direction * 27, y: y + 19))
        board.addLine(to: CGPoint(x: x + direction * 17, y: y + 19))
        board.addLine(to: CGPoint(x: x + direction * 28, y: y + 25))
        board.addLine(to: CGPoint(x: x + direction * 17, y: y + 31))
        board.addLine(to: CGPoint(x: x - direction * 27, y: y + 31))
        board.closeSubpath()
        fill(c, NSColor(calibratedRed: 0.50, green: 0.24, blue: 0.10, alpha: 1))
        c.addPath(board); c.fillPath()
        stroke(c, NSColor(calibratedRed: 0.95, green: 0.83, blue: 0.57, alpha: 1), 1)
        c.addPath(board); c.strokePath()
        (labels[style % labels.count] as NSString).draw(in: CGRect(x: x - 24, y: y + 21, width: 43, height: 9),
                                        withAttributes: [.font: NSFont.boldSystemFont(ofSize: 6.2),
                                                         .foregroundColor: NSColor.white])
        fill(c, .white); c.fillEllipse(in: CGRect(x: x - 1, y: y + 32, width: 2, height: 2))
    }
    private static func mistletoe(_ c: CGContext, x: Double, y: Double, style: Int) {
        stroke(c, NSColor(calibratedRed: 0.22, green: 0.42, blue: 0.18, alpha: 1), 1.5)
        line(c, CGPoint(x: x, y: y + 34), CGPoint(x: x, y: y + 22))
        for side in [-1.0, 1.0] {
            for level in 0..<(2 + style % 2) {
                let startY = y + 21 + Double(level) * 6
                let leaf = CGMutablePath()
                leaf.move(to: CGPoint(x: x, y: startY))
                leaf.addQuadCurve(to: CGPoint(x: x + side * (11 + Double(level) * 3 + Double(style)), y: startY + 7),
                                  control: CGPoint(x: x + side * 6, y: startY + 10))
                leaf.addQuadCurve(to: CGPoint(x: x, y: startY),
                                  control: CGPoint(x: x + side * 7, y: startY - 2))
                fill(c, NSColor(calibratedRed: 0.07, green: 0.32 + Double(level) * 0.07 + Double(style % 2) * 0.05, blue: 0.15, alpha: 1))
                c.addPath(leaf); c.fillPath()
            }
        }
        fill(c, style == 1 ? .systemRed : NSColor(calibratedWhite: 0.98, alpha: 1))
        for (dx, dy) in [(-3.0, 19.0), (2, 18), (0, 22), (5, 24)].prefix(3 + style % 2) {
            c.fillEllipse(in: CGRect(x: x + dx - 2, y: y + dy - 2, width: 4, height: 4))
        }
        fill(c, style == 3 ? .systemYellow : .systemRed)
        c.fillEllipse(in: CGRect(x: x - 4, y: y + 31, width: 8, height: 4))
    }
    private static func snowman(_ c: CGContext, x: Double, y: Double, style: Int) {
        c.saveGState()
        c.translateBy(x: x, y: y)
        let scale = [0.88, 1.0, 1.12, 0.98][style % 4]
        c.scaleBy(x: scale, y: scale)
        fill(c, NSColor(white: 0.96, alpha: 1)); c.fillEllipse(in: CGRect(x: -10, y: 0, width: 20, height: 20))
        c.fillEllipse(in: CGRect(x: -7, y: 16, width: 14, height: 14))
        c.fillEllipse(in: CGRect(x: -5, y: 28, width: 10, height: 10))
        fill(c, .black); c.fillEllipse(in: CGRect(x: -3, y: 34, width: 1.5, height: 1.5)); c.fillEllipse(in: CGRect(x: 2, y: 34, width: 1.5, height: 1.5))
        stroke(c, NSColor(calibratedRed: 0.42, green: 0.21, blue: 0.1, alpha: 1))
        line(c, CGPoint(x: -7, y: 20), CGPoint(x: -16 - Double(style % 2) * 3, y: 25))
        line(c, CGPoint(x: 7, y: 20), CGPoint(x: 16, y: 25 + Double(style % 3) * 2))
        let scarves: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange]
        fill(c, scarves[style % scarves.count]); c.fill(CGRect(x: -8, y: 28, width: 16, height: 2))
        c.fill(CGRect(x: 5, y: 22, width: 2, height: 7))
        fill(c, .systemOrange); c.fill(CGRect(x: 3, y: 32, width: 4, height: 1.5))
        fill(c, .black)
        for dot in [9.0, 14.0, 20.0] { c.fillEllipse(in: CGRect(x: -1, y: dot, width: 2, height: 2)) }
        if style % 2 == 0 {
            fill(c, NSColor(white: 0.1, alpha: 1))
            c.fill(CGRect(x: -7, y: 37, width: 14, height: 3))
            c.fill(CGRect(x: -4, y: 39, width: 8, height: 7))
        } else {
            fill(c, style == 1 ? .systemRed : .systemBlue)
            c.fillEllipse(in: CGRect(x: -6, y: 36, width: 12, height: 8))
            c.fill(CGRect(x: -7, y: 37, width: 14, height: 2))
            fill(c, .white); c.fillEllipse(in: CGRect(x: 4, y: 43, width: 3, height: 3))
        }
        c.restoreGState()
    }
    private static func carolers(_ c: CGContext, x: Double, y: Double, time: Double,
                                 walking: Bool, walkProgress: Double = 0, cycles: Int = 3,
                                 missingMiddle: Bool = false, style: Int) {
        let coats: [[NSColor]] = [
            [NSColor(calibratedRed: 0.15, green: 0.40, blue: 0.32, alpha: 1),
             NSColor(calibratedRed: 0.67, green: 0.11, blue: 0.16, alpha: 1),
             NSColor(calibratedRed: 0.22, green: 0.35, blue: 0.59, alpha: 1)],
            [.systemPurple, .systemGreen, .systemOrange],
            [.systemBlue, .systemBrown, .systemRed],
            [.systemTeal, .systemPink, .systemIndigo]
        ]
        for i in 0..<3 {
            if missingMiddle && i == 1 { continue }
            let dx = Double(i - 1) * 19
            let motion = walking ? walkProgress * Double(max(1, cycles + i - 1)) * 2 * .pi :
                time * 2.5 + Double(i) * 1.4
            let bob = StickWalkPose.at(motion, stride: 6.2, walking: walking).hipBob
            figure(c, x: x + dx, y: y, coat: coats[style % coats.count][i], motion: motion,
                   singing: true, walking: walking, stride: 6.2,
                   bookMotion: time * 2.5 + Double(i) * 1.4)
            if style % 2 == 1 {
                fill(c, coats[style % coats.count][(i + 1) % 3])
                c.fill(CGRect(x: x + dx - 5, y: y + 37 + bob, width: 10, height: 2))
                c.fill(CGRect(x: x + dx - 3, y: y + 39 + bob, width: 6, height: 4))
            } else if style == 2 {
                fill(c, .white)
                c.fill(CGRect(x: x + dx - 3, y: y + 26, width: 6, height: 1.6))
            }
        }
        if Int(time * 1.4) % 3 == 0 {
            stroke(c, NSColor(white: 0.97, alpha: 1), 1)
            line(c, CGPoint(x: x + 32, y: y + 32), CGPoint(x: x + 32, y: y + 39))
            fill(c, .white); c.fillEllipse(in: CGRect(x: x + 29, y: y + 30, width: 4, height: 3))
        }
    }
    private static func snowflakeFlash(_ c: CGContext, x: Double, y: Double, time: Double, strength: Double) {
        guard strength > 0.01 else { return }
        c.saveGState()
        c.setAlpha(strength)
        for flake in 0..<7 {
            let angle = Double(flake) * 2.399 + time * 0.7
            let radius = 6 + Double(flake % 3) * 8 + strength * 7
            let center = CGPoint(x: x + cos(angle) * radius, y: y + sin(angle) * radius)
            let size = 3.5 + Double(flake % 3) * 1.5
            stroke(c, NSColor(calibratedRed: 0.79, green: 0.94, blue: 1, alpha: 1), 1.2)
            for arm in 0..<6 {
                let direction = Double(arm) * .pi / 3 + time * 0.3
                let tip = CGPoint(x: center.x + cos(direction) * size, y: center.y + sin(direction) * size)
                line(c, center, tip)
                let branch = CGPoint(x: center.x + cos(direction) * size * 0.6,
                                     y: center.y + sin(direction) * size * 0.6)
                for side in [-1.0, 1.0] {
                    let back = direction + .pi + side * .pi / 3
                    line(c, tip, CGPoint(x: branch.x + cos(back) * size * 0.25,
                                         y: branch.y + sin(back) * size * 0.25))
                }
            }
            fill(c, .white)
            c.fillEllipse(in: CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2))
        }
        c.restoreGState()
    }
    static func yetiVisit(scene: ChristmasScene, windows: [SnowStormWindow], screen: CGRect,
                          time: Double, in c: CGContext, origin: CGPoint) {
        guard let encounter = scene.yeti,
              let target = windows.first(where: { $0.id == encounter.windowID }),
              target.frame.intersects(screen),
              ChristmasScene.roofVisible(on: target, in: windows, fractions: [encounter.carolerFraction]),
              let pose = YetiPose.at(encounter.phase(at: time), encounter: encounter, target: target,
                                     screen: screen) else { return }
        c.saveGState()
        c.translateBy(x: pose.center.x - origin.x, y: pose.center.y - origin.y)
        c.scaleBy(x: encounter.direction, y: 1)
        let phase = encounter.phase(at: time)
        let frame = YetiAnimation.frame(at: phase, biting: pose.biting)
        ChristmasPixels.draw(ChristmasPixels.yeti[frame], in: c, x: -33, y: 0)
        if pose.biting && phase >= YetiEncounter.biteTime - 0.08 {
            stroke(c, NSColor(calibratedRed: 1, green: 0.93, blue: 0.69, alpha: 0.9), 1.6)
            for angle in stride(from: -0.8, through: 0.8, by: 0.4) {
                line(c, CGPoint(x: 18, y: 33), CGPoint(x: 24 + cos(angle) * 4, y: 33 + sin(angle) * 8))
            }
        }
        c.restoreGState()
    }
    static func santaVisit(scene: ChristmasScene, windows: [SnowStormWindow], screen: CGRect, time: Double,
                           in c: CGContext, origin: CGPoint) {
        guard scene.santa.active, let targetID = scene.target,
              let target = windows.first(where: { $0.id == targetID }), target.frame.intersects(screen) else { return }
        let phase = scene.santaPhase(time: time)
        guard let visit = SantaVisitPose.at(phase, target: target, screen: screen) else { return }
        let x = visit.sleigh.x, y = visit.sleigh.y
        c.saveGState(); c.translateBy(x: -origin.x, y: -origin.y)
        // The snow field is ordered directly below the frontmost window, so
        // Santa appears above the others without a second Santa in a roof strip.
        ChristmasPixels.draw(ChristmasPixels.sleigh, in: c, x: x - 27, y: y - 4)
        var deer: [CGPoint] = []
        let flying = phase < 8.5 || visit.stage == .departing
        for i in 0..<4 {
            let point = CGPoint(x: x + 49 + Double(i) * 47,
                                y: y + 4 + (flying ? sin(time * 7.3 + Double(i) * 1.65) * 2.8 : 0))
            deer.append(point)
            let gallop = flying ? Int(floor(time * 7.3 + Double(i) * 1.65)) & 1 : 0
            ChristmasPixels.draw(ChristmasPixels.reindeer[i][gallop], in: c, x: point.x, y: point.y)
        }
        // Fine curved reins and individual neck straps stay vector-sharp while
        // the animals bob independently over their pixel textures.
        stroke(c, NSColor(calibratedRed: 0.17, green: 0.11, blue: 0.08, alpha: 0.95), 1.1)
        for (i, point) in deer.enumerated() {
            let start = i == 0 ? CGPoint(x: x + 25, y: y + 14) :
                CGPoint(x: deer[i - 1].x + 38, y: deer[i - 1].y + 25)
            let end = CGPoint(x: point.x + 29, y: point.y + 22)
            let harness = CGMutablePath(); harness.move(to: start)
            harness.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) * 0.5, y: min(start.y, end.y) - 5))
            c.addPath(harness); c.strokePath()
            line(c, CGPoint(x: point.x + 29, y: point.y + 18), CGPoint(x: point.x + 35, y: point.y + 24))
            line(c, CGPoint(x: point.x + 10, y: point.y + 19), CGPoint(x: point.x + 30, y: point.y + 20))
        }
        if ![.climbing, .descending, .inside, .resurfacing, .returning].contains(visit.stage) {
            santaFigure(visit, target: target, phase: phase, in: c)
        }
        c.restoreGState()
    }
    private static func santaFigure(_ visit: SantaVisitPose, target: SnowStormWindow, phase: Double,
                                    in c: CGContext) {
        guard visit.stage != .inside else { return }
        if visit.stage == .descending || visit.stage == .resurfacing {
            c.saveGState()
            let chimneyX = ChristmasScene.chimneyX(on: target)
            // The mouth starts two pixels below the front lip. Clip at the
            // mouth so the boots enter before the body disappears.
            c.clip(to: CGRect(x: chimneyX - 10, y: target.frame.maxY + 40, width: 20, height: 100))
        }
        let sx = visit.santa.x, sy = visit.santa.y
        let motion = SantaArticulation.at(phase)
        c.saveGState()
        if visit.stage == .resurfacing || visit.stage == .returning || visit.stage == .remounting {
            c.translateBy(x: 2 * sx, y: 0)
            c.scaleBy(x: -1, y: 1)
        }
        figure(c, x: sx, y: sy, coat: NSColor(calibratedRed: 0.78, green: 0.10, blue: 0.12, alpha: 1),
               motion: 0, walking: false, santaMotion: motion, carryingGift: visit.carriesPresent)
        c.saveGState()
        c.translateBy(x: motion.lean, y: motion.gait.hipBob - motion.crouch)
        fill(c, .white)
        c.fillEllipse(in: CGRect(x: sx - 3.7, y: sy + 29, width: 7.4, height: 5.4))
        c.fill(CGRect(x: sx - 5, y: sy + 37, width: 10, height: 2.5))
        let hat = CGMutablePath()
        hat.move(to: CGPoint(x: sx - 5, y: sy + 39))
        hat.addLine(to: CGPoint(x: sx + 3, y: sy + 46))
        hat.addLine(to: CGPoint(x: sx + 5, y: sy + 39))
        hat.closeSubpath()
        fill(c, .systemRed); c.addPath(hat); c.fillPath()
        fill(c, .white); c.fillEllipse(in: CGRect(x: sx + 2, y: sy + 44, width: 3, height: 3))
        c.restoreGState()
        c.restoreGState()
        if visit.stage == .descending || visit.stage == .resurfacing { c.restoreGState() }
    }
}
