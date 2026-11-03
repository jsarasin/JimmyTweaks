import Foundation
import CoreGraphics

enum WindowCorner: Int, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var name: String { ["top-left", "top-right", "bottom-left", "bottom-right"][rawValue] }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
    func point(in frame: CGRect) -> CGPoint {
        CGPoint(x: isLeft ? frame.minX : frame.maxX, y: isTop ? frame.minY : frame.maxY)
    }
    func anchor(in frame: CGRect) -> CGPoint {
        CGPoint(x: isLeft ? frame.maxX : frame.minX, y: isTop ? frame.maxY : frame.minY)
    }
    func origin(size: CGSize, anchor: CGPoint) -> CGPoint {
        CGPoint(x: isLeft ? anchor.x - size.width : anchor.x, y: isTop ? anchor.y - size.height : anchor.y)
    }
}

enum GestureKind: Equatable {
    case resize(WindowCorner)
    case move
    var name: String {
        if case .resize(let corner) = self { return "resize.\(corner.name)" }
        return "move"
    }
}

struct GestureSeed: Equatable {
    var frame: CGRect
    var pointer: CGPoint
    var kind: GestureKind
    func desiredFrame(at point: CGPoint) -> CGRect {
        let dx = point.x - pointer.x, dy = point.y - pointer.y
        switch kind {
        case .move: return frame.offsetBy(dx: dx, dy: dy)
        case .resize(let corner):
            let size = CGSize(width: max(1, frame.width + (corner.isLeft ? -dx : dx)),
                              height: max(1, frame.height + (corner.isTop ? -dy : dy)))
            return CGRect(origin: corner.origin(size: size, anchor: corner.anchor(in: frame)), size: size)
        }
    }
}

/// A transaction always uses the original target and pointer offset, even when
/// the pointer leaves its frame or the window manager constrains the result.
enum WindowFrameTransaction {
    enum Failure: Error { case incompatible }

    static func apply(seed: GestureSeed, pointer: CGPoint, restoring: Bool = false,
                      check: () throws -> Void,
                      readFrame: () throws -> CGRect,
                      setPosition: (CGPoint) throws -> Void, setSize: (CGSize) throws -> Void) throws -> CGRect {
        try check()
        let desired = restoring ? seed.frame : seed.desiredFrame(at: pointer)
        let current = try readFrame()
        if WindowGeometry.approximatelyEqual(current, desired) { return current }
        switch seed.kind {
        case .move:
            try check(); try setPosition(desired.origin)
            try check()
            let accepted = try readFrame()
            guard abs(accepted.width - seed.frame.width) <= 0.5,
                  abs(accepted.height - seed.frame.height) <= 0.5 else { throw Failure.incompatible }
            return accepted
        case .resize(let corner):
            // AX position and size are separate writes. Make room before growing
            // left/up so the temporary frame does not extend past the opposite
            // screen edge or Dock. Defer right/down movement until after shrinking.
            let preparation = CGPoint(x: min(current.minX, desired.minX), y: min(current.minY, desired.minY))
            if WindowGeometry.distance(current.origin, preparation) > 0.5 {
                try check(); try setPosition(preparation)
            }
            try check(); try setSize(desired.size)
            try check()
            var accepted = try readFrame()
            guard WindowGeometry.valid(accepted) else { throw Failure.incompatible }
            let anchor = corner.anchor(in: seed.frame)
            let origin = restoring ? desired.origin : corner.origin(size: accepted.size, anchor: anchor)
            if WindowGeometry.distance(accepted.origin, origin) > 0.5 {
                try check(); try setPosition(origin)
                try check(); accepted = try readFrame()
                let correction = corner.origin(size: accepted.size, anchor: anchor)
                // Only retry if positioning changed the size. Repeating a denied
                // position fights the same constraint without making progress.
                if !restoring, WindowGeometry.distance(correction, origin) > 0.5,
                   WindowGeometry.distance(accepted.origin, correction) > 0.5 {
                    try check(); try setPosition(correction)
                    try check(); accepted = try readFrame()
                }
            }
            // Position/size constraints and delayed AX readback are recoverable.
            // Keep consuming the same global drag; reversing can resize again.
            return accepted
        }
    }
}

enum WindowGeometry {
    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    static func valid(_ r: CGRect) -> Bool {
        [r.origin.x, r.origin.y, r.width, r.height].allSatisfy(\.isFinite) && r.width > 0 && r.height > 0
    }
    /// Keep a reachable centre on short windows (notably Terminal's default
    /// 24-row size) while retaining one shared, gap-free edge boundary.
    static func effectiveEdgeZoneSize(frame: CGRect, requested: Double) -> Double {
        let shorter = min(frame.width, frame.height)
        let centre = min(shorter * 0.5, max(96, min(200, shorter * 0.4)))
        return min(requested, max(0, (shorter - centre) * 0.5))
    }
    /// One boundary owns the entire frame: its outer band resizes and its centre moves.
    /// The boundary itself belongs to resizing, including where bands meet on small windows.
    static func activationKind(at point: CGPoint, frame: CGRect, edgeZoneSize: Double) -> GestureKind? {
        guard valid(frame), edgeZoneSize.isFinite, edgeZoneSize >= 0,
              point.x >= frame.minX - 0.5, point.x <= frame.maxX + 0.5,
              point.y >= frame.minY - 0.5, point.y <= frame.maxY + 0.5 else { return nil }
        let edgeDistance = min(point.x - frame.minX, frame.maxX - point.x,
                               point.y - frame.minY, frame.maxY - point.y)
        guard edgeDistance <= effectiveEdgeZoneSize(frame: frame, requested: edgeZoneSize) else { return .move }
        let corner = WindowCorner.allCases.min {
            let a = distance($0.point(in: frame), point), b = distance($1.point(in: frame), point)
            return abs(a - b) < 0.0001 ? $0.rawValue < $1.rawValue : a < b
        }!
        return .resize(corner)
    }
    static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: Double = 0.5) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

struct RetryBudget {
    private(set) var attempts: [TimeInterval] = []
    private(set) var consecutive = 0
    mutating func nextDelay(now: TimeInterval) -> TimeInterval? {
        attempts.removeAll { now - $0 >= 60 }
        guard attempts.count < 3, consecutive < 3 else { return nil }
        let delay = pow(2.0, Double(consecutive))
        attempts.append(now); consecutive += 1
        return delay
    }
    mutating func reset() { attempts.removeAll(); consecutive = 0 }
}
