import Foundation

/// One-Euro filter for a scalar signal.
///
/// Chosen over a Kalman filter or a plain moving average because contact
/// detection is velocity-based: the filter has to kill jitter while the limb is
/// still without adding lag when it moves, and that trade is exactly what the
/// One-Euro adaptive cutoff does.
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var derivativeCutoff: Double

    private var previousValue: Double?
    private var previousDerivative: Double = 0
    private var hasDerivative = false

    init(minCutoff: Double, beta: Double, derivativeCutoff: Double) {
        self.minCutoff = max(1e-6, minCutoff)
        self.beta = max(0, beta)
        self.derivativeCutoff = max(1e-6, derivativeCutoff)
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    mutating func filter(_ value: Double, dt: Double) -> Double {
        guard dt > 0 else { return value }
        guard let prev = previousValue else {
            previousValue = value
            return value
        }
        let rawDerivative = (value - prev) / dt
        let dAlpha = Self.alpha(cutoff: derivativeCutoff, dt: dt)
        let derivative = hasDerivative
            ? dAlpha * rawDerivative + (1 - dAlpha) * previousDerivative
            : rawDerivative
        hasDerivative = true
        previousDerivative = derivative

        let cutoff = minCutoff + beta * abs(derivative)
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let filtered = a * value + (1 - a) * prev
        previousValue = filtered
        return filtered
    }

    /// Resets state, e.g. across a tracking gap where continuity is a lie.
    mutating func reset() {
        previousValue = nil
        previousDerivative = 0
        hasDerivative = false
    }
}

/// Drops low-confidence joints, bridges short tracking gaps, then One-Euro
/// filters each joint independently.
///
/// Raw Vision output is jittery enough that velocity computed from it is
/// unusable for contact detection — this stage is what makes `ContactDetector`
/// possible, not a cosmetic nicety.
public struct PoseSmoother: Sendable {

    public init() {}

    public func process(_ sequence: PoseSequence, config: TuningConfig) -> PoseSequence {
        guard !sequence.frames.isEmpty else { return sequence }
        var frames = sequence.frames
        var warnings = sequence.warnings

        // 1. Confidence gate. A joint below the floor is a tracking failure;
        //    keeping it propagates garbage into velocity.
        var droppedByConfidence = 0
        for i in frames.indices {
            for (name, joint) in frames[i].joints {
                // Extremities are held to a lower bar than the torso: Vision is
                // systematically less confident about wrists and ankles, and
                // they are the only joints that touch holds.
                let floor = JointName.extremities.contains(name)
                    ? config.extremityConfidenceFloor
                    : config.jointConfidenceFloor
                if joint.confidence < floor {
                    frames[i].joints[name] = nil
                    droppedByConfidence += 1
                }
            }
        }

        // 2. Bridge short gaps by linear interpolation. Long gaps stay absent —
        //    inventing a limb position across a second of lost tracking would
        //    produce a phantom contact.
        var bridged = 0
        var abandoned = 0
        for name in JointName.allCases {
            var lastPresent: Int?
            for i in frames.indices {
                if frames[i].joints[name] != nil {
                    if let start = lastPresent, i - start > 1 {
                        let gap = i - start - 1
                        if gap <= config.maxInterpolatedGapFrames {
                            interpolate(&frames, joint: name, from: start, to: i, factor: config.interpolatedConfidenceFactor)
                            bridged += gap
                        } else {
                            abandoned += gap
                        }
                    }
                    lastPresent = i
                }
            }
        }

        // 3. One-Euro per joint per axis.
        var filters: [JointName: (x: OneEuroFilter, y: OneEuroFilter)] = [:]
        var lastTime: [JointName: Double] = [:]
        let fallbackDT = 1.0 / max(1, sequence.frameRate)

        for i in frames.indices {
            let t = frames[i].timeSeconds
            for name in JointName.allCases {
                guard let joint = frames[i].joints[name] else {
                    // Gap: reset so the filter doesn't smear across it.
                    filters[name]?.x.reset()
                    filters[name]?.y.reset()
                    lastTime[name] = nil
                    continue
                }
                var pair = filters[name] ?? (
                    OneEuroFilter(minCutoff: config.smoothingMinCutoff, beta: config.smoothingBeta, derivativeCutoff: config.smoothingDerivativeCutoff),
                    OneEuroFilter(minCutoff: config.smoothingMinCutoff, beta: config.smoothingBeta, derivativeCutoff: config.smoothingDerivativeCutoff)
                )
                let dt = lastTime[name].map { max(1e-4, t - $0) } ?? fallbackDT
                let x = pair.x.filter(joint.point.x, dt: dt)
                let y = pair.y.filter(joint.point.y, dt: dt)
                filters[name] = pair
                lastTime[name] = t
                frames[i].joints[name] = Joint(point: Point2D(x: x, y: y), confidence: joint.confidence)
            }
        }

        if droppedByConfidence > 0 {
            warnings.append("Dropped \(droppedByConfidence) low-confidence joint readings.")
        }
        if abandoned > 0 {
            warnings.append("\(abandoned) joint-frames left untracked — gaps longer than \(config.maxInterpolatedGapFrames) frames are not bridged.")
        }

        var out = sequence
        out.frames = frames
        out.warnings = warnings
        return out
    }

    private func interpolate(_ frames: inout [PoseFrame], joint: JointName, from: Int, to: Int, factor: Double) {
        guard let a = frames[from].joints[joint], let b = frames[to].joints[joint] else { return }
        let span = Double(to - from)
        for i in (from + 1) ..< to {
            let t = Double(i - from) / span
            frames[i].joints[joint] = Joint(
                point: a.point * (1 - t) + b.point * t,
                // Interpolated points are inferred, so confidence is the lower
                // of the two anchors, scaled down. Never claim more than you saw.
                confidence: min(a.confidence, b.confidence) * factor
            )
        }
    }
}
