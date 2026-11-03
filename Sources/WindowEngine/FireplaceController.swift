import AppKit
import QuartzCore
import ApplicationServices

/// Geometry only; optional hover bounds use an existing AX grant without prompts.
enum FireplaceDockQuery {
    static func read(desktopTop: Double, cursor: CGPoint? = nil) -> FireplaceDock? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let candidates = windows.compactMap { window -> CGRect? in
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, layer == Int(CGWindowLevelForKey(.dockWindow)),
                  let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
                  let x = bounds["X"]?.doubleValue, let y = bounds["Y"]?.doubleValue,
                  let width = bounds["Width"]?.doubleValue, let height = bounds["Height"]?.doubleValue,
                  min(width, height) >= 12, min(width, height) <= 512,
                  max(width, height) >= 120, max(width, height) / min(width, height) >= 1.5 else { return nil }
            let frame = CGRect(x: x, y: desktopTop - y - height, width: width, height: height)
            return WindowGeometry.valid(frame) ? frame : nil
        }
        guard var frame = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        // Dock backing bounds can omit the enlarged icon under the pointer.
        // One targeted geometry read avoids enumerating every Dock item.
        if let cursor, frame.insetBy(dx: -180, dy: -240).contains(cursor), AXIsProcessTrusted(), let pid = pids.first {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.02)
            var item: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(cursor.x), Float(desktopTop - cursor.y), &item) == .success, let item {
                AXUIElementSetMessagingTimeout(item, 0.02)
                var values: CFArray?
                if AXUIElementCopyMultipleAttributeValues(item, [kAXPositionAttribute, kAXSizeAttribute] as CFArray, [], &values) == .success,
                   let values = values as? [AnyObject], values.count == 2,
                   CFGetTypeID(values[0]) == AXValueGetTypeID(), CFGetTypeID(values[1]) == AXValueGetTypeID() {
                    var point = CGPoint.zero, size = CGSize.zero
                    if AXValueGetValue(values[0] as! AXValue, .cgPoint, &point), AXValueGetValue(values[1] as! AXValue, .cgSize, &size) {
                        let enlarged = CGRect(x: point.x, y: desktopTop - point.y - size.height, width: size.width, height: size.height)
                        if WindowGeometry.valid(enlarged), size.width <= frame.width + 256, size.height <= frame.height + 256,
                           frame.insetBy(dx: -180, dy: -240).intersects(enlarged) { frame = frame.union(enlarged) }
                    }
                }
            }
        }
        return FireplaceDock(frame: frame)
    }
}

/// Smooth heat-field artwork shared by live drawing and exported previews.
enum FireplaceDrawing {
    struct HeatSnapshot {
        let values: [Float]
        let columns: Int
        let rows: Int
        init(_ model: FireplaceModel) {
            values = model.fireHeat; columns = model.columns; rows = model.rows
        }
    }
    private static let backdropImage: CGImage? = {
        var url = Bundle.main.url(forResource: "FireboxBackdrop", withExtension: "png")
        #if TESTING
        if url == nil {
            url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/FireboxBackdrop.png")
        }
        #endif
        guard let url, let picture = NSImage(contentsOf: url) else { return nil }
        return picture.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()
    #if TESTING
    static var hasBackdropForTesting: Bool { backdropImage != nil }
    #endif
    private static let woodGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.07, green: 0.025, blue: 0.012, alpha: 1),
        CGColor(red: 0.22, green: 0.08, blue: 0.035, alpha: 1),
        CGColor(red: 0.11, green: 0.039, blue: 0.019, alpha: 1)
    ] as CFArray, locations: [0, 0.58, 1])!
    private static let firePalette: [UInt8] = {
        let stops: [(Double, SIMD4<Double>)] = [(0, SIMD4(0.18, 0, 0, 0)), (0.18, SIMD4(0.35, 0.012, 0, 0)),
            (0.32, SIMD4(0.65, 0.045, 0.004, 0.18)), (0.48, SIMD4(0.94, 0.17, 0.01, 0.65)),
            (0.67, SIMD4(1, 0.47, 0.035, 0.92)), (0.87, SIMD4(1, 0.76, 0.22, 1)), (1.1, SIMD4(1, 0.95, 0.72, 1))]
        var result = [UInt8](); result.reserveCapacity(4096)
        for i in 0..<1024 {
            let heat = Double(i) / 1023 * 1.1
            let right = stops.firstIndex { $0.0 >= heat } ?? stops.count - 1, left = max(0, right - 1)
            let t = right == left ? 0 : (heat - stops[left].0) / (stops[right].0 - stops[left].0)
            let color = stops[left].1 + (stops[right].1 - stops[left].1) * t
            result += [UInt8(color.x * color.w * 255), UInt8(color.y * color.w * 255), UInt8(color.z * color.w * 255), UInt8(color.w * 255)]
        }
        return result
    }()
    static func fireImage(_ model: FireplaceModel, layer: Int = 0) -> CGImage? {
        fireImage(HeatSnapshot(model), layer: layer)
    }
    static func fireImage(_ snapshot: HeatSnapshot, layer: Int) -> CGImage? {
        let heat = snapshot.values, columns = snapshot.columns, rows = snapshot.rows
        guard columns > 0, rows > 0, heat.count == columns * rows else { return nil }
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        // Edge opacity only varies by column. Convert the heat and premultiplied
        // palette with integer channel math, avoiding per-pixel array copies and
        // repeated floating-point smoothstep work in the live redraw path.
        let fades = (0..<columns).map { UInt16((edgeOpacity(column: $0, count: columns) * 255).rounded()) }
        let paletteScale = Float(1023.0 / 1.1 * (0.88 + Double(layer) * 0.11))
        pixels.withUnsafeMutableBufferPointer { output in
            heat.withUnsafeBufferPointer { samples in
                firePalette.withUnsafeBufferPointer { palette in
                    guard let output = output.baseAddress, let samples = samples.baseAddress,
                          let palette = palette.baseAddress else { return }
                    for y in 0..<rows {
                        let sampleRow = max(0, y - layer * 4) * columns
                        let outputRow = (rows - 1 - y) * columns * 4
                        for x in 0..<columns {
                            let sampleX = (x + layer * 37) % columns
                            let band = min(1023, max(0, Int(samples[sampleRow + sampleX] * paletteScale))) * 4
                            let offset = outputRow + x * 4
                            let fade = fades[x]
                            for channel in 0..<4 {
                                output[offset + channel] = UInt8((UInt16(palette[band + channel]) * fade + 127) / 255)
                            }
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    static func edgeOpacity(column: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        let distance = Double(min(column, count - 1 - column))
        let t = min(1, max(0, distance / max(1, Double(count - 1) * 0.16)))
        return t * t * (3 - 2 * t)
    }
    private static func drawBackdrop(_ image: CGImage, opening: CGRect, opacity: Double, in context: CGContext) {
        context.saveGState()
        context.clip(to: opening); context.setAlpha(opacity)
        context.interpolationQuality = .none
        let tileWidth = opening.height * 1.5
        for index in 0..<Int(ceil(opening.width / tileWidth)) {
            context.draw(image, in: CGRect(x: opening.minX + Double(index) * tileWidth, y: opening.minY,
                                           width: tileWidth, height: opening.height))
        }
        context.restoreGState()
    }
    private struct LogPiece {
        let x: Double, width: Double, rise: Double, height: Double, angle: Double
    }
    private static let logLayers: [[LogPiece]] = [
        [LogPiece(x: 0.06, width: 0.37, rise: -6, height: 25, angle: 0.12),
         LogPiece(x: 0.52, width: 0.42, rise: -7, height: 27, angle: -0.09)],
        [LogPiece(x: 0.19, width: 0.54, rise: -16, height: 31, angle: -0.14),
         LogPiece(x: 0.65, width: 0.30, rise: -8, height: 28, angle: 0.17)],
        [LogPiece(x: 0.01, width: 0.33, rise: -7, height: 31, angle: 0.16),
         LogPiece(x: 0.41, width: 0.43, rise: -12, height: 32, angle: -0.10),
         LogPiece(x: 0.78, width: 0.19, rise: -1, height: 25, angle: 0.22)]
    ]
    private static func drawLogLayer(_ layer: Int, bed: CGRect, time: Double, in context: CGContext) {
        for (index, piece) in logLayers[layer].enumerated() {
            let width = bed.width * piece.width, x = bed.minX + bed.width * piece.x
            let y = bed.minY + piece.rise
            context.saveGState()
            context.translateBy(x: x + width * 0.5, y: y + piece.height * 0.5)
            context.rotate(by: piece.angle)
            let body = CGPath(roundedRect: CGRect(x: -width * 0.5, y: -piece.height * 0.5,
                                                   width: width, height: piece.height),
                              cornerWidth: 9, cornerHeight: 9, transform: nil)
            context.saveGState(); context.addPath(body); context.clip()
            context.drawLinearGradient(woodGradient,
                start: CGPoint(x: 0, y: -piece.height * 0.5),
                end: CGPoint(x: 0, y: piece.height * 0.5), options: [])
            let grain = CGMutablePath()
            for strand in 0..<3 {
                let gy = -piece.height * 0.32 + Double(strand) * piece.height * 0.3
                grain.move(to: CGPoint(x: -width * 0.44, y: gy))
                grain.addQuadCurve(to: CGPoint(x: width * 0.42, y: gy + sin(Double(index * 5 + strand + layer * 3)) * 2),
                                   control: CGPoint(x: width * 0.04, y: gy - 3 + Double(strand)))
            }
            context.setStrokeColor(red: 0.48, green: 0.23, blue: 0.10, alpha: 0.6)
            context.setLineWidth(1.2); context.addPath(grain); context.strokePath()
            let glow = 0.58 + 0.25 * sin(time * (2.2 + Double(layer) * 0.3) + Double(index * 3 + layer))
            context.setStrokeColor(red: 1, green: 0.27, blue: 0.035, alpha: glow)
            context.setLineWidth(1.5)
            for crack in 0..<7 {
                let px = -width * 0.43 + Double(crack) * width * 0.13
                let py = sin(Double(crack * 7 + index * 11 + layer * 13)) * piece.height * 0.12
                context.move(to: CGPoint(x: px, y: py - 2))
                context.addLine(to: CGPoint(x: px + 6, y: py + 2))
            }
            context.strokePath(); context.restoreGState()
            context.setStrokeColor(red: 0.035, green: 0.014, blue: 0.006, alpha: 0.9)
            context.setLineWidth(1.5); context.addPath(body); context.strokePath()
            context.setFillColor(red: 0.32, green: 0.13, blue: 0.055, alpha: 0.95)
            context.fillEllipse(in: CGRect(x: width * 0.5 - 19, y: -piece.height * 0.5 + 4,
                                           width: 15, height: piece.height - 8))
            context.restoreGState()
        }
    }
    private static func drawMantel(_ layout: FireplaceLayout, opacity: Double, in context: CGContext) {
        guard opacity > 0 else { return }
        context.saveGState()
        context.setAlpha(opacity)
        context.setShouldAntialias(false)
        let base = floor(layout.mantelBase), length = floor(layout.length)
        func pixel(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ color: NSColor) {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: floor(x), y: floor(y), width: width, height: height))
        }
        let shadow = NSColor(calibratedRed: 0.10, green: 0.045, blue: 0.022, alpha: 1)
        let wood = NSColor(calibratedRed: 0.39, green: 0.19, blue: 0.085, alpha: 1)
        let warmWood = NSColor(calibratedRed: 0.61, green: 0.32, blue: 0.14, alpha: 1)
        let highlight = NSColor(calibratedRed: 0.76, green: 0.46, blue: 0.23, alpha: 1)
        let green = NSColor(calibratedRed: 0.12, green: 0.36, blue: 0.19, alpha: 1)
        let deepGreen = NSColor(calibratedRed: 0.045, green: 0.18, blue: 0.10, alpha: 1)
        let red = NSColor(calibratedRed: 0.82, green: 0.10, blue: 0.10, alpha: 1)
        let gold = NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.23, alpha: 1)
        let cream = NSColor(calibratedRed: 0.94, green: 0.83, blue: 0.63, alpha: 1)

        // A thirty-point timber beam sits above the slim top brick course.
        let height = FireplaceLayout.mantelHeight
        pixel(8, base - 2, length - 16, height + 2, shadow)
        pixel(10, base, length - 20, height - 1, wood)
        pixel(10, base + 3, length - 20, 2, warmWood)
        pixel(11, base + height - 7, length - 22, 2, shadow)
        pixel(8, base + height - 5, length - 16, 5, warmWood)
        pixel(9, base + height - 1, length - 18, 1, highlight)
        pixel(14, base - 4, 9, 4, shadow)
        pixel(length - 23, base - 4, 9, 4, shadow)
        for index in 0..<Int((length - 30) / 31) {
            let x = 17 + Double(index) * 31
            pixel(x, base + Double((index * 7) % 3) + 8, Double(8 + index % 5), 1,
                  index % 3 == 0 ? highlight : shadow)
            pixel(x + 14, base + 16 + Double(index % 4), 5, 1, warmWood)
            pixel(x + 3, base + 23 + Double(index % 3), 10, 1, shadow)
        }

        // The narrowing rear edge reveals a shallow shelf viewed from above.
        // Keep the front lip level so the thirty-point face reads as solid wood.
        let top = base + FireplaceLayout.mantelHeight
        let shelf = CGMutablePath()
        shelf.move(to: CGPoint(x: 6, y: top))
        shelf.addLine(to: CGPoint(x: length - 6, y: top))
        shelf.addLine(to: CGPoint(x: length - 16, y: top + 7))
        shelf.addLine(to: CGPoint(x: 16, y: top + 7))
        shelf.closeSubpath()
        context.setFillColor(NSColor(calibratedRed: 0.48, green: 0.25, blue: 0.11, alpha: 1).cgColor)
        context.addPath(shelf); context.fillPath()
        pixel(7, top, length - 14, 1, highlight)
        pixel(16, top + 6, length - 32, 1, shadow)
        for index in 0..<Int((length - 35) / 37) {
            let x = 21 + Double(index) * 37
            pixel(x, top + 2 + Double(index % 3), Double(8 + index % 6), 1,
                  index % 2 == 0 ? warmWood : shadow)
        }

        // Decorations sit at different depths on the shelf. Small shadows
        // anchor them to the wood while the elf hangs over the front lip.
        for index in 0..<Int((length - 36) / 19) {
            let x = 19 + Double(index) * 19
            pixel(x, top + 5, 13, 2, deepGreen)
            pixel(x + 2, top + 7, 5, 2, green)
            pixel(x + 8, top + 6, 4, 2, green)
            if index % 3 == 1 { pixel(x + 6, top + 8, 2, 2, red) }
        }
        for fraction in [0.14, 0.86] {
            let x = floor(length * fraction)
            pixel(x - 3, top + 4, 10, 2, shadow)
            pixel(x, top + 5, 4, 7, cream)
            pixel(x + 1, top + 12, 2, 2, gold)
            pixel(x + 1, top + 14, 2, 2, red)
        }
        for (fraction, color, depth) in [(0.26, red, 2.0), (0.74, green, 4.0)] {
            let x = floor(length * fraction)
            pixel(x - 7, top + depth - 1, 14, 2, shadow)
            pixel(x - 6, top + depth, 12, 8, shadow)
            pixel(x - 5, top + depth + 1, 10, 6, color)
            pixel(x - 1, top + depth + 1, 2, 7, gold)
            pixel(x - 5, top + depth + 4, 10, 1, gold)
        }
        for (fraction, depth) in [(0.39, 4.0), (0.61, 2.0)] {
            let x = floor(length * fraction)
            pixel(x - 1, top + depth, 3, 2, shadow)
            pixel(x - 5, top + depth + 2, 11, 3, deepGreen)
            pixel(x - 3, top + depth + 5, 7, 3, green)
            pixel(x - 1, top + depth + 8, 3, 3, green)
            pixel(x, top + depth + 11, 1, 2, gold)
        }
        let middle = floor(length * 0.5)
        pixel(middle - 14, top + 2, 28, 2, shadow)
        pixel(middle - 13, top + 3, 26, 12, shadow)
        pixel(middle - 11, top + 5, 22, 8, warmWood)
        pixel(middle - 9, top + 6, 18, 6,
              NSColor(calibratedRed: 0.21, green: 0.37, blue: 0.48, alpha: 1))
        pixel(middle - 7, top + 7, 6, 2, cream)
        pixel(middle + 1, top + 7, 7, 2, cream)
        pixel(middle - 1, top + 8, 2, 4, deepGreen)
        pixel(middle - 3, top + 9, 6, 2, green)
        // A seated elf has its boots over the lip and its pointed cap above
        // the greenery. Keep every pixel within the transparent top margin.
        let elf = floor(length * 0.61)
        let skin = NSColor(calibratedRed: 0.96, green: 0.69, blue: 0.49, alpha: 1)
        let hair = NSColor(calibratedRed: 0.35, green: 0.18, blue: 0.09, alpha: 1)
        pixel(elf - 7, top - 6, 4, 10, red)
        pixel(elf + 3, top - 6, 4, 10, red)
        pixel(elf - 9, top - 7, 6, 3, deepGreen)
        pixel(elf + 3, top - 7, 7, 3, deepGreen)
        pixel(elf - 8, top + 3, 16, 7, red)
        pixel(elf - 11, top + 4, 3, 6, red)
        pixel(elf + 8, top + 4, 3, 6, red)
        pixel(elf - 11, top + 3, 3, 3, skin)
        pixel(elf + 8, top + 3, 3, 3, skin)
        pixel(elf - 7, top + 9, 14, 2, cream)
        pixel(elf - 5, top + 11, 10, 6, skin)
        pixel(elf - 6, top + 14, 2, 3, hair)
        pixel(elf + 4, top + 14, 2, 3, hair)
        pixel(elf - 3, top + 14, 1, 1, shadow)
        pixel(elf + 2, top + 14, 1, 1, shadow)
        pixel(elf - 1, top + 12, 2, 1, red)
        pixel(elf - 7, top + 17, 14, 2, cream)
        pixel(elf - 7, top + 19, 13, 1, red)
        pixel(elf + 5, top + 18, 3, 2, cream)
        context.restoreGState()
    }
    static func staticImage(_ model: FireplaceModel) -> (image: CGImage, frame: CGRect)? {
        let frame = model.layout.frame.insetBy(dx: -6, dy: -6).integral
        guard let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        drawStatic(model, context: context, worldRect: frame)
        guard let image = context.makeImage() else { return nil }
        return (image, frame)
    }
    static func draw(_ model: FireplaceModel, context: CGContext, worldRect: CGRect,
                     staticArt: (image: CGImage, frame: CGRect)? = nil, fireImages: [CGImage]? = nil) {
        guard model.isVisible else { return }
        if let staticArt {
            context.draw(staticArt.image, in: staticArt.frame.offsetBy(dx: -worldRect.minX, dy: -worldRect.minY))
        } else {
            drawStatic(model, context: context, worldRect: worldRect)
        }
        drawFire(model, context: context, worldRect: worldRect, fireImages: fireImages)
    }
    private static func drawStatic(_ model: FireplaceModel, context: CGContext, worldRect: CGRect) {
        context.saveGState(); context.translateBy(x: -worldRect.minX, y: -worldRect.minY)
        context.saveGState(); context.concatenate(model.layout.transform)
        let opening = model.layout.opening
        context.setShouldAntialias(true)
        context.setFillColor(red: 0.025, green: 0.018, blue: 0.014, alpha: model.backingOpacity)
        context.fill(CGRect(x: 1, y: 0, width: model.layout.length - 2,
                            height: model.layout.mantelBase))
        context.setFillColor(red: 0.005, green: 0.004, blue: 0.003, alpha: model.backingOpacity)
        context.fill(opening)
        if let backdropImage { drawBackdrop(backdropImage, opening: opening, opacity: model.backingOpacity, in: context) }
        context.restoreGState()
        for pose in model.poses() where pose.alpha > 0.001 {
            context.saveGState(); context.setAlpha(pose.alpha)
            context.translateBy(x: pose.rect.midX, y: pose.rect.midY); context.rotate(by: pose.angle)
            context.setShouldAntialias(false)
            let rect = CGRect(x: -pose.rect.width / 2, y: -pose.rect.height / 2, width: pose.rect.width, height: pose.rect.height)
            context.setFillColor(red: 0.20, green: 0.16, blue: 0.13, alpha: 1); context.fill(rect)
            let face = rect.insetBy(dx: 1.2, dy: 1.2)
            context.setFillColor(red: 0.42 + pose.shade * 0.18, green: 0.16 + pose.shade * 0.09, blue: 0.09 + pose.shade * 0.05, alpha: 1)
            context.fill(face)
            context.setFillColor(red: 0.76, green: 0.39, blue: 0.22, alpha: 0.45)
            context.fill(CGRect(x: face.minX + 1, y: face.maxY - 2, width: max(0, face.width - 2), height: 1.5))
            context.setFillColor(red: 0.14, green: 0.06, blue: 0.035, alpha: 0.35)
            context.fill(CGRect(x: face.minX, y: face.minY, width: face.width, height: 2))
            if face.width > 10 && face.height > 6 {
                context.fill(CGRect(x: face.midX - 3 + pose.shade * 4, y: face.midY, width: 3, height: 2))
            }
            context.restoreGState()
        }
        context.saveGState()
        context.concatenate(model.layout.transform)
        drawMantel(model.layout, opacity: model.backingOpacity, in: context)
        context.restoreGState()
        context.restoreGState()
    }
    private static func drawFire(_ model: FireplaceModel, context: CGContext, worldRect: CGRect,
                                 fireImages: [CGImage]?) {
        context.saveGState(); context.translateBy(x: -worldRect.minX, y: -worldRect.minY)
        context.concatenate(model.layout.transform)
        let opening = model.layout.opening
        let logs = model.layout.logBed
        let flames = model.layout.flameRect
        context.setShouldAntialias(true)
        context.saveGState(); context.clip(to: opening)
        context.interpolationQuality = .high
        if let image = fireImages?.first ?? fireImage(model, layer: 0) {
            context.setAlpha(model.ignition * 0.78)
            context.draw(image, in: flames)
        }
        context.setAlpha(model.ignition)
        drawLogLayer(0, bed: logs, time: model.time, in: context)
        if let image = fireImages.flatMap({ $0.count > 1 ? $0[1] : nil }) ?? fireImage(model, layer: 1) {
            context.setAlpha(model.ignition * 0.66)
            context.draw(image, in: CGRect(x: flames.minX + flames.width * 0.07, y: flames.minY - 4,
                                           width: flames.width * 0.86, height: flames.height * 0.78))
        }
        context.setAlpha(model.ignition)
        drawLogLayer(1, bed: logs, time: model.time, in: context)
        if let image = fireImages.flatMap({ $0.count > 2 ? $0[2] : nil }) ?? fireImage(model, layer: 2) {
            context.setAlpha(model.ignition * 0.48)
            context.draw(image, in: CGRect(x: flames.minX + flames.width * 0.14, y: flames.minY - 8,
                                           width: flames.width * 0.72, height: flames.height * 0.54))
        }
        context.setAlpha(model.ignition)
        drawLogLayer(2, bed: logs, time: model.time, in: context)
        // A few dim embers rise independently through the firebox.
        for ember in 0..<16 {
            let speed = 0.17 + Double((ember * 7) % 13) * 0.014
            let age = (model.time * speed + Double(ember) * 0.61803399).truncatingRemainder(dividingBy: 1)
            let x = flames.minX + flames.width * Double((ember * 31 + 7) % 101) / 101 + sin(age * 7 + Double(ember)) * 9
            let y = flames.minY + age * flames.height
            let alpha = sin(age * .pi) * 0.55
            context.setFillColor(red: 1, green: 0.58, blue: 0.15, alpha: alpha)
            context.fillEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 2.2))
        }
        context.restoreGState()
        context.restoreGState()
    }
    static func fallbackSmoke(object: CGRect, progress: Double, strength: Double, context: CGContext, worldRect: CGRect) {
        let opacity = min(1, progress / 0.08) * pow(max(0, 1 - progress), 1.5) * strength
        guard opacity > 0 else { return }
        context.saveGState(); context.translateBy(x: -worldRect.minX, y: -worldRect.minY)
        for i in 0..<18 {
            let f = Double(i) / 17, wave = sin(Double(i) * 2.7)
            let x = object.minX + f * object.width + wave * progress * 60
            let y = object.midY + sin(Double(i) * 4.1) * object.height * 0.3 + progress * (85 + f * 35)
            let radius = 22 + progress * 50 + Double(i % 3) * 8
            context.setFillColor(red: 0.65, green: 0.65, blue: 0.65, alpha: opacity * 0.08)
            for ring in stride(from: 1.5, through: 0.5, by: -0.25) {
                context.fillEllipse(in: CGRect(x: x - radius * ring, y: y - radius * ring, width: radius * ring * 2, height: radius * ring * 2))
            }
        }
        context.restoreGState()
    }
}

private final class FireplacePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class FireplaceView: NSView {
    var model: FireplaceModel?
    var worldRect = CGRect.zero
    var fallback: [(CGRect, Double, Double)] = []
    var fireImages: [CGImage]?
    private var staticCache: (layoutFrame: CGRect, edge: FireplaceLayout.Edge, image: CGImage, imageFrame: CGRect)?
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (object, progress, strength) in fallback { FireplaceDrawing.fallbackSmoke(object: object, progress: progress, strength: strength, context: context, worldRect: worldRect) }
        if let model {
            if model.phase == .burning {
                if staticCache?.layoutFrame != model.layout.frame || staticCache?.edge != model.layout.edge {
                    staticCache = nil
                    if let art = FireplaceDrawing.staticImage(model) {
                        staticCache = (model.layout.frame, model.layout.edge, art.image, art.frame)
                    }
                }
            } else { staticCache = nil }
            let art = staticCache.map { (image: $0.image, frame: $0.imageFrame) }
            FireplaceDrawing.draw(model, context: context, worldRect: worldRect,
                                  staticArt: art, fireImages: fireImages)
        }
    }
}
private final class FireplaceSmoke {
    let object: CGRect
    let rect: CGRect
    let strength: Float
    var elapsed = 0.0
    var renderer: ProceduralEffects?
    var surface: EffectSurface?
    init(object: CGRect, strength: Float, renderer: ProceduralEffects?) {
        self.object = object; self.strength = strength; self.renderer = renderer
        rect = object.insetBy(dx: -140, dy: -160)
    }
}

/// Active fireplaces borrow Snow Storm's clock. A detached departure owns only
/// a finite clock, which invalidates itself when the last puff becomes transparent.
final class FireplaceController {
    let model: FireplaceModel
    private let screens: () -> [StaticEffectScreen]
    private let present: (NSPanel) -> Void
    private var dock: FireplaceDock?
    private var widthFraction = 0.5
    private var height = 158.0
    private var offset = 0.0
    private var panel: NSPanel?
    private let drawing = FireplaceView()
    private var renderer: ProceduralEffects?
    private var smoke: [FireplaceSmoke] = []
    private var departureClock: Timer?
    private var previousTick = 0.0
    private var lastFireFrame = -1
    private let rasterQueue = DispatchQueue(label: "app.jimmytweaks.fireplace-raster", qos: .userInitiated)
    private var rasterInFlight = false
    private var stopped = false
    var onFinished: (() -> Void)?
    init?(screens: @escaping () -> [StaticEffectScreen], present: @escaping (NSPanel) -> Void = { $0.orderFrontRegardless() }, allowGPU: Bool = true) {
        guard let layout = FireplaceLayout.resolve(screens: screens().map(\.frame), dock: nil) else { return nil }
        self.screens = screens; self.present = present; model = FireplaceModel(layout: layout)
        model.setEnabled(true)
        if allowGPU {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let renderer = ProceduralEffects()
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.renderer = renderer
                    for puff in self.smoke where puff.renderer == nil { puff.renderer = renderer?.makeSibling() }
                }
            }
        }
    }
    deinit { shutdown() }
    func setEnabled(_ enabled: Bool) {
        guard !stopped else { return }
        if !enabled && (model.phase == .assembling || model.phase == .burning) {
            let puff = FireplaceSmoke(object: model.layout.frame, strength: Float(max(0.2, model.backingOpacity)), renderer: renderer?.makeSibling())
            if smoke.count >= 2 { smoke.removeFirst().surface?.removeFromSuperview() }
            smoke.append(puff)
        }
        model.setEnabled(enabled)
    }
    func updateDock(_ dock: FireplaceDock?) {
        let previous = self.dock == nil ? nil : model.layout
        if let layout = FireplaceLayout.resolve(screens: screens().map(\.frame), dock: dock,
                                                previous: previous, widthFraction: widthFraction, height: height, offset: offset) { model.setLayout(layout) }
        if let dock { self.dock = dock }
    }
    func setWidthFraction(_ value: Double) {
        let next = min(0.8, max(0.3, value))
        guard next != widthFraction else { return }
        widthFraction = next
        // A deliberate slider change can shrink a previously magnified Dock
        // envelope; routine Dock samples still retain that envelope.
        if let layout = FireplaceLayout.resolve(screens: screens().map(\.frame), dock: dock,
                                                widthFraction: widthFraction, height: height, offset: offset) { model.setLayout(layout) }
    }
    func setHeight(_ value: Double) {
        let next = min(320, max(80, value))
        guard next != height else { return }
        height = next
        if let layout = FireplaceLayout.resolve(screens: screens().map(\.frame), dock: dock,
                                                previous: model.layout, widthFraction: widthFraction,
                                                height: height, offset: offset) { model.setLayout(layout) }
    }
    func setOffset(_ value: Double) {
        let next = min(1, max(-1, value))
        guard next != offset else { return }
        offset = next
        if let layout = FireplaceLayout.resolve(screens: screens().map(\.frame), dock: dock,
                                                previous: model.layout, widthFraction: widthFraction,
                                                height: height, offset: offset) { model.setLayout(layout) }
    }
    func advance(_ dt: Double) {
        guard !stopped, dt.isFinite, dt > 0 else { return }
        let delta = min(1.0 / 15, max(0, dt))
        model.advance(delta)
        for puff in smoke { puff.elapsed += delta }
        smoke.removeAll { puff in
            if puff.elapsed >= FireplaceModel.departureDuration { puff.surface?.removeFromSuperview(); return true }
            return false
        }
        if !model.isVisible && smoke.isEmpty {
            panel?.orderOut(nil); panel = nil
            departureClock?.invalidate(); departureClock = nil
            onFinished?(); return
        }
        let frame = Int(model.time * 24)
        if model.phase == .burning && smoke.isEmpty && frame == lastFireFrame { return }
        if model.phase == .burning { scheduleFireImages() }
        else { drawing.fireImages = nil }
        lastFireFrame = frame
        render()
    }
    private func scheduleFireImages() {
        guard !rasterInFlight else { return }
        rasterInFlight = true
        let snapshot = FireplaceDrawing.HeatSnapshot(model)
        rasterQueue.async { [weak self] in
            let images = (0..<3).compactMap { FireplaceDrawing.fireImage(snapshot, layer: $0) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rasterInFlight = false
                guard !self.stopped, self.model.phase == .burning,
                      self.model.columns == snapshot.columns, self.model.rows == snapshot.rows,
                      images.count == 3 else { return }
                self.drawing.fireImages = images
                self.drawing.needsDisplay = true
            }
        }
    }
    func dissolveIndependently() {
        setEnabled(false)
        guard departureClock == nil else { return }
        guard model.isVisible || !smoke.isEmpty else { onFinished?(); return }
        previousTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.advance(now - self.previousTick); self.previousTick = now
        }
        timer.tolerance = 0.002; RunLoop.main.add(timer, forMode: .common); departureClock = timer
    }
    private func render() {
        let layout = model.layout
        var viewport = model.phase == .assembling ? layout.screen : layout.frame.insetBy(dx: -6, dy: -6)
        for puff in smoke { viewport = viewport.union(puff.rect) }
        viewport = viewport.intersection(layout.screen)
        guard !viewport.isEmpty else { return }
        let panel: NSPanel
        if let existing = self.panel { panel = existing }
        else {
            panel = FireplacePanel(contentRect: viewport, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.acceptsMouseMovedEvents = false
            panel.isReleasedWhenClosed = false
            // Sit just above the wallpaper, below desktop icons, normal app
            // windows, and the Dock, regardless of which app gains focus.
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.setAccessibilityHidden(true)
            let root = NSView(frame: CGRect(origin: .zero, size: viewport.size)); root.wantsLayer = true; root.layer?.masksToBounds = true
            drawing.setAccessibilityHidden(true); root.addSubview(drawing); panel.contentView = root
            self.panel = panel; present(panel)
        }
        if panel.frame != viewport { panel.setFrame(viewport, display: false) }
        let bounds = CGRect(origin: .zero, size: viewport.size)
        drawing.frame = bounds; drawing.model = model; drawing.worldRect = viewport
        drawing.fallback = []
        for puff in smoke {
            let progress = Float(puff.elapsed / FireplaceModel.departureDuration)
            if let renderer = puff.renderer, !renderer.failed,
               renderer.configureSmokePuff(rect: puff.rect, object: puff.object, progress: progress, strength: puff.strength) {
                let surface = puff.surface ?? EffectSurface(renderer: renderer)
                if puff.surface == nil { panel.contentView?.addSubview(surface, positioned: .below, relativeTo: drawing); puff.surface = surface }
                surface.frame = bounds; surface.worldRect = viewport
                surface.drawableSize = CGSize(width: ceil(viewport.width * panel.backingScaleFactor), height: ceil(viewport.height * panel.backingScaleFactor))
                if !renderer.render(surfaces: [surface], at: ProcessInfo.processInfo.systemUptime) {
                    puff.surface?.removeFromSuperview(); puff.surface = nil; puff.renderer = nil
                    drawing.fallback.append((puff.object, Double(progress), Double(puff.strength)))
                }
            } else {
                puff.surface?.removeFromSuperview(); puff.surface = nil
                drawing.fallback.append((puff.object, Double(progress), Double(puff.strength)))
            }
        }
        drawing.needsDisplay = true
    }
    func shutdown() {
        stopped = true; departureClock?.invalidate(); departureClock = nil
        panel?.orderOut(nil); panel = nil
        smoke.removeAll(); renderer = nil; drawing.fireImages = nil
    }
    var allPanels: [NSPanel] { panel.map { [$0] } ?? [] }
    var finished: Bool { !model.isVisible && smoke.isEmpty }
    #if TESTING
    var departureTimerForTesting: Bool { departureClock != nil }
    var smokeCountForTesting: Int { smoke.count }
    var fireImagesReadyForTesting: Bool { drawing.fireImages?.count == 3 }
    #endif
}
