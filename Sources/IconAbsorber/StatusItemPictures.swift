import AppKit
import ScreenCaptureKit

enum StatusItemPictures {
    /// Captures only the native menu-bar window, never underlying application windows.
    /// No permission prompt here: picture capture is an explicit optional user action.
    static func capture(_ items: [AbsorbedStatusItem], knownItems: [AbsorbedStatusItem], completion: @escaping ([String: NSImage]) -> Void) {
        guard CGPreflightScreenCaptureAccess(), !items.isEmpty else { completion([:]); return }
        Task {
            var pictures: [String: NSImage] = [:]
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let bars = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent" && $0.frame.height <= 100 && $0.frame.width > 200 }
                for bar in bars {
                    let targets = items.filter { item in
                        guard let frame = item.frame, bar.frame.contains(frame), frame.width >= 10, frame.height >= 10 else { return false }
                        let interior = frame.insetBy(dx: min(5, frame.width / 4), dy: 2)
                        return !knownItems.contains { $0.id != item.id && $0.frame?.insetBy(dx: 4, dy: 2).intersects(interior) == true }
                    }
                    guard !targets.isEmpty else { continue }
                    let filter = SCContentFilter(desktopIndependentWindow: bar)
                    let config = SCStreamConfiguration()
                    config.width = Int(bar.frame.width * 2); config.height = Int(bar.frame.height * 2)
                    config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.includeChildWindows = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let sx = CGFloat(image.width) / bar.frame.width, sy = CGFloat(image.height) / bar.frame.height
                    for item in targets {
                        guard let frame = item.frame?.insetBy(dx: 3, dy: 2) else { continue }
                        let crop = CGRect(x: (frame.minX - bar.frame.minX) * sx, y: (frame.minY - bar.frame.minY) * sy,
                                          width: frame.width * sx, height: frame.height * sy).integral
                        guard let glyph = image.cropping(to: crop), hasVisiblePixels(glyph) else { continue }
                        pictures[item.id] = NSImage(cgImage: glyph, size: frame.size)
                    }
                }
            } catch { /* Missing capture permission or inaccessible surfaces use application icons. */ }
            DispatchQueue.main.async { completion(pictures) }
        }
    }
    private static func hasVisiblePixels(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            let visible = stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 25 }
            let variation = (0..<4).contains { channel in
                let samples = stride(from: channel, to: bytes.count, by: 4).map { Int(bytes[$0]) }
                return (samples.max() ?? 0) - (samples.min() ?? 0) > 20
            }
            return visible && variation
        }
    }
}
