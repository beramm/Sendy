import Foundation

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
    public var joints: [JointName: Joint3D]

    public init(index: Int, timeSeconds: Double, joints: [JointName: Joint3D]) {
        self.index = index
        self.timeSeconds = timeSeconds
        self.joints = joints
    }

    public subscript(_ name: JointName) -> Joint3D? { joints[name] }
}

/// A 3D visualization sequence. It deliberately carries no analytical or
/// wall-space state: moves, timing, metrics and alignment remain 2D-owned.
public struct PoseSequence3D: Sendable, Codable {
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
        warnings: [String] = []
    ) {
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
}
