import AppKit
import QuartzCore

/// Deterministic formula/geometry checks never manipulate user windows.
enum SnowStormTests {
    static func run(root: URL) throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1; assert(value(), "Snow Storm: " + message)
        }
        let screen = CGRect(x: 0, y: 0, width: 640, height: 480)
        let window = SnowStormWindow(id: 101, owner: 99, frame: CGRect(x: 100, y: 100, width: 240, height: 100), level: 0)
        let cornerProfile = StormDrift(id: UInt64(window.id), window: window, frame: window.frame)
        check(cornerProfile.supportY(at: window.frame.minX) == nil &&
              cornerProfile.supportY(at: window.frame.maxX) == nil &&
              cornerProfile.supportY(at: window.frame.minX + StormDrift.cornerBlank)! > 190 &&
              cornerProfile.supportY(at: window.frame.maxX - StormDrift.cornerBlank)! > 190 &&
              abs(cornerProfile.supportY(at: window.frame.minX + StormDrift.cornerInset)! - 200) < 0.001 &&
              abs(cornerProfile.supportY(at: window.frame.midX)! - 200) < 0.001,
              "window snow begins inside symmetric rounded corners and reaches the flat roof")
        check(cornerProfile.heightCaps.first == 0 && cornerProfile.heightCaps.last == 0 &&
              cornerProfile.heightCaps[3] < cornerProfile.heightCaps[8],
              "snow height tapers to zero before both window edges")
        let quiet = SnowStormSettings(snowfall: 0.1, maximumFlakeSize: 0.5, gusts: 0)
        func advance(_ simulation: SnowStormSimulation, frames: Int = 1, windows: [SnowStormWindow]? = nil, cursor: CGPoint? = nil, emit: Bool = false, settings: SnowStormSettings? = nil) {
            for _ in 0..<frames { simulation.advance(dt: 1.0 / 120, windows: windows ?? [window], cursor: cursor, screens: [screen], settings: settings ?? quiet, emit: emit) }
        }
        func flake(x: Double, y: Double, vx: Double = 0, vy: Double = -180, mass: Double = 20, radius: Double = 2, depth: UInt32? = nil) -> StormFlake {
            var p = StormFlake(position: CGPoint(x: x, y: y), velocity: CGVector(dx: vx, dy: vy), mass: mass, radius: radius, phase: 1.2, depthWindow: depth)
            while !SnowStormSimulation.landsOnWindow(p, id: window.id) || !SnowStormSimulation.landsOnWindow(p, id: 202) { p.landingSeed += 1 }
            p.age = 1; return p
        }
        func conserved(_ simulation: SnowStormSimulation) -> Bool { abs(simulation.totalMass + simulation.escapedMass - simulation.emittedMass) < 0.001 }
        let resting = SnowStormSimulation()
        advance(resting)
        resting.addParticleForTesting(flake(x: 180, y: 215, vx: 55))
        advance(resting, frames: 70)
        check(resting.drifts[0].mass > 19.9 && resting.particles.isEmpty, "landing blends flakes into one snowbank")
        check(resting.drifts[0].masses.filter { $0 > 0 }.count > 1, "a landing blends across adjacent bins")
        check(conserved(resting), "landing and settling conserve mass")
        let restingMass = resting.totalMass
        let quietRevision = resting.drifts[0].revision
        advance(resting, frames: 240)
        check(abs(resting.totalMass - restingMass) < 0.001 && conserved(resting), "settled snow does not silently vanish")
        check(resting.drifts[0].revision == quietRevision, "stationary banks do no per-frame relaxation work")

        let cornerLanding = SnowStormSimulation()
        advance(cornerLanding)
        cornerLanding.addParticleForTesting(flake(x: 110, y: 198, vy: -100, mass: 4, radius: 1))
        advance(cornerLanding, frames: 30)
        check(cornerLanding.drifts[0].mass > 3.9 && conserved(cornerLanding),
              "a flake below the straight top edge can land on the lowered corner surface")

        let formula = SnowStormSimulation()
        let fixed = flake(x: 30, y: 430, vx: 8, vy: -80)
        formula.addParticleForTesting(fixed)
        advance(formula, frames: 120, windows: [])
        check(formula.particles.count == 1 && abs(formula.particles[0].position.y - 350) < 0.001, "falling uses a constant travel formula")
        check(formula.particles[0].velocity == fixed.velocity, "falling has no integrated gravity, drag, or impulses")

        let shaken = SnowStormSimulation()
        advance(shaken); shaken.fillDriftForTesting(id: UInt64(window.id), height: 24)
        let shakenStartingMass = shaken.drifts[0].mass
        var moved = window; moved.frame.origin.x += 16
        advance(shaken, windows: [moved])
        check(shaken.erosionMass > 0 && !shaken.particles.isEmpty, "abrupt motion eats away at the snowbank and produces loose snow")
        check(shaken.drifts[0].mass < shakenStartingMass, "erosion reduces the merged object's mass")
        check(shaken.drifts[0].mass > shakenStartingMass * 0.95, "a single ordinary move retains almost all window snow")
        check(shaken.particles.allSatisfy { abs($0.velocity.dx) <= 24 && $0.velocity.dy < 0 }, "shed snow uses bounded formula rates without window momentum")
        check(shaken.particles.contains { $0.position.x < moved.frame.minX }, "snow can be left behind at the old window position")
        check(conserved(shaken), "eroded snow is transferred to particles, not duplicated")
        var more = moved; more.frame.origin.x += 100
        advance(shaken, windows: [more])
        check(shaken.particles.contains { $0.position.x < more.frame.minX }, "old debris is not teleported to a moving support")
        check(conserved(shaken), "continued shaking remains mass-conservative")
        check(shaken.particles.allSatisfy { $0.radius <= quiet.maximumRadius }, "released snow obeys the selected maximum flake size")

        let steady = SnowStormSimulation()
        advance(steady); steady.fillDriftForTesting(id: UInt64(window.id), height: 20)
        let startingMass = steady.drifts[0].mass
        var dragged = window
        for _ in 0..<40 {
            dragged.frame.origin.x += 4
            advance(steady, windows: [dragged])
        }
        check(steady.drifts[0].mass > startingMass * 0.95,
              "a sustained ordinary drag carries the snowbank instead of eroding it every frame")
        func movedBank(step: Double, vertical: Bool = false) -> SnowStormSimulation {
            let simulation = SnowStormSimulation()
            advance(simulation)
            simulation.fillDriftForTesting(id: UInt64(window.id), height: 20)
            var moving = window
            for _ in 0..<6 {
                if vertical { moving.frame.origin.y += step }
                else { moving.frame.origin.x += step }
                simulation.advance(dt: 1.0 / 30, windows: [moving], cursor: nil,
                                   screens: [screen], settings: quiet, emit: false)
            }
            return simulation
        }
        let slowDrag = movedBank(step: 12)
        let fastDrag = movedBank(step: 48)
        let fastVerticalDrag = movedBank(step: 32, vertical: true)
        check(fastDrag.drifts[0].mass < slowDrag.drifts[0].mass - startingMass * 0.06 &&
              fastDrag.drifts[0].mass > startingMass * 0.55 &&
              !fastDrag.particles.isEmpty && conserved(fastDrag),
              "a fast one-direction drag sheds visibly more snow without emptying the window")
        check(fastVerticalDrag.drifts[0].mass < startingMass * 0.99 &&
              fastVerticalDrag.particles.count <= 6 * 16 && conserved(fastVerticalDrag),
              "a quick vertical drag loosens snow with a bounded number of clumps")
        let beforeRelocation = steady.drifts[0].mass
        dragged.frame.origin.x += 600
        advance(steady, windows: [dragged])
        check(abs(steady.drifts[0].mass - beforeRelocation) < 0.001,
              "a large geometry sample relocates the window without treating it as a shake")
        check(conserved(steady), "edge loss and relocation conserve snow mass")

        let rapid = SnowStormSimulation()
        advance(rapid); rapid.fillDriftForTesting(id: UInt64(window.id), height: 20)
        var shakenWindow = window
        for _ in 0..<5 {
            for step in [40.0, 40, -40, -40] {
                shakenWindow.frame.origin.x += step
                rapid.advance(dt: 1.0 / 30, windows: [shakenWindow], cursor: nil,
                              screens: [screen], settings: quiet, emit: false)
            }
        }
        check(rapid.drifts[0].mass < startingMass * 0.85 && rapid.drifts[0].mass > startingMass * 0.45,
              "quick repeated reversals shed some snow without instantly emptying the bank")
        check(!rapid.particles.isEmpty && conserved(rapid), "shaken-off snow becomes bounded falling flakes")

        for direction in [-1.0, 1.0] {
            let knocked = SnowStormSimulation()
            var original = window
            original.frame.origin.x = direction > 0 ? 50 : 300
            advance(knocked, windows: [original])
            let x = direction > 0 ? original.frame.maxX + 35 : original.frame.minX - 35
            knocked.addParticleForTesting(flake(x: x, y: 155, vx: -direction * 10, vy: -20))
            var returning = original; returning.frame.origin.x += direction * 65
            advance(knocked, windows: [returning])
            let edge = direction > 0 ? returning.frame.maxX : returning.frame.minX
            check(knocked.collisionCount > 0 && knocked.particles.contains { ($0.position.x - edge) * direction >= 2 }, "a moving window nudges intercepted snow to its leading X edge")
            check(knocked.particles.allSatisfy { $0.velocity.dx == -direction * 10 && $0.velocity.dy == -20 }, "an edge nudge adds no bounce or physical impulse")
            check(conserved(knocked), "moving-body collision conserves snow mass")
        }
        let capped = SnowStormSimulation()
        advance(capped); capped.fillDriftForTesting(id: UInt64(window.id), height: 36)
        let cappedBank = capped.drifts[0]
        check((cappedBank.heightCaps.max()! - cappedBank.heightCaps.min()!) > 9 &&
              cappedBank.heightCaps[0] < cappedBank.heightCaps[cappedBank.heightCaps.count / 2],
              "a full bank has stable low edges and uneven peaks instead of one rectangular height")
        check(cappedBank.heights.max()! <= 24.00001, "window snowbanks stop at the lower 24-point limit")
        check(StormDrift(id: UInt64(window.id), window: window, frame: window.frame).heightCaps == cappedBank.heightCaps &&
              StormDrift(id: 202, window: window, frame: window.frame).heightCaps != cappedBank.heightCaps,
              "each window keeps its own stable snow profile")
        capped.addParticleForTesting(flake(x: 180, y: 244, mass: 100))
        advance(capped, frames: 80)
        check(capped.drifts.allSatisfy { drift in zip(drift.heights, drift.heightCaps).allSatisfy { $0.0 <= $0.1 + 0.00001 } },
              "window accumulation stops at each cell's natural height cap")
        check(abs(capped.drifts[0].mass - cappedBank.mass) < 0.001, "a full irregular bank stops building up")
        check(!capped.particles.isEmpty && conserved(capped), "overflow remains mobile without losing or creating mass")

        let pointer = SnowStormSimulation()
        let point = CGPoint(x: 200, y: 220)
        advance(pointer, windows: [], cursor: point)
        pointer.fillDriftForTesting(id: StormDrift.cursorID, height: 12)
        pointer.addParticleForTesting(flake(x: 205, y: 247))
        advance(pointer, frames: 60, windows: [], cursor: point)
        check(pointer.drifts[0].isCursor && pointer.drifts[0].heights.allSatisfy { $0 <= 12.00001 }, "cursor supports a separate bounded drift")
        advance(pointer, windows: [], cursor: CGPoint(x: 235, y: 220))
        check(pointer.erosionMass > 0 && !pointer.particles.isEmpty, "fast cursor movement sheds snow with inertia")
        check(conserved(pointer), "cursor snow conserves mass through shedding")

        let silhouette = CursorSnowShape(size: CGSize(width: 16, height: 16), hotSpot: CGPoint(x: 2, y: 3),
            pixelWidth: 4, pixelHeight: 4, alpha: [255, 0, 0, 0,
                                                    0, 255, 0, 0,
                                                    0, 0, 255, 0,
                                                    0, 0, 0, 0])!
        let shapedFrame = silhouette.frame(at: point)
        check(shapedFrame == CGRect(x: 198, y: 207, width: 16, height: 16) &&
              silhouette.topY(at: 200, in: shapedFrame) == 223 &&
              silhouette.topY(at: 204, in: shapedFrame) == 219 &&
              silhouette.topY(at: 208, in: shapedFrame) == 215 &&
              silhouette.topY(at: 212, in: shapedFrame) == nil,
              "cursor collision columns follow their first visible pixel and hotspot")
        let shaped = SnowStormSimulation(cursorShape: silhouette)
        advance(shaped, windows: [], cursor: point)
        check(shaped.drifts[0].frame == shapedFrame && shaped.drifts[0].heightCaps.last == 0,
              "transparent cursor columns cannot collect snow")
        shaped.addParticleForTesting(flake(x: 200, y: 230, vy: -120, mass: 4, radius: 1))
        advance(shaped, frames: 30, windows: [], cursor: point)
        check(shaped.drifts[0].mass > 3.9 && conserved(shaped),
              "falling snow lands at the sampled opaque cursor column")
        let transparent = SnowStormSimulation(cursorShape: silhouette)
        advance(transparent, windows: [], cursor: point)
        transparent.addParticleForTesting(flake(x: 212.5, y: 230, vy: -120, mass: 4, radius: 1))
        advance(transparent, frames: 30, windows: [], cursor: point)
        check(transparent.drifts[0].mass == 0 && conserved(transparent),
              "snow passes through transparent cursor columns")
        let arrowAlpha: [UInt8] = (0..<32).flatMap { y in
            (0..<32).map { x in x < 24 && y >= Int(Double(x) * 0.7) ? 255 : 0 }
        }
        let arrow = CursorSnowShape(size: CGSize(width: 32, height: 32), hotSpot: .zero,
                                    pixelWidth: 32, pixelHeight: 32, alpha: arrowAlpha)!
        let smoothCursor = SnowStormSimulation(cursorShape: arrow)
        advance(smoothCursor, windows: [], cursor: point)
        smoothCursor.addParticleForTesting(flake(x: 211, y: 230, vy: -120, mass: 8, radius: 1))
        advance(smoothCursor, frames: 30, windows: [], cursor: point)
        let cap = smoothCursor.drifts.first { $0.isCursor }!
        check(cap.masses.filter { $0 > 0.001 }.count >= 5 && conserved(smoothCursor),
              "a cursor landing spreads across nearby opaque pixels instead of one thin column")
        smoothCursor.fillDriftForTesting(id: StormDrift.cursorID, height: 8)
        let displayCap = smoothCursor.drifts.first { $0.isCursor }!
        let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: preview)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let drawing = graphics.cgContext, area = CGRect(x: 190, y: 180, width: 64, height: 64)
        drawing.setFillColor(NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.20, alpha: 1).cgColor)
        drawing.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        drawing.scaleBy(x: 4, y: 4)
        let cursorArt = CGMutablePath()
        cursorArt.move(to: CGPoint(x: 10, y: 40)); cursorArt.addLine(to: CGPoint(x: 34, y: 23))
        cursorArt.addLine(to: CGPoint(x: 34, y: 8)); cursorArt.addLine(to: CGPoint(x: 10, y: 8))
        cursorArt.closeSubpath()
        drawing.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 1).cgColor)
        drawing.addPath(cursorArt); drawing.fillPath()
        SnowStormDrawing.drift(displayCap, in: drawing, origin: area.origin)
        NSGraphicsContext.restoreGraphicsState()
        try preview.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("cursor-snow-cap.png"))

        let layered = SnowStormSimulation()
        let front = SnowStormWindow(id: 202, owner: 98, frame: CGRect(x: 120, y: 150, width: 200, height: 200), level: 0)
        advance(layered, windows: [front, window])
        layered.addParticleForTesting(flake(x: 200, y: 365))
        advance(layered, frames: 60, windows: [front, window])
        check(layered.drifts.first { $0.id == UInt64(front.id) }!.mass > 0 && layered.drifts.first { $0.id == UInt64(window.id) }!.mass == 0, "frontmost exposed surface receives falling snow")
        advance(layered, windows: [window, front])
        check(layered.windows.first?.id == window.id && layered.drifts.first { $0.id == UInt64(front.id) }!.mass > 0, "reordering preserves the drift attached to each window identity")
        advance(layered, windows: [])
        check(layered.drifts.isEmpty && !layered.particles.isEmpty && conserved(layered), "closing a window releases its drift")

        let varied = SnowStormSimulation()
        var upper = front; upper.frame = CGRect(x: 120, y: 260, width: 200, height: 90)
        advance(varied, windows: [upper, window])
        for seed in 0..<120 {
            var p = flake(x: 200, y: 365, mass: 2); p.landingSeed = UInt32(seed)
            varied.addParticleForTesting(p)
        }
        advance(varied, frames: 150, windows: [upper, window])
        let upperMass = varied.drifts.first { $0.id == UInt64(upper.id) }!.mass
        let lowerMass = varied.drifts.first { $0.id == UInt64(window.id) }!.mass
        check(upperMass > 30 && upperMass < 200 && lowerMass > 20, "some snow lands on the first top and some passes in front to a lower top")
        check(!varied.particles.isEmpty && conserved(varied), "other snow continues falling past both windows without mass duplication")

        let low = SnowStormSimulation(seed: 9), high = SnowStormSimulation(seed: 9)
        var lowWind = 0.0, highWind = 0.0
        for _ in 0..<3_600 {
            advance(low, windows: [], settings: SnowStormSettings(gusts: 0.01))
            advance(high, windows: [], settings: SnowStormSettings(gusts: 1))
            lowWind += abs(low.wind); highWind += abs(high.wind)
        }
        check(highWind > lowWind * 3 && high.gustCount > low.gustCount, "one gust slider increases both strength and frequency")
        let lightSnow = SnowStormSimulation(seed: 37), heavySnow = SnowStormSimulation(seed: 37)
        var greatestWindDifference = 0.0
        for _ in 0..<1_800 {
            advance(lightSnow, windows: [], emit: true, settings: SnowStormSettings(snowfall: 0.1, gusts: 0.8))
            advance(heavySnow, windows: [], emit: true, settings: SnowStormSettings(snowfall: 1, gusts: 0.8))
            greatestWindDifference = max(greatestWindDifference, abs(lightSnow.wind - heavySnow.wind))
        }
        check(greatestWindDifference < 0.000001 && lightSnow.gustCount == heavySnow.gustCount &&
              lightSnow.vortexCount == heavySnow.vortexCount && lightSnow.vortex?.center == heavySnow.vortex?.center,
              "snowfall amount cannot change horizontal gust timing, strength, or vortex placement")
        var edgeDirections = Set<Int>()
        for seed in 1...16 where edgeDirections.count < 2 {
            let gust = SnowStormSimulation(seed: UInt64(seed))
            let setting = SnowStormSettings(snowfall: 1, gusts: 1)
            for _ in 0..<300 where abs(gust.wind) < 45 { advance(gust, windows: [], settings: setting) }
            guard abs(gust.wind) >= 45 else { continue }
            gust.advance(dt: 0.05, windows: [], cursor: nil, screens: [screen], settings: setting, emit: true)
            let direction = gust.wind >= 0 ? 1 : -1
            let edgeFlakes = gust.particles.filter { p in
                p.position.y < screen.maxY - 50 &&
                (direction > 0 ? p.position.x < screen.minX + 20 : p.position.x > screen.maxX - 20)
            }
            let heights = edgeFlakes.map { $0.position.y }
            check(edgeFlakes.count >= 2 && heights.max()! - heights.min()! > 70,
                  "a Wind Gusts driven crosswind brings flakes through its upwind edge at varied heights")
            edgeDirections.insert(direction)
        }
        check(edgeDirections == Set([-1, 1]), "crosswinds can arrive from both screen edges")
        let spinning = SnowStormSimulation(seed: 44)
        let gustSetting = SnowStormSettings(snowfall: 0.5, gusts: 1)
        for _ in 0..<2_000 where (spinning.vortex?.envelope(at: spinning.time) ?? 0) < 0.8 {
            advance(spinning, windows: [], settings: gustSetting)
        }
        check(spinning.vortexCount > 0 && spinning.vortex != nil, "strong Wind Gusts occasionally starts an edge vortex")
        let vortex = spinning.vortex!
        let edgeDistance = min(abs(vortex.center.x - screen.minX), abs(vortex.center.x - screen.maxX))
        let right = spinning.vortexVelocity(at: CGPoint(x: vortex.center.x + vortex.radius * 0.5, y: vortex.center.y), gusts: 1)
        let above = spinning.vortexVelocity(at: CGPoint(x: vortex.center.x, y: vortex.center.y + vortex.radius * 0.5), gusts: 1)
        check(edgeDistance < vortex.radius * 0.4 && abs(right.dy) > 100 && abs(above.dx) > 100 && right.dy * above.dx < 0,
              "the vortex circulates flakes around a center placed at the screen edge")
        check(vortex.envelope(at: vortex.start) == 0 && vortex.envelope(at: vortex.start + vortex.duration) == 0 &&
              vortex.envelope(at: vortex.start + vortex.duration * 0.5) > 0.99,
              "the edge vortex grows and fades instead of appearing abruptly")
        spinning.advance(dt: 0.05, windows: [], cursor: nil, screens: [screen], settings: SnowStormSettings(snowfall: 1, gusts: 1), emit: true)
        check(spinning.particles.contains { hypot($0.position.x - vortex.center.x, $0.position.y - vortex.center.y) < vortex.radius * 0.8 },
              "the vortex draws from the existing flake budget so its circular motion is visible")
        let gentle = SnowStormSimulation(seed: 11), blizzard = SnowStormSimulation(seed: 11)
        gentle.addParticleForTesting(flake(x: 300, y: 440, vy: -80))
        blizzard.addParticleForTesting(flake(x: 300, y: 440, vy: -80))
        let mild = SnowStormSettings(snowfall: 0.5, gusts: 0)
        let intense = SnowStormSettings(snowfall: 1, gusts: 0)
        advance(gentle, frames: 120, windows: [], settings: mild)
        advance(blizzard, frames: 120, windows: [], settings: intense)
        check(gentle.particles.count == 1 && blizzard.particles.count == 1 &&
              gentle.particles[0].position.y - blizzard.particles[0].position.y > 200,
              "maximum Snowfall intensity makes existing flakes fall much faster")
        check(abs(blizzard.particles[0].position.x - gentle.particles[0].position.x) < 0.000001 &&
              abs(blizzard.wind) < 0.000001 && abs(gentle.wind) < 0.000001,
              "Snowfall intensity changes vertical fall but cannot create horizontal wind")
        let beforeChange = gentle.particles[0].position.y
        advance(gentle, frames: 30, windows: [], settings: intense)
        check(beforeChange - gentle.particles[0].position.y > 70,
              "changing intensity accelerates flakes already on screen")
        let small = SnowStormSimulation(seed: 7), medium = SnowStormSimulation(seed: 7), large = SnowStormSimulation(seed: 7)
        advance(small, frames: 360, windows: [], emit: true, settings: SnowStormSettings(snowfall: 0.1, maximumFlakeSize: 0.01, gusts: 0))
        advance(medium, frames: 360, windows: [], emit: true, settings: SnowStormSettings(snowfall: 0.5, maximumFlakeSize: 1, gusts: 0))
        advance(large, frames: 360, windows: [], emit: true, settings: SnowStormSettings(snowfall: 1, maximumFlakeSize: 1, gusts: 0))
        check((small.particles.map(\.radius).max() ?? 0) <= 1.477 && (large.particles.map(\.radius).max() ?? 0) > 5, "maximum flake size changes the size distribution")
        check(large.particles.count > small.particles.count * 2, "snowfall intensity increases emission")
        check(large.particles.count > medium.particles.count,
              "faster maximum-intensity flakes are replenished densely enough to remain a stronger storm")
        check(large.particles.allSatisfy { $0.position.y < screen.maxY + $0.radius + 3 && $0.velocity.dy < 0 }, "fresh snow enters from the top and falls")
        let overloaded = SnowStormSimulation()
        for i in 0..<6_050 { overloaded.addParticleForTesting(flake(x: Double(i % 600), y: 400)) }
        advance(overloaded, windows: [])
        check(overloaded.particles.count <= SnowStormSimulation.maximumParticles && conserved(overloaded), "simulation and resource-limit accounting remain bounded")
        advance(large, frames: 1_200, windows: [], emit: true, settings: SnowStormSettings(snowfall: 1, maximumFlakeSize: 1, gusts: 1))
        check(large.particles.count <= SnowStormSimulation.maximumParticles && large.particles.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite }, "a sustained storm stays finite and bounded")
        check(conserved(large), "emission, screen exits, and culling account for all mass")
        try nativeAndRenderingChecks(root: root) { check($0, $1) }
        print("\(checks) Snow Storm checks passed: formula travel, edge nudges, varied landing depth, merged banks, cursor, Z order, sliders, bounded rendering, and cleanup.")
    }

    private static func nativeAndRenderingChecks(root: URL, check: (Bool, String) -> Void) throws {
        let frames = [StaticEffectScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 640, height: 480))]
        let back = SnowStormWindow(id: 101, owner: 10, frame: CGRect(x: 60, y: 80, width: 370, height: 180), level: 0)
        let front = SnowStormWindow(id: 202, owner: 11, frame: CGRect(x: 260, y: 150, width: 300, height: 230), level: 0)
        var orders: [(NSPanel, SnowStormWindow?)] = []
        var fieldTargets: [UInt32?] = []
        let controller = SnowStormController(settings: SnowStormSettings(), screens: { frames }, cursor: { nil }, query: { _, _ in [] },
            present: { orders.append(($0, $1)) }, presentField: { _, target in fieldTargets.append(target?.id) }, automaticTicks: false)
        controller.advanceForTesting(dt: 1.0 / 60, windows: [front, back], cursor: nil)
        controller.simulation.fillDriftForTesting(id: UInt64(back.id), height: 23)
        controller.simulation.fillDriftForTesting(id: UInt64(front.id), height: 15)
        controller.advanceForTesting(dt: 1.0 / 60, windows: [front, back], cursor: CGPoint(x: 510, y: 90))
        controller.simulation.fillDriftForTesting(id: StormDrift.cursorID, height: 8)
        controller.advanceForTesting(dt: 1.0 / 60, windows: [front, back], cursor: CGPoint(x: 510, y: 90))
        check(controller.allPanels.count == 4, "one field surface, two thin window drifts, and one cursor drift are used")
        check(orders.compactMap { panel, window -> Bool? in
            guard let window else { return nil }
            return abs(panel.frame.minY - (window.frame.maxY - StormDrift.cornerDrop - 4)) < 0.001 &&
                   panel.frame.maxY >= window.frame.maxY + 24
        }.allSatisfy { $0 }, "each window overlay includes the lowered corner snow without clipping")
        check(fieldTargets == [front.id], "the full-screen snowfall field targets the frontmost window for placement behind it")
        check(Set(orders.compactMap { $0.1?.id }) == Set([front.id, back.id]), "drift presentation uses each original window as its relative-order target")
        let redrawRequests = controller.bankRedrawRequestsForTesting
        controller.advanceForTesting(dt: 1.0 / 30, windows: [front, back], cursor: CGPoint(x: 510, y: 90))
        check(controller.bankRedrawRequestsForTesting == redrawRequests, "unchanged banks request no redraw with the full-screen field")
        orders.removeAll()
        var shifted = back; shifted.frame.origin.x += 1
        controller.advanceForTesting(dt: 1.0 / 30, windows: [front, shifted], cursor: CGPoint(x: 510, y: 90))
        check(orders.isEmpty, "ordinary movement does not reorder every bank")
        check(controller.allPanels.allSatisfy { $0.ignoresMouseEvents && !$0.canBecomeKey && !$0.canBecomeMain }, "all snow surfaces pass through clicks and focus")
        orders.removeAll()
        controller.advanceForTesting(dt: 1.0 / 60, windows: [back, front], cursor: CGPoint(x: 510, y: 90))
        check(fieldTargets.last == back.id, "the snowfall field follows focus-order changes")
        check(orders.compactMap { $0.1?.id }.count == 2, "unchanged-geometry Z reordering reorders both snowbanks")
        check(!controller.timerRunningForTesting, "controlled rendering does not start a live animation timer")
        try preview(controller.simulation, frames: frames, root: root)
        let previous = controller.allPanels
        controller.shutdown()
        controller.advanceForTesting(dt: 1, windows: [front, back], cursor: nil)
        check(controller.allPanels.isEmpty && controller.simulation.particles.isEmpty && previous.allSatisfy { !$0.isVisible }, "shutdown discards simulation and all surfaces")
        let defaults = MemoryDefaults(), prefs = PreferenceStore(defaults: MemoryDefaults())
        prefs.set(StaticEffect.snowStorm.rawValue, for: .staticEffect)
        prefs.set(80, for: .stormSnowfall); prefs.set(90, for: .stormFlakeSize); prefs.set(25, for: .stormGusts)
        let config = StaticEffectConfiguration(preferences: prefs)
        check(config.effect == .snowStorm && config.amount == 0.8 && config.size == 0.9 && config.speed == 0.25, "Storm's three sliders map to intensity, maximum size, and gusts")
        defaults.set(StaticEffect.snowStorm.rawValue, forKey: PreferenceKey.staticEffect.rawValue)
        defaults.set(999, forKey: PreferenceKey.stormFlakeSize.rawValue)
        let restored = PreferenceStore(defaults: defaults)
        check(restored.staticEffect == .snowStorm && restored.int(.stormFlakeSize) == 100, "saved Storm choices restore with safe bounds")
        var reduced = false
        let wrapper = StaticEffectsController(preferences: prefs, reducedMotion: { reduced }, screens: { [] }, present: { _, _ in }, automaticPlacement: false)
        let live = wrapper.stormForTesting!
        check(live.timerRunningForTesting, "selecting Snow Storm starts its dedicated simulation clock")
        check(live.timerIntervalForTesting == 1.0 / 30, "the live storm renders at a bounded 30 frames per second")
        let model = live.simulation
        prefs.set(20, for: .stormSnowfall)
        check(wrapper.stormForTesting === live && live.simulation === model, "live slider changes preserve snow already in the simulation")
        reduced = true; wrapper.reconcile()
        check(wrapper.stormForTesting == nil && !live.timerRunningForTesting, "Reduce Motion tears down the Snow Storm clock")
        reduced = false; wrapper.reconcile()
        let resumed = wrapper.stormForTesting!
        prefs.set(StaticEffect.none.rawValue, for: .staticEffect)
        check(wrapper.stormForTesting == nil && !resumed.timerRunningForTesting, "No Effect stops all Snow Storm simulation work")
        wrapper.shutdown()
    }

    private static func preview(_ simulation: SnowStormSimulation, frames: [StaticEffectScreen], root: URL) throws {
        // Render the same drift/flake drawing against native-style fixture windows.
        let bounds = frames[0].frame
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: image)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let cg = graphics.cgContext
        cg.setFillColor(NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.18, alpha: 1).cgColor); cg.fill(bounds)
        for window in simulation.windows.reversed() {
            cg.setFillColor(NSColor(calibratedRed: 0.19, green: 0.27, blue: 0.36, alpha: 1).cgColor)
            cg.addPath(CGPath(roundedRect: window.frame, cornerWidth: StormDrift.cornerInset,
                              cornerHeight: StormDrift.cornerInset, transform: nil))
            cg.fillPath()
            if let drift = simulation.drifts.first(where: { $0.window?.id == window.id }) { SnowStormDrawing.drift(drift, in: cg, origin: .zero) }
        }
        SnowStormDrawing.flakes(simulation.particles, windows: simulation.windows, in: cg, worldRect: bounds, time: simulation.time)
        if let cursor = simulation.drifts.first(where: \.isCursor) { SnowStormDrawing.drift(cursor, in: cg, origin: .zero) }
        NSGraphicsContext.restoreGraphicsState()
        try image.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("snow-storm-preview.png"))
    }
}
