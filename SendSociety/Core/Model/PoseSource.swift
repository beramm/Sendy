import Foundation

/// Which pose model produced a `PoseSequence`.
///
/// Deliberately **not** part of `TuningConfig`. Every field in that struct obeys
/// one rule — changing it re-runs from `ContactDetector` onward and never
/// re-extracts pose — and the pose source is precisely the thing that must
/// re-extract. Putting it there would quietly break the guarantee the whole
/// tuning loop rests on, so it lives on `ClimbSession` instead.
public enum PoseSource: String, Sendable, Codable, CaseIterable, Identifiable, Hashable {
    /// `VNDetectHumanBodyPoseRequest`. 19 joints, no fingers or toes.
    case vision
    /// RTMPose via Core ML. 133 COCO-WholeBody keypoints, mapped down to the
    /// same 19 `JointName` cases, with feet and hands available for later.
    case rtmPose

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vision: "Apple Vision"
        case .rtmPose: "RTMPose"
        }
    }

    public var detail: String {
        switch self {
        case .vision: "19 joints, on device. No fingers or toes."
        case .rtmPose: "133 keypoints including feet and hands."
        }
    }
}

/// Chooses an extractor for a source.
///
/// The point of `PoseExtractor` being a protocol since day one. Adding a model
/// means registering a builder here and nothing else — no stage downstream
/// knows or cares which model produced the joints it is reading.
///
/// RTMPose is *registered by the app* rather than constructed here, because it
/// needs ONNX Runtime, which is an app-target dependency. Core has to keep
/// building on macOS for the test suite and the CLI, so it cannot link it.
public enum PoseExtractorFactory {
    /// Guarded because registration happens once at launch and reads happen
    /// from the processing actor.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var builders: [PoseSource: @Sendable () -> any PoseExtractor] = [:]

    /// Called by the app at startup for sources it can supply.
    public static func register(_ source: PoseSource, builder: @escaping @Sendable () -> any PoseExtractor) {
        lock.withLock { builders[source] = builder }
    }

    public static func make(_ source: PoseSource) -> any PoseExtractor {
        if let builder = lock.withLock({ builders[source] }) { return builder() }
        switch source {
        case .vision: return VisionPoseExtractor()
        case .rtmPose: return UnavailablePoseExtractor(source: source)
        }
    }

    /// Whether a source can actually run here. The picker shows an unavailable
    /// source rather than hiding it, so the reason is visible.
    public static func isAvailable(_ source: PoseSource) -> Bool {
        if lock.withLock({ builders[source] }) != nil { return true }
        return source == .vision
    }
}

/// Stands in for a source this build cannot run.
///
/// It fails loudly and specifically rather than silently falling back to
/// Vision. A silent fallback would produce a "comparison" in which both sides
/// are the same model — the same failure `SessionStore`'s per-source cache
/// keying guards against, arriving by a different route.
public struct UnavailablePoseExtractor: PoseExtractor {
    public let source: PoseSource

    public init(source: PoseSource) {
        self.source = source
    }

    public func extract(
        url: URL,
        config: TuningConfig,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> PoseSequence {
        throw PoseExtractionError.sourceUnavailable(
            "\(source.displayName) is not available in this build. Run it on desktop with Tools/rtmpose and import the pose, or select Apple Vision."
        )
    }
}
