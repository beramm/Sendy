import Foundation

/// Centre of mass from Dempster's body segment parameters.
///
/// Fully determined by the 19 joints — no height, no weight. Dempster gives
/// *fractions*, and fractions are all a geometric comparison needs. Mass would
/// only convert a fraction into kilograms, which actively corrupts
/// cross-climber comparison.
public struct COMEstimator: Sendable {

    public struct Segment: Sendable {
        public let massFraction: Double
        public let proximal: JointName
        public let distal: JointName
        /// Position of the segment centroid along proximal→distal, 0...1.
        public let centroidRatio: Double
    }

    /// Dempster segment parameters. Limb values apply per side, so the eight
    /// distinct values below sum to 1.0 once both sides are counted.
    public static let segments: [Segment] = [
        .init(massFraction: 0.081,  proximal: .neck,          distal: .nose,        centroidRatio: 1.0),
        .init(massFraction: 0.497,  proximal: .leftShoulder,  distal: .leftHip,     centroidRatio: 0.5),
        .init(massFraction: 0.028,  proximal: .leftShoulder,  distal: .leftElbow,   centroidRatio: 0.436),
        .init(massFraction: 0.028,  proximal: .rightShoulder, distal: .rightElbow,  centroidRatio: 0.436),
        .init(massFraction: 0.016,  proximal: .leftElbow,     distal: .leftWrist,   centroidRatio: 0.430),
        .init(massFraction: 0.016,  proximal: .rightElbow,    distal: .rightWrist,  centroidRatio: 0.430),
        .init(massFraction: 0.006,  proximal: .leftWrist,     distal: .leftWrist,   centroidRatio: 0.0),
        .init(massFraction: 0.006,  proximal: .rightWrist,    distal: .rightWrist,  centroidRatio: 0.0),
        .init(massFraction: 0.100,  proximal: .leftHip,       distal: .leftKnee,    centroidRatio: 0.433),
        .init(massFraction: 0.100,  proximal: .rightHip,      distal: .rightKnee,   centroidRatio: 0.433),
        .init(massFraction: 0.0465, proximal: .leftKnee,      distal: .leftAnkle,   centroidRatio: 0.433),
        .init(massFraction: 0.0465, proximal: .rightKnee,     distal: .rightAnkle,  centroidRatio: 0.433),
        .init(massFraction: 0.0145, proximal: .leftAnkle,     distal: .leftAnkle,   centroidRatio: 0.0),
        .init(massFraction: 0.0145, proximal: .rightAnkle,    distal: .rightAnkle,  centroidRatio: 0.0)
    ]

    public init() {}

    /// COM in wall space, plus the fraction of body mass that was actually
    /// tracked. A COM computed from 40% of the body is reported with
    /// `confidence` 0.4 rather than silently presented as fact.
    public func estimate(_ frame: PoseFrame) -> (point: Point2D, confidence: Double)? {
        var weighted = Point2D.zero
        var total = 0.0

        // The trunk is handled specially: shoulder-centre to hip-centre, since
        // a single-sided trunk segment would drag the COM sideways whenever one
        // shoulder drops out of tracking.
        if let s = frame.shoulderCenter, let h = frame.hipCenter {
            weighted = weighted + (s + h) * 0.5 * 0.497
            total += 0.497
        }

        for segment in Self.segments where segment.massFraction != 0.497 {
            guard let a = frame.joints[segment.proximal]?.point else { continue }
            let b = frame.joints[segment.distal]?.point ?? a
            let centroid = a + (b - a) * segment.centroidRatio
            weighted = weighted + centroid * segment.massFraction
            total += segment.massFraction
        }

        guard total > 0.15 else { return nil }
        return (weighted / total, total)
    }

    /// COM track over a whole sequence. `nil` where too little of the body was
    /// tracked to compute one.
    public func track(_ sequence: PoseSequence) -> [Point2D?] {
        sequence.frames.map { estimate($0)?.point }
    }
}
