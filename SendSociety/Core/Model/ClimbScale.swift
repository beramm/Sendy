import Foundation

/// Converts between wall units and body-lengths, and carries the aspect
/// correction with it.
///
/// Rule 2 of the project — comparison is always normalized — applies to
/// *thresholds* as much as to metrics. A contact-velocity threshold in
/// wall-widths per second silently depends on how far back the tripod stood: on
/// the dev fixture the climber occupies about a fifth of the frame, so the same
/// movement reads five times slower than it would from close up. Expressing
/// thresholds in body-lengths removes framing from the equation entirely.
public struct ClimbScale: Sendable, Codable, Hashable {
    public var iso: IsoMetric
    /// Median torso length in aspect-corrected wall units.
    public var torsoLength: Double
    /// True when the torso never tracked and a fallback was substituted. The UI
    /// shows a warning; the pipeline still runs. Fail soft, never blank.
    public var isEstimated: Bool

    /// Used when the torso never tracked. Deliberately conservative — roughly a
    /// climber filling a fifth of the frame height.
    public static let fallbackTorsoLength = 0.08

    public init(iso: IsoMetric, torsoLength: Double, isEstimated: Bool = false) {
        self.iso = iso
        self.torsoLength = torsoLength > 1e-6 ? torsoLength : Self.fallbackTorsoLength
        self.isEstimated = isEstimated
    }

    public init(sequence: PoseSequence) {
        let iso = IsoMetric(sequence: sequence)
        if let t = sequence.medianTorsoLength(iso: iso), t > 1e-6 {
            self.init(iso: iso, torsoLength: t, isEstimated: false)
        } else {
            self.init(iso: iso, torsoLength: Self.fallbackTorsoLength, isEstimated: true)
        }
    }

    /// Wall units for a threshold quoted in body-lengths.
    public func wall(bodyLengths: Double) -> Double { bodyLengths * torsoLength }

    /// Body-lengths for a distance measured in wall units.
    public func bodyLengths(wall distance: Double) -> Double { distance / torsoLength }

    /// Distance between two wall-space points, in body-lengths.
    public func distance(_ a: Point2D, _ b: Point2D) -> Double {
        iso.distance(a, b) / torsoLength
    }

    /// Distance between two wall-space points, in wall units.
    public func wallDistance(_ a: Point2D, _ b: Point2D) -> Double {
        iso.distance(a, b)
    }
}
