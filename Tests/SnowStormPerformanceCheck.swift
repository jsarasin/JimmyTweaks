import AppKit

/// Controlled comparison, not a desktop-wide CPU/GPU benchmark.
@main struct SnowStormPerformanceCheck {
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let simulation = SnowStormSimulation(seed: 31)
        var windows = (0..<24).map { i in
            SnowStormWindow(id: UInt32(i + 1), owner: 100, frame: CGRect(x: (i % 6) * 360, y: (i / 6) * 240 + 80, width: 640, height: 420), level: 0)
        }
        let settings = SnowStormSettings(snowfall: 1, maximumFlakeSize: 0.7, gusts: 0.5)
        simulation.advance(dt: 1.0 / 30, windows: windows, cursor: nil, screens: [screen], settings: settings, emit: false)
        for window in windows { simulation.fillDriftForTesting(id: UInt64(window.id), height: 20) }
        var elapsed = 0.0
        for frame in 0..<420 {
            while simulation.particles.count < 3000 {
                let i = simulation.particles.count
                simulation.addParticleForTesting(StormFlake(position: CGPoint(x: Double((i * 73) % 2560), y: Double((i * 97 + frame * 31) % 1440)),
                    velocity: CGVector(dx: 2, dy: -80), mass: 2, radius: 2, phase: Double(i % 60) * 0.1))
            }
            windows[0].frame.origin.x = 200 + sin(Double(frame) * 0.08) * 160
            let start = ProcessInfo.processInfo.systemUptime
            simulation.advance(dt: 1.0 / 30, windows: windows, cursor: nil, screens: [screen], settings: settings, emit: false)
            elapsed += ProcessInfo.processInfo.systemUptime - start
        }
        let context = CGContext(data: nil, width: 2560, height: 1440, bitsPerComponent: 8, bytesPerRow: 2560 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var drawing = 0.0
        for _ in 0..<30 {
            context.clear(screen)
            let start = ProcessInfo.processInfo.systemUptime
            SnowStormDrawing.flakes(simulation.particles, windows: simulation.windows, in: context, worldRect: screen, time: simulation.time)
            drawing += ProcessInfo.processInfo.systemUptime - start
        }
        print(String(format: "3000 flakes / 24 windows / 2560×1440, including an edge vortex: update %.3f ms; particle draw %.3f ms; final population %d.", elapsed * 1000 / 420, drawing * 1000 / 30, simulation.particles.count))
    }
}
