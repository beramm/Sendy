import Foundation

/// Relative load on each contact point, as a fraction of bodyweight.
///
/// Inverse Distance Weighting from the COM to each loaded contact. This is a
/// **heuristic, not physics** — present it in the UI as relative load, never as
/// measured force. It is expressed in %bodyweight because IDW produces
/// fractions determined entirely by geometry; multiplying by a mass would add
/// no accuracy and would make a heavier climber look worse on every move.
public struct LimbLoad: Sendable, Codable, Hashable {
    public var fractions: [JointName: Double]

    public init(fractions: [JointName: Double]) {
        self.fractions = fractions
    }

    public static let none = LimbLoad(fractions: [:])

    public subscript(_ j: JointName) -> Double { fractions[j] ?? 0 }

    public var handTotal: Double { JointName.hands.reduce(0) { $0 + self[$1] } }
    public var footTotal: Double { JointName.feet.reduce(0) { $0 + self[$1] } }

    /// |left − right| across all four limbs, 0...1.
    public var asymmetry: Double {
        let left = self[.leftWrist] + self[.leftAnkle]
        let right = self[.rightWrist] + self[.rightAnkle]
        return abs(left - right)
    }
}

public struct LoadEstimator: Sendable {

    public init() {}

    /// Per-frame limb loads. Fractions always sum to 1 when at least one
    /// contact is active, and to 0 when the climber is off the wall.
    public func estimate(
        com: Point2D?,
        contactPositions: [JointName: Point2D],
        scale: ClimbScale,
        config: TuningConfig
    ) -> LimbLoad {
        guard let com, !contactPositions.isEmpty else { return .none }
        var weights: [JointName: Double] = [:]
        var total = 0.0
        for (joint, position) in contactPositions {
            // Floor the distance so a contact coincident with the COM doesn't
            // take the entire bodyweight through a division by zero.
            let d = max(scale.distance(com, position), 1e-3)
            let w = 1.0 / pow(d, config.loadIDWExponent)
            weights[joint] = w
            total += w
        }
        guard total > 0 else { return .none }
        return LimbLoad(fractions: weights.mapValues { $0 / total })
    }

    /// Contact positions active at a frame, keyed by joint.
    public static func activeContacts(_ contacts: [Contact], atFrame frame: Int) -> [JointName: Point2D] {
        var out: [JointName: Point2D] = [:]
        for c in contacts where c.contains(frame: frame) {
            out[c.joint] = c.position
        }
        return out
    }
}

/// The polygon spanned by the currently loaded contact points. The COM leaving
/// it is the mechanical definition of falling — the strongest signal available
/// for fall attribution, and the reason skeleton-only mode exists.
public struct BaseOfSupport: Sendable, Codable, Hashable {
    public var vertices: [Point2D]
    /// Signed distance from the COM to the polygon, in body-lengths. Negative
    /// is inside. `nil` when the support is degenerate — see `isDegenerate`.
    public var comMarginBodyLengths: Double?
    public var comInside: Bool
    /// True when fewer than three loaded contacts span the support, so there is
    /// no polygon to be inside or outside of.
    ///
    /// This matters more than it looks. A climber hanging off two hands with no
    /// feet has a *line*, not a polygon, so the containment test can only ever
    /// answer "outside" — and the margin it reports is simply how far below
    /// their hands they hang. Reporting that as "your centre of mass left the
    /// base of support" is not a fall signal, it is a description of hanging.
    public var isDegenerate: Bool

    public init(vertices: [Point2D], comMarginBodyLengths: Double?, comInside: Bool, isDegenerate: Bool) {
        self.vertices = vertices
        self.comMarginBodyLengths = comMarginBodyLengths
        self.comInside = comInside
        self.isDegenerate = isDegenerate
    }

    public static let empty = BaseOfSupport(vertices: [], comMarginBodyLengths: nil, comInside: false, isDegenerate: true)

    public static func compute(
        loadedContacts: [Point2D],
        com: Point2D?,
        scale: ClimbScale
    ) -> BaseOfSupport {
        let hull = convexHull(loadedContacts)
        let degenerate = hull.count < 3
        guard let com, !hull.isEmpty else {
            return BaseOfSupport(vertices: hull, comMarginBodyLengths: nil, comInside: false, isDegenerate: true)
        }
        guard !degenerate else {
            // Distance to a point or a line is still worth drawing in the
            // skeleton view, but it is not a containment margin and must not be
            // read as one.
            return BaseOfSupport(
                vertices: hull,
                comMarginBodyLengths: nil,
                comInside: false,
                isDegenerate: true
            )
        }
        let inside = pointInPolygon(com, hull)
        let distance = distanceToPolygon(com, hull, scale: scale)
        return BaseOfSupport(
            vertices: hull,
            comMarginBodyLengths: inside ? -distance : distance,
            comInside: inside,
            isDegenerate: false
        )
    }

    /// Andrew's monotone chain.
    static func convexHull(_ points: [Point2D]) -> [Point2D] {
        guard points.count > 2 else { return points }
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: Point2D, _ a: Point2D, _ b: Point2D) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [Point2D] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [Point2D] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    static func pointInPolygon(_ p: Point2D, _ polygon: [Point2D]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func distanceToPolygon(_ p: Point2D, _ polygon: [Point2D], scale: ClimbScale) -> Double {
        guard !polygon.isEmpty else { return .infinity }
        if polygon.count == 1 { return scale.distance(p, polygon[0]) }
        var best = Double.infinity
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            best = min(best, distanceToSegment(p, a, b, scale: scale))
        }
        return best
    }

    static func distanceToSegment(_ p: Point2D, _ a: Point2D, _ b: Point2D, scale: ClimbScale) -> Double {
        let ab = scale.iso.vector(from: a, to: b)
        let ap = scale.iso.vector(from: a, to: p)
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 1e-12 else { return scale.distance(p, a) }
        let t = ((ap.x * ab.x + ap.y * ab.y) / lengthSquared).clamped(to: 0 ... 1)
        let closest = Point2D(x: ab.x * t - ap.x, y: ab.y * t - ap.y)
        return closest.length / scale.torsoLength
    }
}
