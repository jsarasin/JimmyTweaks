import Foundation
import CoreGraphics
import simd

/// Four aligned vectors shared with the instanced Metal sprite renderer.
struct EffectSprite {
    var geometry: SIMD4<Float> // world centre XY, length, width
    var direction: SIMD4<Float> // unit direction XY, curvature/phase, seed
    var appearance: SIMD4<Float> // opacity, material, age fraction, core width
    var colour: SIMD4<Float>
}

private struct EffectRandom {
    var state: UInt64 = 0x71A9C3
    mutating func unit() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
    }
    mutating func between(_ a: Float, _ b: Float) -> Float { a + (b - a) * unit() }
}

/// A particle's birth position and velocity never follow later window changes.
struct WindField {
    static let emissionRate: Float = 145 * 4
    static let capacity = 420 * 4
    struct Particle {
        let id: UInt64
        let origin: SIMD2<Float>
        let velocity: SIMD2<Float>
        let size: SIMD2<Float>
        let material: Int
        let colour: SIMD4<Float>
        let seed: Float
        let life: Float
        var age: Float = 0
        var position: SIMD2<Float> {
            let normal = SIMD2(-velocity.y, velocity.x) / max(1, simd_length(velocity))
            return origin + velocity * age + normal * (sin(age * 3.5 + seed) - sin(seed)) * 15
        }
    }
    private(set) var particles: [Particle] = []
    private var random = EffectRandom()
    private var credit: Float = 0
    private var age: Float = 0
    private var angle: Float = 0
    private var nextID: UInt64 = 0

    mutating func advance(dt: Float, window: CGRect, velocity: SIMD2<Float>, emitting: Bool) {
        age += dt
        for i in particles.indices { particles[i].age += dt }
        particles.removeAll { $0.age >= $0.life }
        guard emitting else { return }
        if simd_length(velocity) > 25 {
            let desired = atan2(velocity.y, velocity.x)
            angle += atan2(sin(desired - angle), cos(desired - angle)) * (1 - exp(-dt * 5))
        }
        credit += dt * Self.emissionRate * min(1, age / 0.4)
        let direction = SIMD2(cos(angle), sin(angle)), normal = SIMD2(-direction.y, direction.x)
        let half = SIMD2(Float(window.width), Float(window.height)) * 0.5
        let centre = SIMD2(Float(window.midX), Float(window.midY))
        let along = simd_dot(simd_abs(direction), half)
        let across = simd_dot(simd_abs(normal), half) + 150
        while credit >= 1 && particles.count < Self.capacity {
            credit -= 1; nextID &+= 1
            let choice = random.unit()
            let material = choice < 0.39 ? 0 : choice < 0.66 ? 1 : choice < 0.94 ? 2 : 3
            let grey = random.between(0.60, 0.98)
            var colour = SIMD4(grey, grey, grey, Float(1))
            if material == 2 { colour = SIMD4(0.66, 0.61, 0.53, 1) }
            if material == 3 {
                let palette = [SIMD4<Float>(0.92, 0.42, 0.10, 1), SIMD4(0.96, 0.72, 0.17, 1), SIMD4(0.70, 0.19, 0.08, 1)]
                colour = palette[min(2, Int(random.unit() * 3))]
            }
            let size: SIMD2<Float>
            switch material {
            case 0: size = SIMD2(random.between(95, 245), random.between(18, 48))
            case 1: size = SIMD2(random.between(60, 195), random.between(5, 14))
            case 2: size = SIMD2(random.between(2, 7), random.between(2, 6))
            default: size = SIMD2(random.between(11, 22), random.between(7, 14))
            }
            let origin = centre - direction * (along + random.between(155, 390)) + normal * random.between(-across, across)
            let speed = random.between(260, 490) + min(650, simd_length(velocity) * 0.48)
            particles.append(Particle(id: nextID, origin: origin, velocity: direction * speed + normal * random.between(-28, 28),
                size: size, material: material, colour: colour, seed: random.between(0, 30), life: random.between(1.65, 2.6)))
        }
        credit = min(credit, 2)
    }

    func sprites(departure: Float?) -> [EffectSprite] {
        let finalFade = departure.map { 1 - smooth(0.65, 1, $0) } ?? 1
        return particles.map { particle in
            let phase = particle.age / particle.life
            let opacity = smooth(0, 0.16, phase) * (1 - smooth(0.56, 1, phase)) * finalFade
            var rotation = atan2(particle.velocity.y, particle.velocity.x)
            if particle.material == 3 { rotation += sin(particle.age * 5 + particle.seed) * 1.8 + particle.age * 1.2 }
            let p = particle.position
            return EffectSprite(geometry: SIMD4(p.x, p.y, particle.size.x, particle.size.y),
                direction: SIMD4(cos(rotation), sin(rotation), particle.age * 2 + particle.seed, particle.seed),
                appearance: SIMD4(opacity, Float(particle.material), phase, 0), colour: particle.colour)
        }
    }
}

/// Crystals appear independently near the two active edges. Existing flakes
/// stay in world space when the corner moves, so their fade does not snap.
struct CrystalFrostField {
    static let emissionRate: Float = 32
    static let capacity = 65
    struct Flake {
        let origin: SIMD2<Float>
        let velocity: SIMD2<Float>
        let size: Float
        let angle: Float
        let spin: Float
        let shape: Float
        let tint: SIMD4<Float>
        let life: Float
        var age: Float = 0
        var position: SIMD2<Float> { origin + velocity * age }
    }
    private(set) var flakes: [Flake] = []
    private var random = EffectRandom(state: 0xC2A571F05)
    private var credit: Float = 0
    private var elapsed: Float = 0

    mutating func advance(dt: Float, corner: SIMD2<Float>, arms: SIMD2<Float>, emitting: Bool) {
        elapsed += dt
        for i in flakes.indices { flakes[i].age += dt }
        flakes.removeAll { $0.age >= $0.life }
        guard emitting else { return }
        credit += dt * Self.emissionRate * min(1, elapsed / 0.18)
        while credit >= 1 && flakes.count < Self.capacity {
            credit -= 1
            let choice = random.unit()
            let offset: SIMD2<Float>
            if choice < 0.42 {
                offset = SIMD2(arms.x * random.between(8, 145), random.between(-27, 27))
            } else if choice < 0.84 {
                offset = SIMD2(random.between(-27, 27), arms.y * random.between(8, 145))
            } else {
                offset = SIMD2(arms.x * random.between(-46, 86), arms.y * random.between(-46, 86))
            }
            let shape = random.unit()
            let size = shape > 0.76 ? random.between(8, 21) :
                (random.unit() < 0.7 ? random.between(23, 48) : random.between(12, 23))
            let palette = [SIMD4<Float>(0.83, 0.96, 1, 1), SIMD4<Float>(0.54, 0.85, 1, 1),
                           SIMD4<Float>(0.92, 0.91, 1, 1)]
            let tint = palette[min(2, Int(random.unit() * 3))]
            flakes.append(Flake(origin: corner + offset,
                                velocity: SIMD2(random.between(-12, 12), random.between(-12, 12)),
                                size: size, angle: random.between(-.pi, .pi),
                                spin: random.between(-0.55, 0.55), shape: shape,
                                tint: tint, life: random.between(0.8, 1.75)))
        }
        credit = min(credit, 2)
    }

    func sprites(departure: Float?) -> [EffectSprite] {
        let endFade = departure.map { 1 - smooth(0.56, 1, $0) } ?? 1
        return flakes.map { flake in
            let phase = flake.age / flake.life
            let opacity = smooth(0, 0.18, flake.age) * (1 - smooth(0.58, 1, phase)) * endFade
            let angle = flake.angle + flake.spin * flake.age
            let point = flake.position
            return EffectSprite(geometry: SIMD4(point.x, point.y, flake.size, flake.size),
                direction: SIMD4(cos(angle), sin(angle), flake.angle, flake.spin),
                appearance: SIMD4(opacity, 7, phase, flake.shape), colour: flake.tint)
        }
    }
}

/// Persistent, independently timed Tesla fingers. Anchors live on the window;
/// roots may walk around its perimeter while their tips probe or whip through the air.
struct ElectricalField {
    private struct Finger {
        let id: UInt64
        let anchored: Bool
        var edge: Int
        var offset: Float
        var age: Float
        var life: Float
        var collapse: Float
        let width: Float
        var random: EffectRandom
        var current: [Arc] = []
        var previous: [Arc] = []
        var channelAge: Float = 0
        var strikeTimer: Float = 0
        var crossfade: Float = 0.055
        var revision = 0
        var lastRoot: SIMD2<Float>?
        var normalAngle: Float
        var angle: Float = 0
        var targetAngle: Float = 0
        var reach: Float
        var targetReach: Float
        var sweep: Bool
        var modeTimer: Float
        var tipTimer: Float
        var walkTimer: Float
        var walkSpeed: Float = 0
        var targetWalkSpeed: Float = 0
        var sparkTimer: Float
    }
    private struct Arc {
        var points: [SIMD2<Float>]
        let width: Float
        let opacity: Float
        var attachment: Float = 0
        var rootInfluence: Float = 1
    }
    private struct Spark {
        let origin: SIMD2<Float>
        let velocity: SIMD2<Float>
        let life: Float
        var age: Float = 0
    }
    private var random = EffectRandom(state: 0xC011F1E1D)
    private var fingers: [Finger] = []
    private var arcs: [Arc] = []
    private var sparks: [Spark] = []
    private var rootGlows: [(position: SIMD2<Float>, opacity: Float)] = []
    private var nextID: UInt64 = 0
    private var elapsed: Float = 0
    private var departing = false

    private static func edgeLength(_ edge: Int, _ window: CGRect) -> Float {
        max(1, Float(edge % 2 == 0 ? window.width : window.height))
    }
    private static func normalAngle(_ edge: Int) -> Float {
        [-Float.pi / 2, 0, Float.pi / 2, Float.pi][edge]
    }
    private static func root(_ finger: Finger, _ window: CGRect) -> SIMD2<Float> {
        let x = Float(window.minX), y = Float(window.minY), w = Float(window.width), h = Float(window.height)
        let t = finger.offset
        switch finger.edge {
        case 0: return SIMD2(x + t * w, y)
        case 1: return SIMD2(x + w, y + t * h)
        case 2: return SIMD2(x + (1 - t) * w, y + h)
        default: return SIMD2(x, y + (1 - t) * h)
        }
    }
    private static func offsets(depth: Int, random: inout EffectRandom) -> [Float] {
        var points: [Float] = [0, 0], displacement: Float = 0.19
        for _ in 0..<depth {
            var next = [points[0]]
            for i in 0..<(points.count - 1) {
                next.append((points[i] + points[i + 1]) * 0.5 + random.between(-displacement, displacement))
                next.append(points[i + 1])
            }
            points = next; displacement *= 0.48
        }
        return points
    }
    private mutating func makeFinger(slot: Int, window: CGRect, arms: SIMD2<Float>, initial: Bool) -> Finger {
        nextID &+= 1
        // Each finger owns a separate random stream, not a shared animation phase.
        var rng = EffectRandom(state: random.state ^ (nextID &* 0x9E3779B97F4A7C15))
        _ = random.unit()
        let edge: Int
        var offset: Float
        if initial && slot < 4 {
            edge = slot % 2 == 0 ? (arms.y > 0 ? 0 : 2) : (arms.x > 0 ? 3 : 1)
            let near = rng.between(0.03, min(0.65, 220 / Self.edgeLength(edge, window)))
            offset = edge == 0 ? (arms.x > 0 ? near : 1 - near) :
                edge == 1 ? (arms.y > 0 ? near : 1 - near) :
                edge == 2 ? (arms.x > 0 ? 1 - near : near) : (arms.y > 0 ? 1 - near : near)
        } else { edge = min(3, Int(rng.unit() * 4)); offset = rng.unit() }
        offset = min(1, max(0, offset))
        let anchored = initial ? slot % 2 == 0 : rng.unit() < 0.48
        let sweep = initial ? slot % 3 == 1 : rng.unit() < 0.35
        let reach = rng.between(150, 300)
        return Finger(id: nextID, anchored: anchored, edge: edge, offset: offset,
            age: -(initial ? (slot == 0 ? 0 : Float(slot) * 0.08 + rng.between(0, 0.14)) : rng.between(0.06, 0.35)),
            life: rng.between(1.4, 4.8), collapse: rng.between(0.25, 0.60), width: rng.between(2.0, 3.6),
            random: rng,
            normalAngle: Self.normalAngle(edge), reach: reach, targetReach: reach, sweep: sweep,
            modeTimer: rng.between(0.4, 1.8), tipTimer: rng.between(0.04, 0.4), walkTimer: rng.between(0.03, 0.3), sparkTimer: rng.between(0.02, 0.2))
    }

    private static func channel(from start: SIMD2<Float>, to end: SIMD2<Float>, count: Int, random: inout EffectRandom) -> [SIMD2<Float>] {
        let delta = end - start, reach = max(1, simd_length(delta))
        let normal = SIMD2(-delta.y, delta.x) / reach
        let offsets = Self.offsets(depth: 6, random: &random)
        return (0..<count).map { i in
            let u = Float(i) / Float(count - 1), sample = u * Float(offsets.count - 1)
            let lo = min(offsets.count - 2, Int(sample)), fraction = sample - Float(lo)
            let displacement = offsets[lo] * (1 - fraction) + offsets[lo + 1] * fraction
            return start + delta * u + normal * (reach * displacement)
        }
    }

    private static func moveRoots(_ arcs: inout [Arc], by delta: SIMD2<Float>) {
        for i in arcs.indices {
            for j in arcs[i].points.indices {
                let u = Float(j) / Float(arcs[i].points.count - 1)
                arcs[i].points[j] += delta * (arcs[i].rootInfluence * (1 - u) * (1 - u))
            }
        }
    }

    private static func restrike(_ f: inout Finger, root: SIMD2<Float>) {
        let normal = SIMD2(cos(Self.normalAngle(f.edge)), sin(Self.normalAngle(f.edge)))
        let tangent = SIMD2(-normal.y, normal.x)
        var endpoint = root + SIMD2(cos(f.normalAngle + f.angle), sin(f.normalAngle + f.angle)) * f.reach
        if !f.sweep, let oldTip = f.current.first?.points.last {
            endpoint = oldTip * 0.65 + endpoint * 0.35 + normal * f.random.between(-12, 28) + tangent * f.random.between(-26, 26)
        } else { endpoint += tangent * f.random.between(-35, 35) }
        var relative = endpoint - root
        let outward = simd_dot(relative, normal), sideways = simd_dot(relative, tangent)
        // Leaders grow into the air outside their edge, including while roots cross corners.
        relative = normal * max(65, outward) + tangent * min(330, max(-330, sideways))
        relative *= min(1, 420 / max(1, simd_length(relative)))
        endpoint = root + relative
        let old = f.current
        var leader: [SIMD2<Float>]
        if let oldLeader = old.first?.points, oldLeader.count == 33 {
            // Keep the proximal channel; grow a newly fractured distal route.
            // Changing a tip target never rotates the existing leader like a rigid rod.
            let pivot = f.sweep ? Int(f.random.between(3, 10)) : Int(f.random.between(10, 21))
            let tail = Self.channel(from: oldLeader[pivot], to: endpoint, count: 33 - pivot, random: &f.random)
            leader = Array(oldLeader.prefix(pivot)) + tail
        } else { leader = Self.channel(from: root, to: endpoint, count: 33, random: &f.random) }
        var tree = [Arc(points: leader, width: f.width, opacity: 1)]
        let branches = Int(f.random.between(4, 8))
        for j in 0..<branches {
            let attach = min(29, max(5, Int(f.random.between(6, 30))))
            let u = Float(attach) / 32
            let direction = leader[min(32, attach + 2)] - leader[max(0, attach - 1)]
            let angle = atan2(direction.y, direction.x) + (j % 2 == 0 ? 1 : -1) * f.random.between(0.35, 1.35)
            let length = f.reach * f.random.between(0.13, 0.43)
            let end = leader[attach] + SIMD2(cos(angle), sin(angle)) * length
            let points = Self.channel(from: leader[attach], to: end, count: 17, random: &f.random)
            let width = f.width * f.random.between(0.15, 0.38) * pow(1 - u, 0.4)
            let influence = (1 - u) * (1 - u)
            tree.append(Arc(points: points, width: width, opacity: f.random.between(0.55, 0.95), attachment: u, rootInfluence: influence))
            if f.random.unit() < 0.75 {
                let at = Int(f.random.between(6, 13)), v = Float(at) / 16
                let twigAngle = angle + f.random.between(-1.2, 1.2)
                let twigEnd = points[at] + SIMD2(cos(twigAngle), sin(twigAngle)) * length * f.random.between(0.25, 0.55)
                tree.append(Arc(points: Self.channel(from: points[at], to: twigEnd, count: 9, random: &f.random),
                    width: width * 0.35, opacity: 0.55, attachment: min(0.97, u + (1 - u) * v * 0.35), rootInfluence: influence * (1 - v) * (1 - v)))
            }
        }
        // Small radial streamers make the attachment point a corona, not a blunt line end.
        for _ in 0..<4 {
            let angle = Self.normalAngle(f.edge) + f.random.between(-1.5, 1.5)
            let end = root + SIMD2(cos(angle), sin(angle)) * f.random.between(12, 36)
            tree.append(Arc(points: Self.channel(from: root, to: end, count: 9, random: &f.random), width: 0.22, opacity: 0.50))
        }
        f.previous = old; f.current = tree; f.channelAge = 0; f.revision += 1
        f.strikeTimer = f.sweep ? f.random.between(0.035, 0.075) : f.random.between(0.065, 0.14)
        f.crossfade = min(0.070, f.strikeTimer * 0.85)
    }

    private static func trimmed(_ points: [SIMD2<Float>], fraction: Float) -> [SIMD2<Float>] {
        if fraction >= 0.999 { return points }
        return points.indices.map { i in
            let sample = Float(i) * fraction
            let lo = min(points.count - 2, Int(sample)), f = sample - Float(lo)
            return points[lo] * (1 - f) + points[lo + 1] * f
        }
    }

    mutating func advance(dt: Float, window: CGRect, corner: SIMD2<Float>, arms: SIMD2<Float>, speed: Float, emitting: Bool) {
        elapsed += dt
        for i in sparks.indices { sparks[i].age += dt }
        sparks.removeAll { $0.age >= $0.life }
        if fingers.isEmpty && emitting {
            for slot in 0..<8 { fingers.append(makeFinger(slot: slot, window: window, arms: arms, initial: true)) }
        }
        if !emitting && !departing {
            departing = true
            for i in fingers.indices {
                if fingers[i].age < 0 { fingers[i].life = 0; continue }
                let remaining = fingers[i].random.between(0.28, 0.78)
                fingers[i].life = min(fingers[i].life, fingers[i].age + remaining)
                fingers[i].collapse = min(fingers[i].collapse, remaining)
            }
        }
        arcs.removeAll(keepingCapacity: true); rootGlows.removeAll(keepingCapacity: true)
        for index in fingers.indices {
            if fingers[index].age >= fingers[index].life {
                guard emitting else { continue }
                fingers[index] = makeFinger(slot: index, window: window, arms: arms, initial: false)
            }
            var f = fingers[index]
            f.age += dt
            guard f.age >= 0, f.age < f.life else { fingers[index] = f; continue }
            f.modeTimer -= dt; f.tipTimer -= dt; f.walkTimer -= dt; f.sparkTimer -= dt
            f.strikeTimer -= dt; f.channelAge += dt
            if f.modeTimer <= 0 {
                f.sweep.toggle()
                f.modeTimer = f.sweep ? f.random.between(0.35, 1.1) : f.random.between(0.9, 2.5)
                f.tipTimer = 0
            }
            if f.tipTimer <= 0 {
                if f.sweep {
                    f.targetAngle = f.random.between(-1.30, 1.30)
                    f.targetReach = f.random.between(150, 390)
                    f.tipTimer = f.random.between(0.07, 0.24)
                } else {
                    f.targetAngle = min(1.2, max(-1.2, f.targetAngle + f.random.between(-0.32, 0.32)))
                    f.targetReach = min(360, max(110, f.targetReach + f.random.between(-45, 45)))
                    f.tipTimer = f.random.between(0.30, 0.85)
                }
            }
            let response = 1 - exp(-dt * (f.sweep ? 19 : 1.7))
            f.angle += (f.targetAngle - f.angle) * response
            f.reach += (f.targetReach - f.reach) * response
            if !f.anchored {
                if f.walkTimer <= 0 {
                    f.targetWalkSpeed = f.random.between(-620, 620)
                    f.walkTimer = f.random.between(0.06, 0.32)
                }
                f.walkSpeed += (f.targetWalkSpeed - f.walkSpeed) * (1 - exp(-dt * 15))
                f.offset += f.walkSpeed * dt / Self.edgeLength(f.edge, window)
                while f.offset > 1 {
                    let excess = (f.offset - 1) * Self.edgeLength(f.edge, window)
                    f.edge = (f.edge + 1) % 4; f.offset = excess / Self.edgeLength(f.edge, window)
                }
                while f.offset < 0 {
                    let excess = -f.offset * Self.edgeLength(f.edge, window)
                    f.edge = (f.edge + 3) % 4; f.offset = 1 - excess / Self.edgeLength(f.edge, window)
                }
            }
            let desiredNormal = Self.normalAngle(f.edge)
            f.normalAngle += atan2(sin(desiredNormal - f.normalAngle), cos(desiredNormal - f.normalAngle)) * (1 - exp(-dt * 12))
            let collapse = 1 - smooth(f.life - f.collapse, f.life, f.age)
            let strength = smooth(0, 0.16, f.age) * sqrt(collapse)
            let root = Self.root(f, window)
            if let oldRoot = f.lastRoot {
                Self.moveRoots(&f.current, by: root - oldRoot)
                Self.moveRoots(&f.previous, by: root - oldRoot)
            }
            f.lastRoot = root
            if f.current.isEmpty || (emitting && collapse > 0.99 && f.strikeTimer <= 0) { Self.restrike(&f, root: root) }
            let oldWeight = 1 - smooth(0, f.crossfade, f.channelAge)
            let newWeight = f.previous.isEmpty ? 1 : smooth(0, 0.018, f.channelAge)
            for (tree, weight) in [(f.current, newWeight), (f.previous, oldWeight * 0.58)] where weight > 0.001 {
                for arc in tree {
                    let visible = min(1, max(0, (collapse - arc.attachment) / max(0.03, 1 - arc.attachment)))
                    guard visible > 0.001 else { continue }
                    arcs.append(Arc(points: Self.trimmed(arc.points, fraction: visible), width: arc.width,
                        opacity: arc.opacity * strength * weight * smooth(0, 0.10, visible)))
                }
            }
            rootGlows.append((root, strength * (0.45 + oldWeight * 0.35)))
            if f.sparkTimer <= 0 && emitting, let path = f.current.first?.points {
                f.sparkTimer = f.random.between(0.06, 0.20)
                let sparkAngle = f.normalAngle + f.angle + f.random.between(-1.5, 1.5)
                sparks.append(Spark(origin: path.last!, velocity: SIMD2(cos(sparkAngle), sin(sparkAngle)) * f.random.between(35, 150), life: f.random.between(0.35, 0.9)))
            }
            fingers[index] = f
        }
        if sparks.count > 100 { sparks.removeFirst(sparks.count - 100) }
    }

    func sprites(departure: Float?) -> [EffectSprite] {
        let entrance = smooth(0, 0.22, elapsed)
        let fade = departure.map { 1 - smooth(0.05, 0.85, $0) } ?? 1
        var result: [EffectSprite] = []
        for arc in arcs {
            for i in 0..<(arc.points.count - 1) {
                let a = arc.points[i], b = arc.points[i + 1], delta = b - a
                let length = max(0.01, simd_length(delta)), direction = delta / length, centre = (a + b) * 0.5
                let u = Float(i) / Float(arc.points.count - 1)
                let taper = 0.055 + 0.945 * pow(1 - u, 1.45)
                result.append(EffectSprite(geometry: SIMD4(centre.x, centre.y, length + 18, 24),
                    direction: SIMD4(direction.x, direction.y, length, 0),
                    appearance: SIMD4(arc.opacity * entrance * fade, 4, 0, max(0.12, arc.width * taper)), colour: SIMD4(0.28, 0.47, 1, 1)))
            }
        }
        for glow in rootGlows {
            result.append(EffectSprite(geometry: SIMD4(glow.position.x, glow.position.y, 26, 26), direction: SIMD4(1, 0, 0, 0),
                appearance: SIMD4(glow.opacity * entrance * fade, 6, 0, 0), colour: SIMD4(0.58, 0.28, 1, 1)))
        }
        for spark in sparks {
            let phase = spark.age / spark.life
            let p = spark.origin + spark.velocity * spark.age + SIMD2(0, -35 * spark.age * spark.age)
            let d = spark.velocity / max(1, simd_length(spark.velocity))
            result.append(EffectSprite(geometry: SIMD4(p.x, p.y, 9, 4), direction: SIMD4(d.x, d.y, 0, 0),
                appearance: SIMD4((1 - phase) * entrance * fade * 0.6, 5, phase, 0), colour: SIMD4(0.65, 0.8, 1, 1)))
        }
        return result
    }

    #if TESTING
    var dischargesForTesting: [(id: UInt64, revision: Int, points: [SIMD2<Float>], branches: Int, anchored: Bool, collapsing: Bool)] {
        fingers.filter { $0.age >= 0 && $0.age < $0.life && !$0.current.isEmpty }.map {
            ($0.id, $0.revision, $0.current[0].points, $0.current.count - 1, $0.anchored, $0.age > $0.life - $0.collapse)
        }
    }
    var fingersForTesting: [(id: UInt64, anchored: Bool, edge: Int, offset: Float, angle: Float, reach: Float, sweep: Bool, age: Float, remaining: Float, collapsing: Bool)] {
        fingers.map { ($0.id, $0.anchored, $0.edge, $0.offset, $0.angle, $0.reach, $0.sweep, $0.age, $0.life - $0.age, $0.age > $0.life - $0.collapse) }
    }
    #endif
}

private func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}
