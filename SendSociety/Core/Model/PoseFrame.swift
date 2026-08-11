import Foundation

/// The 19 joints `VNDetectHumanBodyPoseRequest` reports.
///
/// No fingers, no toes — grip analysis and precise foot placement are out of
/// scope while Vision is the pose vendor. If `PoseExtractor` is swapped for a
/// 133-keypoint model, revisit that constraint rather than assuming it holds.
public enum JointName: String, Sendable, Codable, CaseIterable, Hashable {
    case nose, leftEye, rightEye, leftEar, rightEar, neck
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
    case root

    /// Wrists and ankles — the only joints that make contact with holds.
    public static let extremities: [JointName] = [.leftWrist, .rightWrist, .leftAnkle, .rightAnkle]
    public static let hands: [JointName] = [.leftWrist, .rightWrist]
    public static let feet: [JointName] = [.leftAnkle, .rightAnkle]
    /// Joints used to judge whether a frame tracked at all.
    public static let torso: [JointName] = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]

    public var isHand: Bool { JointName.hands.contains(self) }
    public var isFoot: Bool { JointName.feet.contains(self) }
    public var isLeft: Bool { rawValue.hasPrefix("left") }
    public var isRight: Bool { rawValue.hasPrefix("right") }
}

/// Makes `[JointName: Joint]` encode as a JSON **object** keyed by joint name
/// rather than Swift's default alternating `[key, value, key, value]` array.
///
/// This is interop, not cosmetics. The pose cache is the interchange format
/// between this app and any other pose model — an external script can write
/// the same file and it drops straight into the pipeline. An alternating array
/// is unreadable when debugging and needlessly hostile to produce elsewhere.
extension JointName: CodingKeyRepresentable {}

public struct Joint: Sendable, Codable, Hashable {
    public var point: Point2D
    public var confidence: Double

    public init(point: Point2D, confidence: Double) {
        self.point = point
        self.confidence = confidence
    }
}

/// One frame of pose. Coordinates are wall space once `WallAligner` has run,
/// normalized image space before that — `PoseSequence.space` records which.
///
/// `plan.md` specifies `CMTime`; this uses seconds because the type must be
/// `Codable` for the pose cache, and a `Double` round-trips losslessly enough
/// at video frame rates.
public struct PoseFrame: Sendable, Codable, Hashable {
    public var index: Int
    public var timeSeconds: Double
    public var joints: [JointName: Joint]

    public init(index: Int, timeSeconds: Double, joints: [JointName: Joint]) {
        self.index = index
        self.timeSeconds = timeSeconds
        self.joints = joints
    }

    public subscript(_ name: JointName) -> Joint? { joints[name] }

    public func point(_ name: JointName, minConfidence: Double = 0) -> Point2D? {
        guard let j = joints[name], j.confidence >= minConfidence else { return nil }
        return j.point
    }

    /// True when all four torso joints clear the floor. Frames that fail this
    /// are tracking failures; interpolating across them beats propagating them.
    public func torsoTracked(minConfidence: Double) -> Bool {
        JointName.torso.allSatisfy { (joints[$0]?.confidence ?? 0) >= minConfidence }
    }

    /// Midpoint of the two hips, or a single hip, or nil.
    public var hipCenter: Point2D? { midpoint(.leftHip, .rightHip) }
    public var shoulderCenter: Point2D? { midpoint(.leftShoulder, .rightShoulder) }

    public func midpoint(_ a: JointName, _ b: JointName) -> Point2D? {
        switch (joints[a]?.point, joints[b]?.point) {
        case let (p?, q?): return (p + q) * 0.5
        case let (p?, nil): return p
        case let (nil, q?): return q
        default: return nil
        }
    }

    /// Shoulder-centre to hip-centre distance. The normalizing length for every
    /// distance metric in the app — see `CLAUDE.md` "comparison is always
    /// normalized".
    public var torsoLength: Double? {
        guard let s = shoulderCenter, let h = hipCenter else { return nil }
        let d = s.distance(to: h)
        return d > 1e-6 ? d : nil
    }
}

/// Which coordinate frame a sequence's points live in.
public enum CoordinateSpace: String, Sendable, Codable {
    /// Normalized image space of the source video, `[0,1]`, y up.
    case image
    /// Canonical wall space shared by both videos, `[0,1]`, y up.
    case wall
}

/// A whole climb's worth of pose, plus the metadata needed to interpret it.
public struct PoseSequence: Sendable, Codable {
    public var frames: [PoseFrame]
    public var space: CoordinateSpace
    public var frameRate: Double
    /// Source pixel dimensions, kept only so aspect ratio can be undone when
    /// measuring lengths. Never used as a coordinate.
    public var sourceWidth: Int
    public var sourceHeight: Int
    /// Non-fatal problems found while extracting. Surfaced in the UI; never
    /// swallowed. Fail soft, never blank.
    public var warnings: [String]

    public init(
        frames: [PoseFrame],
        space: CoordinateSpace,
        frameRate: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        warnings: [String] = []
    ) {
        self.frames = frames
        self.space = space
        self.frameRate = frameRate
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.warnings = warnings
    }

    public var isEmpty: Bool { frames.isEmpty }
    public var count: Int { frames.count }
    public var durationSeconds: Double { (frames.last?.timeSeconds ?? 0) - (frames.first?.timeSeconds ?? 0) }

    /// Aspect ratio correction: normalized coordinates squash the longer axis,
    /// so a raw normalized distance is not isotropic. Multiply x by this before
    /// measuring lengths.
    public var xScale: Double {
        guard sourceHeight > 0 else { return 1 }
        return Double(sourceWidth) / Double(sourceHeight)
    }

    public func frame(at index: Int) -> PoseFrame? {
        guard index >= 0 && index < frames.count else { return nil }
        return frames[index]
    }

    /// Median shoulder-to-hip distance over the climb, in aspect-corrected wall
    /// units. **This is the project's unit of length.**
    ///
    /// Every spatial threshold is expressed in body-lengths and multiplied by
    /// this to reach wall units, which is what makes a threshold independent of
    /// how far back the tripod stood. A climber filling the frame and the same
    /// climber occupying a fifth of it must produce the same numbers.
    ///
    /// Returns `nil` when the torso never tracked — callers fall back and warn
    /// rather than dividing by a guess.
    public func medianTorsoLength(iso: IsoMetric) -> Double? {
        var lengths: [Double] = []
        for f in frames {
            guard let s = f.shoulderCenter, let h = f.hipCenter else { continue }
            let d = iso.distance(s, h)
            if d > 1e-6 { lengths.append(d) }
        }
        return lengths.median
    }
}
