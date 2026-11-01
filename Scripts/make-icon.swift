import AppKit

// Compile together with Sources/App/BrandIcon.swift.
@main
struct MakeIcon {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var bitmaps: [Int: Data] = [:]
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let image = BrandIcon.applicationImage(size: CGFloat(pixels))
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
    }
}
