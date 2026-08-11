import Foundation

/// A 2D point.
///
/// Coordinate convention for the whole pipeline: **wall space**, normalized to
/// `[0, 1]` on both axes, origin bottom-left, **y increasing upward**. This
/// matches Vision's normalized image space and matches how climbers think
/// (higher on the route = larger y).
///
/// Pixel coordinates never escape `PoseExtractor` / `WallAligner`.
public struct Point2D: Sendable, Codable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2D(x: 0, y: 0)

    public static func + (a: Point2D, b: Point2D) -> Point2D { Point2D(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Point2D, b: Point2D) -> Point2D { Point2D(x: a.x - b.x, y: a.y - b.y) }
    public static func * (p: Point2D, s: Double) -> Point2D { Point2D(x: p.x * s, y: p.y * s) }
    public static func * (s: Double, p: Point2D) -> Point2D { p * s }
    public static func / (p: Point2D, s: Double) -> Point2D { Point2D(x: p.x / s, y: p.y / s) }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Point2D) -> Double { (self - other).length }

    /// Angle in degrees between the vectors `self -> a` and `self -> b`.
    public func angleDegrees(_ a: Point2D, _ b: Point2D) -> Double {
        let u = a - self
        let v = b - self
        let lu = u.length
        let lv = v.length
        guard lu > 1e-9, lv > 1e-9 else { return .nan }
        let cosine = ((u.x * v.x + u.y * v.y) / (lu * lv)).clamped(to: -1 ... 1)
        return acos(cosine) * 180 / .pi
    }
}

/// A 3×3 homography, row-major. Kept as a plain value type so it is `Codable`
/// and `Sendable` without dragging simd into the model layer.
public struct Homography: Sendable, Codable, Hashable {
    /// Row-major, 9 elements.
    public var m: [Double]

    public init(m: [Double]) {
        precondition(m.count == 9, "Homography needs 9 elements")
        self.m = m
    }

    public static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    public var isIdentity: Bool {
        zip(m, Homography.identity.m).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    /// Applies the homography to a point in normalized coordinates.
    public func apply(to p: Point2D) -> Point2D {
        let w = m[6] * p.x + m[7] * p.y + m[8]
        guard abs(w) > 1e-12 else { return p }
        return Point2D(
            x: (m[0] * p.x + m[1] * p.y + m[2]) / w,
            y: (m[3] * p.x + m[4] * p.y + m[5]) / w
        )
    }

    public func concatenated(with other: Homography) -> Homography {
        var out = [Double](repeating: 0, count: 9)
        for r in 0 ..< 3 {
            for c in 0 ..< 3 {
                var sum = 0.0
                for k in 0 ..< 3 { sum += other.m[r * 3 + k] * m[k * 3 + c] }
                out[r * 3 + c] = sum
            }
        }
        return Homography(m: out)
    }

    /// Inverse via adjugate. Returns `nil` for a singular matrix.
    public var inverted: Homography? {
        let a = m
        let c00 = a[4] * a[8] - a[5] * a[7]
        let c01 = a[5] * a[6] - a[3] * a[8]
        let c02 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c00 + a[1] * c01 + a[2] * c02
        guard abs(det) > 1e-12 else { return nil }
        let c10 = a[2] * a[7] - a[1] * a[8]
        let c11 = a[0] * a[8] - a[2] * a[6]
        let c12 = a[1] * a[6] - a[0] * a[7]
        let c20 = a[1] * a[5] - a[2] * a[4]
        let c21 = a[2] * a[3] - a[0] * a[5]
        let c22 = a[0] * a[4] - a[1] * a[3]
        let inv = [c00, c10, c20, c01, c11, c21, c02, c12, c22].map { $0 / det }
        return Homography(m: inv)
    }
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Array where Element == Double {
    /// Linearly-interpolated percentile. `p` in `0...1`. Returns `nil` when empty.
    public func percentile(_ p: Double) -> Double? {
        guard !isEmpty else { return nil }
        let sorted = self.sorted()
        if sorted.count == 1 { return sorted[0] }
        let pos = (Double(sorted.count - 1) * p.clamped(to: 0 ... 1))
        let lo = Int(pos.rounded(.down))
        let hi = Swift.min(lo + 1, sorted.count - 1)
        let t = pos - Double(lo)
        return sorted[lo] * (1 - t) + sorted[hi] * t
    }

    public var mean: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }

    public var median: Double? { percentile(0.5) }
}
