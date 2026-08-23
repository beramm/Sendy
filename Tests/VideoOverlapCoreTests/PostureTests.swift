import Testing
import Foundation
@testable import VideoOverlapCore

/// The coach-priority reads: pelvis, then knee, then arm.
///
/// Every assertion here is against a *known* answer built into the fixture —
/// a pelvis tilted by a constructed angle, a hip line narrowed by a constructed
/// factor — rather than against whatever the estimator happened to produce.
@Suite("Posture")
struct PostureTests {

    let config = TuningConfig()

    func scale(_ frame: PoseFrame) -> ClimbScale {
        ClimbScale(iso: .square, torsoLength: 0.12)
    }

    /// A frame with the hips rotated in the image plane by a known angle.
    func tiltedFrame(degrees: Double, hipHalfWidth: Double = 0.03) -> PoseFrame {
        var frame = SyntheticClimb.standingFrame()
        let radians = degrees * .pi / 180
        let dx = hipHalfWidth * cos(radians)
        let dy = hipHalfWidth * sin(radians)
        frame.joints[.leftHip] = Joint(point: Point2D(x: 0.5 - dx, y: 0.5 - dy), confidence: 0.9)
        frame.joints[.rightHip] = Joint(point: Point2D(x: 0.5 + dx, y: 0.5 + dy), confidence: 0.9)
        return frame
    }

    @Test("Hip tilt recovers a constructed angle, signed toward the high hip")
    func hipTilt() {
        let estimator = PostureEstimator()
        for expected in [-30.0, -12.0, 0.0, 8.0, 25.0] {
            let frame = tiltedFrame(degrees: expected)
            let posture = estimator.measure(
                frame: frame, load: .none, activeContacts: [],
                scale: scale(frame), hipWidthReference: 0.06, config: config
            )
            guard let tilt = posture.pelvis?.tiltDegrees else {
                Issue.record("no pelvis at \(expected)°")
                continue
            }
            #expect(abs(tilt - expected) < 0.5, "tilt \(tilt) for constructed \(expected)")
        }
    }

    /// Positive tilt must mean the right hip is the high one, because the copy
    /// says "your right hip sat higher" and a sign flip makes it a lie.
    @Test("Positive tilt is the right hip high")
    func tiltSign() {
        let frame = tiltedFrame(degrees: 20)
        let right = frame.joints[.rightHip]!.point.y
        let left = frame.joints[.leftHip]!.point.y
        #expect(right > left)
        let posture = PostureEstimator().measure(
            frame: frame, load: .none, activeContacts: [],
            scale: scale(frame), hipWidthReference: 0.06, config: config
        )
        #expect((posture.pelvis?.tiltDegrees ?? 0) > 0)
    }

    @Test("Pelvis turn recovers a constructed width compression")
    func pelvisTurn() {
        let estimator = PostureEstimator()
        let reference = 0.06
        // cos θ = observed / reference, by construction.
        for expected in [0.0, 30.0, 60.0] {
            let observed = reference * cos(expected * .pi / 180)
            let frame = tiltedFrame(degrees: 0, hipHalfWidth: observed / 2)
            let posture = estimator.measure(
                frame: frame, load: .none, activeContacts: [],
                scale: scale(frame), hipWidthReference: reference, config: config
            )
            guard let turn = posture.pelvis?.turnDegrees else {
                Issue.record("no turn at \(expected)°")
                continue
            }
            #expect(abs(turn - expected) < 1.0, "turn \(turn) for constructed \(expected)")
        }
    }

    /// The same failure mode as foreshortening depth: near square the estimate
    /// is arbitrary, and it has to *say* so rather than be emitted flat.
    @Test("Turn confidence is lowest near square")
    func turnConfidenceNearSquare() {
        let estimator = PostureEstimator()
        func confidence(atTurn degrees: Double) -> Double {
            let observed = 0.06 * cos(degrees * .pi / 180)
            let frame = tiltedFrame(degrees: 0, hipHalfWidth: observed / 2)
            return estimator.measure(
                frame: frame, load: .none, activeContacts: [],
                scale: scale(frame), hipWidthReference: 0.06, config: config
            ).pelvis?.turnConfidence ?? 1
        }
        #expect(confidence(atTurn: 0) < 0.05)
        #expect(confidence(atTurn: 60) > confidence(atTurn: 20))
    }

    @Test("A pelvis with no calibrated hip width reports no turn at all")
    func turnWithoutCalibration() {
        let frame = tiltedFrame(degrees: 0)
        let posture = PostureEstimator().measure(
            frame: frame, load: .none, activeContacts: [],
            scale: scale(frame), hipWidthReference: nil, config: config
        )
        #expect(posture.pelvis != nil)
        #expect(posture.pelvis?.turnDegrees == nil, "an uncalibrated turn is not a small turn")
    }

    @Test("Torso lean is signed from vertical, positive when shoulders sit right of the hips")
    func torsoLean() {
        var frame = SyntheticClimb.standingFrame()
        // Shoulders shifted right by exactly one torso-length tangent.
        let torso = 0.12
        let offset = torso * tan(20 * .pi / 180)
        for (name, x) in [(JointName.leftShoulder, 0.45), (.rightShoulder, 0.55)] {
            let p = frame.joints[name]!.point
            frame.joints[name] = Joint(point: Point2D(x: x + offset, y: p.y), confidence: 0.9)
        }
        let posture = PostureEstimator().measure(
            frame: frame, load: .none, activeContacts: [],
            scale: scale(frame), hipWidthReference: 0.06, config: config
        )
        guard let lean = posture.torsoLeanDegrees else {
            Issue.record("no lean")
            return
        }
        #expect(abs(lean - 20) < 1.0, "lean \(lean)")
    }

    /// The barn door is a *configuration*, and the claim is only licensed by
    /// that configuration. Everything else has to come back nil.
    @Test("Open side is named only in the barn-door configuration")
    func barnDoorGate() {
        func openSide(_ loaded: [JointName]) -> BodySide? {
            let fractions = Dictionary(uniqueKeysWithValues: loaded.map { ($0, 1.0 / Double(loaded.count)) })
            return PostureEstimator.barnDoorOpenSide(
                load: LimbLoad(fractions: fractions),
                activeContacts: Set(loaded),
                config: config
            )
        }
        // Same side hand and foot: the free side swings out.
        #expect(openSide([.leftWrist, .leftAnkle]) == .right)
        #expect(openSide([.rightWrist, .rightAnkle]) == .left)
        // A diagonal is the arrangement that *resists* rotation.
        #expect(openSide([.rightWrist, .leftAnkle]) == nil)
        // Three points, two hands, one limb: none of these is a barn door.
        #expect(openSide([.leftWrist, .rightWrist, .leftAnkle]) == nil)
        #expect(openSide([.leftWrist, .rightWrist]) == nil)
        #expect(openSide([.leftWrist]) == nil)
    }

    /// A bent arm holding nothing is a shake-out. Counting it as pulling was
    /// the thing that made bent-arm time read badly on rests.
    @Test("Pulling needs a bent elbow, a levered lat and load on that hand")
    func pullingRequiresLoad() {
        var frame = SyntheticClimb.standingFrame()
        // Bend both elbows hard: wrists pulled up beside the shoulders.
        let shoulderY = 0.5 + 0.12
        frame.joints[.leftWrist] = Joint(point: Point2D(x: 0.45, y: shoulderY - 0.01), confidence: 0.9)
        frame.joints[.rightWrist] = Joint(point: Point2D(x: 0.55, y: shoulderY - 0.01), confidence: 0.9)

        let unloaded = PostureEstimator().measure(
            frame: frame, load: .none, activeContacts: [],
            scale: scale(frame), hipWidthReference: 0.06, config: config
        )
        #expect(unloaded.pullingHands.isEmpty, "a bent arm with no load on it is a shake-out")

        let loaded = PostureEstimator().measure(
            frame: frame,
            load: LimbLoad(fractions: [.leftWrist: 0.5, .rightWrist: 0.5]),
            activeContacts: [.leftWrist, .rightWrist],
            scale: scale(frame), hipWidthReference: 0.06, config: config
        )
        #expect(!loaded.pullingHands.isEmpty)
    }

    @Test("Diagonal imbalance sees what left/right asymmetry cannot")
    func diagonalImbalance() {
        let frame = SyntheticClimb.standingFrame()
        // Right hand and left foot carry everything. Left/right asymmetry is
        // zero here by construction — one limb per side — and the diagonal
        // imbalance is total.
        let load = LimbLoad(fractions: [.rightWrist: 0.5, .leftAnkle: 0.5])
        #expect(load.asymmetry < 1e-9)
        let posture = PostureEstimator().measure(
            frame: frame, load: load, activeContacts: [.rightWrist, .leftAnkle],
            scale: scale(frame), hipWidthReference: 0.06, config: config
        )
        #expect(abs((posture.diagonalImbalance ?? 0) - 1.0) < 1e-9)
    }

    @Test("Knee-past-toe is signed and normalized by body length")
    func kneeOverAnkle() {
        var frame = SyntheticClimb.standingFrame()
        // Right knee driven 0.06 wall units across its own ankle: half a torso.
        let knee = frame.joints[.rightKnee]!.point
        frame.joints[.rightKnee] = Joint(point: Point2D(x: knee.x - 0.06, y: knee.y), confidence: 0.9)
        let posture = PostureEstimator().measure(
            frame: frame, load: .none, activeContacts: [],
            scale: scale(frame), hipWidthReference: 0.06, config: config
        )
        #expect(abs((posture.rightKneeOverAnkle ?? 0) + 0.5) < 0.01, "right knee \(String(describing: posture.rightKneeOverAnkle))")
        #expect(abs((posture.kneeDriveBodyLengths ?? 0) - 0.5) < 0.01)
    }

    /// Adding a stored property to a `Codable` metric struct must not orphan
    /// sessions already on disk — the failure `TuningConfig` documents.
    @Test("Frame metrics recorded before posture existed still decode")
    func olderFrameMetricsDecode() throws {
        let json = """
        {"index":3,"timeSeconds":0.1,"comConfidence":0.8,"load":{"fractions":{}},
         "baseOfSupport":{"vertices":[],"comInside":false,"isDegenerate":true},
         "hipDepth":{"confidence":0.0},"activeContacts":[]}
        """
        let decoded = try JSONDecoder().decode(FrameMetrics.self, from: Data(json.utf8))
        #expect(decoded.index == 3)
        #expect(decoded.posture.pelvis == nil)
    }
}
