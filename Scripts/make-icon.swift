import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var bitmaps: [Int: Data] = [:]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { rect in
            let unit = CGFloat(pixels) / 1024
            let background = NSBezierPath(roundedRect: rect.insetBy(dx: 55 * unit, dy: 55 * unit), xRadius: 210 * unit, yRadius: 210 * unit)
            NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.24, blue: 0.43, alpha: 1), ending: NSColor(calibratedRed: 0.22, green: 0.51, blue: 0.68, alpha: 1))!.draw(in: background, angle: -40)
            let window = NSBezierPath(roundedRect: NSRect(x: 215 * unit, y: 250 * unit, width: 594 * unit, height: 524 * unit), xRadius: 58 * unit, yRadius: 58 * unit)
            NSColor.white.withAlphaComponent(0.2).setFill(); window.fill()
            NSColor.white.withAlphaComponent(0.95).setStroke(); window.lineWidth = 27 * unit; window.stroke()
            let divider = NSBezierPath(); divider.move(to: NSPoint(x: 225 * unit, y: 660 * unit)); divider.line(to: NSPoint(x: 799 * unit, y: 660 * unit)); divider.lineWidth = 22 * unit; divider.stroke()
            let arrow = NSBezierPath(); arrow.lineWidth = 46 * unit; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
            arrow.move(to: NSPoint(x: 390 * unit, y: 390 * unit)); arrow.line(to: NSPoint(x: 650 * unit, y: 590 * unit))
            arrow.move(to: NSPoint(x: 390 * unit, y: 505 * unit)); arrow.line(to: NSPoint(x: 390 * unit, y: 390 * unit)); arrow.line(to: NSPoint(x: 510 * unit, y: 390 * unit))
            arrow.move(to: NSPoint(x: 530 * unit, y: 590 * unit)); arrow.line(to: NSPoint(x: 650 * unit, y: 590 * unit)); arrow.line(to: NSPoint(x: 650 * unit, y: 475 * unit))
            NSColor(calibratedRed: 0.69, green: 0.93, blue: 0.92, alpha: 1).setStroke(); arrow.stroke()
            return true
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.clear(NSRect(x: 0, y: 0, width: pixels, height: pixels))
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let data = bitmap.representation(using: .png, properties: [:])!
        bitmaps[pixels] = data
        try data.write(to: output.appendingPathComponent(name))
    }
}
// ICNS accepts PNG payloads in the modern size chunks. Assemble the container locally;
// no Icon Services helper or access outside the supplied output directory is needed.
func bigEndian(_ value: UInt32) -> Data { var n = value.bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
var chunks = Data()
for (type, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    let png = bitmaps[size]!
    chunks.append(Data(type.utf8)); chunks.append(bigEndian(UInt32(png.count + 8))); chunks.append(png)
}
var icns = Data("icns".utf8); icns.append(bigEndian(UInt32(chunks.count + 8))); icns.append(chunks)
try icns.write(to: output.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
