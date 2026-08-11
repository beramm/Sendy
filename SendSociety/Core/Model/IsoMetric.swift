import Foundation

/// Wall space is normalized to `[0,1]` on both axes, which means it is
/// **anisotropic** on a non-square frame: one x-unit is `W/H` times longer than
/// one y-unit in the real world.
///
/// That is harmless for storage and rendering, and wrong for measurement — limb
/// length would depend on limb orientation, which would corrupt the
/// foreshortening depth estimate outright. So every distance in the pipeline
/// goes through this type instead of `Point2D.distance(to:)` directly.
public struct IsoMetric: Sendable, Hashable, Codable {
    /// Multiply x by this to get units of the same physical size as y.
    public var xScale: Double

    public init(xScale: Double) {
        self.xScale = xScale > 0 ? xScale : 1
    }

    public static let square = IsoMetric(xScale: 1)

    public init(sequence: PoseSequence) {
        self.init(xScale: sequence.xScale)
    }

    public func vector(from a: Point2D, to b: Point2D) -> Point2D {
        Point2D(x: (b.x - a.x) * xScale, y: b.y - a.y)
    }

    public func distance(_ a: Point2D, _ b: Point2D) -> Double {
        vector(from: a, to: b).length
    }

    public func length(_ v: Point2D) -> Double {
        Point2D(x: v.x * xScale, y: v.y).length
    }

    /// Angle at `vertex` between `a` and `b`, aspect-corrected.
    public func angleDegrees(vertex: Point2D, _ a: Point2D, _ b: Point2D) -> Double {
        let u = vector(from: vertex, to: a)
        let v = vector(from: vertex, to: b)
        let lu = u.length, lv = v.length
        guard lu > 1e-9, lv > 1e-9 else { return .nan }
        let c = ((u.x * v.x + u.y * v.y) / (lu * lv)).clamped(to: -1 ... 1)
        return acos(c) * 180 / .pi
    }
}
