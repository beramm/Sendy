import Foundation

/// Every joint reported by `HumanBodyPose3DObservation` in the installed
/// Vision SDK. This stays separate from the analytical 2D `JointName` model:
/// the center-line head and torso joints exist only in Vision's 3D topology.
public enum JointName3D: String, Sendable, Codable, CaseIterable, Hashable {
    case topHead
    case centerHead
    case centerShoulder
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case spine
    case root
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
}

extension JointName3D: CodingKeyRepresentable {}

/// The complete visualization-only Vision 3D hierarchy. Every supported joint
/// participates in at least one segment.
public let skeleton3DBones: [(JointName3D, JointName3D)] = [
    (.topHead, .centerHead),
    (.centerHead, .centerShoulder),
    (.centerShoulder, .leftShoulder), (.centerShoulder, .rightShoulder),
    (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
    (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
    (.centerShoulder, .spine), (.spine, .root),
    (.root, .leftHip), (.root, .rightHip),
    (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
    (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
]

/// A camera-relative 3D point in metres, as reported by Vision.
public struct Point3D: Sendable, Codable, Hashable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// One recognized body joint in camera-relative 3D space.
public struct Joint3D: Sendable, Codable, Hashable {
    public var point: Point3D
    public var confidence: Double

    public init(point: Point3D, confidence: Double) {
        self.point = point
        self.confidence = confidence
    }
}

/// The visualization-only 3D pose corresponding to one emitted 2D pose frame.
public struct PoseFrame3D: Sendable, Codable, Hashable {
    public var index: Int
    public var timeSeconds: Double
    public var joints: [JointName3D: Joint3D]

    public init(index: Int, timeSeconds: Double, joints: [JointName3D: Joint3D]) {
        self.index = index
        self.timeSeconds = timeSeconds
        self.joints = joints
    }

    public subscript(_ name: JointName3D) -> Joint3D? { joints[name] }
}

/// A 3D visualization sequence. It deliberately carries no analytical or
/// wall-space state: moves, timing, metrics and alignment remain 2D-owned.
public struct PoseSequence3D: Sendable, Codable {
    /// Version 1 caches predate Vision's head/spine/center-shoulder joints.
    /// They remain decodable so storage can reject them deliberately and run
    /// only the inexpensive 3D-only regeneration path.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var frames: [PoseFrame3D]
    public var frameRate: Double
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var warnings: [String]

    public init(
        frames: [PoseFrame3D],
        frameRate: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        warnings: [String] = [],
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.frames = frames
        self.frameRate = frameRate
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.warnings = warnings
    }

    public var count: Int { frames.count }
    public var isEmpty: Bool { frames.isEmpty }

    public func frame(at index: Int) -> PoseFrame3D? {
        guard frames.indices.contains(index) else { return nil }
        return frames[index]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, frames, frameRate, sourceWidth, sourceHeight, warnings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        frames = try container.decode([PoseFrame3D].self, forKey: .frames)
        frameRate = try container.decode(Double.self, forKey: .frameRate)
        sourceWidth = try container.decode(Int.self, forKey: .sourceWidth)
        sourceHeight = try container.decode(Int.self, forKey: .sourceHeight)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(frames, forKey: .frames)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(sourceWidth, forKey: .sourceWidth)
        try container.encode(sourceHeight, forKey: .sourceHeight)
        try container.encode(warnings, forKey: .warnings)
    }
}
