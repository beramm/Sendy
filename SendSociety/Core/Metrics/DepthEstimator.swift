import Foundation

/// Distance out from the wall plane, toward the camera. Always positive.
public struct DepthEstimate: Sendable, Codable, Hashable {
    /// Body-lengths. `nil` when confidence fell below the floor — a
    /// low-confidence z is not a small error, it is an arbitrary one.
    public var zBodyLengths: Double?
    public var confidence: Double

    public init(zBodyLengths: Double?, confidence: Double) {
        self.zBodyLengths = zBodyLengths
        self.confidence = confidence
    }

    public static let unavailable = DepthEstimate(zBodyLengths: nil, confidence: 0)
}

/// Depth from a single straight-on camera, via limb foreshortening.
///
/// The protocol exists so `VNDetectHumanBodyPose3DRequest` can slot in later as
/// a cross-check without touching anything downstream.
public protocol DepthEstimator: Sendable {
    func hipDepthTrack(
        sequence: PoseSequence,
        contacts: [Set<JointName>],
        scale: ClimbScale,
        config: TuningConfig
    ) -> [DepthEstimate]
}

/// Per-segment true lengths, taken as a high percentile of observed length over
/// the whole climb. A segment is only ever *shorter* than its true length in
/// projection, so the upper tail of the observed distribution is the estimate.
public struct SegmentCalibration: Sendable, Codable, Hashable {
    public var lengths: [String: Double]   // segment key -> true length, wall units
    public var samples: [String: Int]
    public var warnings: [String]

    public static func key(_ a: JointName, _ b: JointName) -> String { "\(a.rawValue)-\(b.rawValue)" }

    public func length(_ a: JointName, _ b: JointName) -> Double? { lengths[Self.key(a, b)] }

    public static let calibratedSegments: [(JointName, JointName)] = [
        (.leftHip, .leftKnee), (.rightHip, .rightKnee),
        (.leftKnee, .leftAnkle), (.rightKnee, .rightAnkle),
        (.leftShoulder, .leftElbow), (.rightShoulder, .rightElbow),
        (.leftElbow, .leftWrist), (.rightElbow, .rightWrist)
    ]

    /// Task 3.2. Percentile is a `TuningConfig` field, not a constant.
    public static func calibrate(sequence: PoseSequence, scale: ClimbScale, config: TuningConfig) -> SegmentCalibration {
        var lengths: [String: Double] = [:]
        var samples: [String: Int] = [:]
        var warnings: [String] = []
        for (a, b) in calibratedSegments {
            var observed: [Double] = []
            for f in sequence.frames {
                guard let pa = f.joints[a]?.point, let pb = f.joints[b]?.point else { continue }
                observed.append(scale.iso.distance(pa, pb))
            }
            let key = Self.key(a, b)
            samples[key] = observed.count
            if let l = observed.percentile(config.segmentLengthPercentile), l > 1e-6 {
                lengths[key] = l
            } else {
                warnings.append("Segment \(key) never tracked, so its length could not be calibrated.")
            }
        }
        return SegmentCalibration(lengths: lengths, samples: samples, warnings: warnings)
    }
}

/// Foreshortening depth, anchored at contacts where z ≈ 0.
///
/// ```
/// ratio   = clamp(L_observed / L_true, 0, 1)
/// z_local = L_true · √(1 − ratio²)
/// conf    = 1 − ratio
/// ```
///
/// **Known weakness, by construction:** the sign of each `z_local` is not
/// recoverable from a single view, so the chain sums magnitudes. That makes the
/// estimate an upper bound on how far the hip is out, monotone in the quantity
/// a coach cares about, but not a measurement of it. Near the wall plane the
/// derivative is flat, so small pixel errors give large z errors — which is
/// what `confidence` is for, and why it gates emission.
public struct ForeshorteningDepthEstimator: DepthEstimator {

    public init() {}

    public func hipDepthTrack(
        sequence: PoseSequence,
        contacts: [Set<JointName>],
        scale: ClimbScale,
        config: TuningConfig
    ) -> [DepthEstimate] {
        let calibration = SegmentCalibration.calibrate(sequence: sequence, scale: scale, config: config)
        var raw: [DepthEstimate] = []

        for (i, frame) in sequence.frames.enumerated() {
            let active = i < contacts.count ? contacts[i] : []
            var estimates: [(z: Double, confidence: Double)] = []

            for (ankle, knee, hip) in [
                (JointName.leftAnkle, JointName.leftKnee, JointName.leftHip),
                (JointName.rightAnkle, JointName.rightKnee, JointName.rightHip)
            ] {
                // Anchor at a foot on the wall: that ankle is at z ≈ 0.
                guard active.contains(ankle) else { continue }
                guard let shank = segmentDepth(frame: frame, a: knee, b: ankle, calibration: calibration, scale: scale),
                      let thigh = segmentDepth(frame: frame, a: hip, b: knee, calibration: calibration, scale: scale)
                else { continue }
                estimates.append((shank.z + thigh.z, min(shank.confidence, thigh.confidence)))
            }

            if estimates.isEmpty {
                raw.append(.unavailable)
                continue
            }
            let weightTotal = estimates.map(\.confidence).reduce(0, +)
            guard weightTotal > 1e-6 else {
                raw.append(.unavailable)
                continue
            }
            let z = estimates.reduce(0.0) { $0 + $1.z * $1.confidence } / weightTotal
            let confidence = weightTotal / Double(estimates.count)
            raw.append(DepthEstimate(zBodyLengths: z / scale.torsoLength, confidence: confidence))
        }

        return smoothAndGate(raw, config: config)
    }

    func segmentDepth(
        frame: PoseFrame,
        a: JointName,
        b: JointName,
        calibration: SegmentCalibration,
        scale: ClimbScale
    ) -> (z: Double, confidence: Double)? {
        guard let pa = frame.joints[a]?.point, let pb = frame.joints[b]?.point,
              let trueLength = calibration.length(a, b) ?? calibration.length(b, a),
              trueLength > 1e-6
        else { return nil }
        let observed = scale.iso.distance(pa, pb)
        let ratio = (observed / trueLength).clamped(to: 0 ... 1)
        let z = trueLength * (1 - ratio * ratio).squareRoot()
        return (z, 1 - ratio)
    }

    /// Exponential smoothing, then confidence gating. Gating comes last so a
    /// smoothed value never inherits credibility from its neighbours.
    func smoothAndGate(_ raw: [DepthEstimate], config: TuningConfig) -> [DepthEstimate] {
        var out: [DepthEstimate] = []
        var previous: Double?
        for e in raw {
            guard let z = e.zBodyLengths else {
                out.append(.unavailable)
                previous = nil
                continue
            }
            let smoothed: Double
            if let p = previous {
                smoothed = config.depthSmoothingAlpha * z + (1 - config.depthSmoothingAlpha) * p
            } else {
                smoothed = z
            }
            previous = smoothed
            out.append(e.confidence >= config.depthConfidenceFloor
                ? DepthEstimate(zBodyLengths: smoothed, confidence: e.confidence)
                : DepthEstimate(zBodyLengths: nil, confidence: e.confidence))
        }
        return out
    }
}
