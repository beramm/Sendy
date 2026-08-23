import Foundation

/// Left or right side of the body. Named rather than `Bool` because every use
/// of it ends up in user-facing copy ("your right hip"), where a boolean would
/// have to be un-encoded at the call site.
public enum BodySide: String, Sendable, Codable, Hashable {
    case left, right

    public var opposite: BodySide { self == .left ? .right : .left }
    public var displayName: String { rawValue }
}

/// The coach's pelvis triangle: two hip points and the pubic bone below them.
///
/// A climbing coach reads the pelvis before anything else — where it points,
/// whether it is level, how far it has turned out of the wall plane — and then
/// reads the knee, then the arm. Everything in this struct is the geometry a
/// coach draws on a still with a finger, computed instead of eyeballed.
///
/// **What is measured and what is inferred.** `tiltDegrees` and the triangle
/// are direct projections of tracked joints. `turnDegrees` is inferred from hip
/// width compression against the climb's own widest hip line, which is a
/// magnitude with no sign — a single camera cannot tell a pelvis turned left
/// from one turned right by width alone. `openSide` is not derived from the
/// pelvis at all; it is the mechanical barn-door configuration read off the
/// loaded contacts, and it is `nil` whenever that configuration does not hold.
/// Guessing a facing direction from a projected width would be exactly the kind
/// of confident number about nothing this project refuses to produce.
public struct PelvisPose: Sendable, Codable, Hashable {
    public var leftHip: Point2D
    public var rightHip: Point2D
    /// Apex of the triangle — a pubic-bone proxy, placed below the hip midpoint
    /// along the torso axis so it rotates with the pelvis rather than with the
    /// screen.
    public var pubis: Point2D
    public var center: Point2D
    /// Hip-line angle from horizontal, signed. Positive = right hip higher.
    /// Range −90…90.
    public var tiltDegrees: Double
    /// How far the pelvis has turned out of the wall plane, 0…90, magnitude
    /// only. `nil` when hip width was never calibrated on this climb.
    public var turnDegrees: Double?
    /// Confidence in `turnDegrees`. Lowest near square, where `acos` has an
    /// infinite derivative and a pixel of hip-width noise is worth many
    /// degrees — the same failure mode as foreshortening depth near the wall
    /// plane, and handled the same way.
    public var turnConfidence: Double
    /// The side that will swing away from the wall if the climber lets go of
    /// nothing at all: set **only** in the barn-door configuration, where the
    /// one loaded hand and the one loaded foot are on the same side. Any other
    /// arrangement is not a barn door and gets `nil`.
    public var openSide: BodySide?

    public init(
        leftHip: Point2D,
        rightHip: Point2D,
        pubis: Point2D,
        center: Point2D,
        tiltDegrees: Double,
        turnDegrees: Double?,
        turnConfidence: Double,
        openSide: BodySide?
    ) {
        self.leftHip = leftHip
        self.rightHip = rightHip
        self.pubis = pubis
        self.center = center
        self.tiltDegrees = tiltDegrees
        self.turnDegrees = turnDegrees
        self.turnConfidence = turnConfidence
        self.openSide = openSide
    }
}

/// Posture at one frame — the coach-priority quantities, in coach order:
/// pelvis, then knee, then arm.
public struct PostureFrame: Sendable, Codable, Hashable {
    public var pelvis: PelvisPose?
    /// Angle of the plumb line: pelvis centre → shoulder centre, measured from
    /// vertical, signed. Positive = shoulders right of the hips. This is the
    /// line a coach draws from the head down past the pubic bone, and its sign
    /// says which arm is working.
    public var torsoLeanDegrees: Double?
    /// Angle at the shoulder between torso and upper arm (hip–shoulder–elbow) —
    /// the lat lever. Below `TuningConfig.latEngagementDegrees` the lat is
    /// loaded, which is what a bent arm actually costs.
    public var leftShoulderDegrees: Double?
    public var rightShoulderDegrees: Double?
    /// Knee horizontal offset past the ankle, in body-lengths, signed toward
    /// screen-right. A knee well past its own toe is a drop knee or a flag —
    /// the coach's second-priority read.
    public var leftKneeOverAnkle: Double?
    public var rightKneeOverAnkle: Double?
    /// Wrists whose arm is bent, lat-loaded **and** carrying weight. A bent arm
    /// holding nothing is a shake-out, not a pull, and counting it was what made
    /// `straightArmRatio` read badly on rests.
    public var pullingHands: Set<JointName>
    /// |(right hand + left foot) − (left hand + right foot)|. The diagonal is
    /// the pairing a coach loads and unloads as one unit; left-versus-right
    /// asymmetry cannot see it.
    public var diagonalImbalance: Double?

    public init(
        pelvis: PelvisPose? = nil,
        torsoLeanDegrees: Double? = nil,
        leftShoulderDegrees: Double? = nil,
        rightShoulderDegrees: Double? = nil,
        leftKneeOverAnkle: Double? = nil,
        rightKneeOverAnkle: Double? = nil,
        pullingHands: Set<JointName> = [],
        diagonalImbalance: Double? = nil
    ) {
        self.pelvis = pelvis
        self.torsoLeanDegrees = torsoLeanDegrees
        self.leftShoulderDegrees = leftShoulderDegrees
        self.rightShoulderDegrees = rightShoulderDegrees
        self.leftKneeOverAnkle = leftKneeOverAnkle
        self.rightKneeOverAnkle = rightKneeOverAnkle
        self.pullingHands = pullingHands
        self.diagonalImbalance = diagonalImbalance
    }

    public static let unavailable = PostureFrame()

    /// Largest knee-past-ankle offset at this frame, in body-lengths.
    public var kneeDriveBodyLengths: Double? {
        [leftKneeOverAnkle, rightKneeOverAnkle].compactMap { $0.map(abs) }.max()
    }
}

/// Computes `PostureFrame`. Deterministic Swift, like everything that produces
/// a number in this app.
public struct PostureEstimator: Sendable {

    public init() {}

    /// Widest hip line observed across the climb, in aspect-corrected wall
    /// units. Same reasoning as `SegmentCalibration`: projection can only ever
    /// shorten a segment, so the upper tail of the observed distribution is the
    /// true length. Returns `nil` when the hips never tracked.
    public func referenceHipWidth(sequence: PoseSequence, scale: ClimbScale, config: TuningConfig) -> Double? {
        var observed: [Double] = []
        for frame in sequence.frames {
            guard let l = frame.joints[.leftHip]?.point, let r = frame.joints[.rightHip]?.point else { continue }
            observed.append(scale.iso.distance(l, r))
        }
        guard let width = observed.percentile(config.segmentLengthPercentile), width > 1e-6 else { return nil }
        return width
    }

    public func measure(
        frame: PoseFrame,
        load: LimbLoad,
        activeContacts: Set<JointName>,
        scale: ClimbScale,
        hipWidthReference: Double?,
        config: TuningConfig
    ) -> PostureFrame {
        var out = PostureFrame()

        let iso = scale.iso
        let leftHip = frame.joints[.leftHip]?.point
        let rightHip = frame.joints[.rightHip]?.point
        let shoulderCenter = frame.shoulderCenter

        if let leftHip, let rightHip, let hipCenter = frame.hipCenter {
            let hipVector = iso.vector(from: leftHip, to: rightHip)
            let tilt = atan2(hipVector.y, hipVector.x) * 180 / .pi
            // Fold onto −90…90: a hip line is undirected, so 170° and −10° are
            // the same tilt seen from opposite ends.
            let folded = tilt > 90 ? tilt - 180 : (tilt < -90 ? tilt + 180 : tilt)

            var turn: Double?
            var turnConfidence = 0.0
            if let reference = hipWidthReference, reference > 1e-6 {
                let ratio = (hipVector.length / reference).clamped(to: 0 ... 1)
                turn = acos(ratio) * 180 / .pi
                // sin(turn) — zero at square, one at fully side-on. The
                // derivative of acos is what makes a square pelvis
                // unmeasurable, not the tracking.
                turnConfidence = (1 - ratio * ratio).squareRoot()
            }

            // Pubic bone: down the torso axis from the hip centre. Falls back
            // to straight down when the shoulders are untracked, which keeps
            // the triangle drawable rather than dropping it.
            let axis: Point2D
            if let shoulderCenter {
                let up = iso.vector(from: hipCenter, to: shoulderCenter)
                let length = up.length
                axis = length > 1e-9 ? Point2D(x: -up.x / length, y: -up.y / length) : Point2D(x: 0, y: -1)
            } else {
                axis = Point2D(x: 0, y: -1)
            }
            let drop = scale.torsoLength * config.pubisDropTorsoFraction
            // Back out of iso units into wall units for the x component.
            let pubis = Point2D(
                x: hipCenter.x + (axis.x * drop) / max(iso.xScale, 1e-9),
                y: hipCenter.y + axis.y * drop
            )

            out.pelvis = PelvisPose(
                leftHip: leftHip,
                rightHip: rightHip,
                pubis: pubis,
                center: hipCenter,
                tiltDegrees: folded,
                turnDegrees: turn,
                turnConfidence: turnConfidence,
                openSide: Self.barnDoorOpenSide(load: load, activeContacts: activeContacts, config: config)
            )
        }

        if let hipCenter = frame.hipCenter, let shoulderCenter {
            let v = iso.vector(from: hipCenter, to: shoulderCenter)
            if v.length > 1e-9 {
                out.torsoLeanDegrees = atan2(v.x, v.y) * 180 / .pi
            }
        }

        out.leftShoulderDegrees = shoulderAngle(frame, side: .left, iso: iso)
        out.rightShoulderDegrees = shoulderAngle(frame, side: .right, iso: iso)
        out.leftKneeOverAnkle = kneeOverAnkle(frame, side: .left, scale: scale)
        out.rightKneeOverAnkle = kneeOverAnkle(frame, side: .right, scale: scale)

        var pulling: Set<JointName> = []
        for (side, wrist, shoulderAngle) in [
            (BodySide.left, JointName.leftWrist, out.leftShoulderDegrees),
            (BodySide.right, JointName.rightWrist, out.rightShoulderDegrees)
        ] {
            let elbow = elbowAngle(frame, side: side, iso: iso)
            guard let elbow, elbow < config.straightArmDegrees else { continue }
            guard let shoulderAngle, shoulderAngle < config.latEngagementDegrees else { continue }
            guard load[wrist] >= config.pullingArmLoadFraction else { continue }
            pulling.insert(wrist)
        }
        out.pullingHands = pulling

        let diagonalA = load[.rightWrist] + load[.leftAnkle]
        let diagonalB = load[.leftWrist] + load[.rightAnkle]
        if diagonalA + diagonalB > 1e-9 {
            out.diagonalImbalance = abs(diagonalA - diagonalB)
        }

        return out
    }

    /// The barn-door configuration: one loaded hand and one loaded foot, on the
    /// **same** side. That is the arrangement with no diagonal to resist
    /// rotation, and the free side is the one that swings out — which is what
    /// the coach means by "look at where the hip is facing and you know which
    /// way they'll come off".
    ///
    /// Deliberately narrow. A diagonal pair, three points of contact, or two
    /// hands all return `nil`, because none of them licenses the claim.
    static func barnDoorOpenSide(
        load: LimbLoad,
        activeContacts: Set<JointName>,
        config: TuningConfig
    ) -> BodySide? {
        let hands = JointName.hands.filter {
            activeContacts.contains($0) && load[$0] >= config.loadedContactFraction
        }
        let feet = JointName.feet.filter {
            activeContacts.contains($0) && load[$0] >= config.loadedContactFraction
        }
        guard hands.count == 1, feet.count == 1 else { return nil }
        guard hands[0].isLeft == feet[0].isLeft else { return nil }
        return hands[0].isLeft ? .right : .left
    }

    func shoulderAngle(_ frame: PoseFrame, side: BodySide, iso: IsoMetric) -> Double? {
        let (shoulder, elbow, hip): (JointName, JointName, JointName) = side == .left
            ? (.leftShoulder, .leftElbow, .leftHip)
            : (.rightShoulder, .rightElbow, .rightHip)
        guard let s = frame.joints[shoulder]?.point,
              let e = frame.joints[elbow]?.point,
              let h = frame.joints[hip]?.point else { return nil }
        let a = iso.angleDegrees(vertex: s, e, h)
        return a.isNaN ? nil : a
    }

    func elbowAngle(_ frame: PoseFrame, side: BodySide, iso: IsoMetric) -> Double? {
        let (shoulder, elbow, wrist): (JointName, JointName, JointName) = side == .left
            ? (.leftShoulder, .leftElbow, .leftWrist)
            : (.rightShoulder, .rightElbow, .rightWrist)
        guard let s = frame.joints[shoulder]?.point,
              let e = frame.joints[elbow]?.point,
              let w = frame.joints[wrist]?.point else { return nil }
        let a = iso.angleDegrees(vertex: e, s, w)
        return a.isNaN ? nil : a
    }

    func kneeOverAnkle(_ frame: PoseFrame, side: BodySide, scale: ClimbScale) -> Double? {
        let (knee, ankle): (JointName, JointName) = side == .left
            ? (.leftKnee, .leftAnkle)
            : (.rightKnee, .rightAnkle)
        guard let k = frame.joints[knee]?.point, let a = frame.joints[ankle]?.point else { return nil }
        let v = scale.iso.vector(from: a, to: k)
        return v.x / scale.torsoLength
    }
}
