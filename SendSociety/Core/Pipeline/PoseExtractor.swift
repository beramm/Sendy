import Foundation
import AVFoundation
import CoreVideo
import Vision

/// Pose is a **vendor choice**, not a project risk. Everything downstream talks
/// to this protocol so Vision can be swapped for RTMPose or MoveNet without a
/// single change outside this file.
public protocol PoseExtractor: Sendable {
    /// Extracts pose for a whole video. Must be cancellable via task
    /// cancellation and must not block the main actor.
    func extract(
        url: URL,
        config: TuningConfig,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> PoseSequence
}

public enum PoseExtractionError: Error, LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case cancelled
    case sourceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .readerFailed(let s): "Video decode failed: \(s)"
        case .cancelled: "Cancelled."
        case .sourceUnavailable(let s): s
        }
    }
}

/// Apple Vision, on device. `VNDetectHumanBodyPoseRequest` over frames decoded
/// with `AVAssetReader`.
///
/// Assumes exactly one climber in frame — multi-person detection is explicitly
/// out of scope, so the highest-confidence observation wins.
public struct VisionPoseExtractor: PoseExtractor {

    public init() {}

    public func extract(
        url: URL,
        config: TuningConfig,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> PoseSequence {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PoseExtractionError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds

        // The decoded buffer is in camera orientation; `preferredTransform`
        // says how to rotate it for display. Vision needs that as an
        // orientation, and the reported size must be the rotated one.
        let orientation = Self.orientation(for: transform)
        let displaySize = orientation.swapsAxes
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize

        let sourceRate = nominalRate > 0 ? Double(nominalRate) : 30
        let targetRate = max(1, config.workingFrameRate)
        // Never upsample: the working rate is a ceiling, not a target.
        let effectiveRate = min(targetRate, sourceRate)
        let sampleInterval = 1.0 / effectiveRate

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw PoseExtractionError.readerFailed("cannot attach track output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw PoseExtractionError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        var frames: [PoseFrame] = []
        var warnings: [String] = []
        var nextSampleTime = 0.0
        var emittedIndex = 0
        var decodedCount = 0
        var untrackedCount = 0
        var lastProgressReport = -1.0

        let request = VNDetectHumanBodyPoseRequest()

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw PoseExtractionError.cancelled
            }
            decodedCount += 1
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { continue }
            // Temporal downsample to the working rate so frame-indexed
            // thresholds mean the same thing on a 30fps and a 60fps source.
            guard pts + 1e-6 >= nextSampleTime else { continue }
            nextSampleTime = pts + sampleInterval

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: orientation.cgOrientation,
                options: [:]
            )
            var joints: [JointName: Joint] = [:]
            do {
                try handler.perform([request])
                if let observation = (request.results ?? [])
                    .max(by: { $0.confidence < $1.confidence }) {
                    joints = Self.joints(from: observation)
                }
            } catch {
                warnings.append("Vision failed on frame \(emittedIndex): \(error.localizedDescription)")
            }

            if joints.isEmpty { untrackedCount += 1 }

            frames.append(PoseFrame(index: emittedIndex, timeSeconds: pts, joints: joints))
            emittedIndex += 1

            if duration > 0 {
                let p = min(1, pts / duration)
                if p - lastProgressReport > 0.01 {
                    lastProgressReport = p
                    progress(p)
                }
            }
        }

        if reader.status == .failed {
            throw PoseExtractionError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        progress(1)

        if frames.isEmpty {
            warnings.append("No frames decoded from \(url.lastPathComponent).")
        } else if untrackedCount > frames.count / 2 {
            warnings.append("No person detected in \(untrackedCount) of \(frames.count) frames — check framing and lighting.")
        } else if untrackedCount > 0 {
            warnings.append("\(untrackedCount) of \(frames.count) frames had no detection.")
        }
        if decodedCount > 0 && effectiveRate < targetRate - 0.5 {
            warnings.append(String(format: "Source is %.0ffps; working rate reduced to %.0ffps.", sourceRate, effectiveRate))
        }

        return PoseSequence(
            frames: frames,
            space: .image,
            frameRate: effectiveRate,
            sourceWidth: Int(displaySize.width.rounded()),
            sourceHeight: Int(displaySize.height.rounded()),
            warnings: warnings
        )
    }

    // MARK: Vision plumbing

    static func joints(from observation: VNHumanBodyPoseObservation) -> [JointName: Joint] {
        guard let points = try? observation.recognizedPoints(.all) else { return [:] }
        var out: [JointName: Joint] = [:]
        for (vnName, mapped) in visionJointMap {
            guard let p = points[vnName], p.confidence > 0 else { continue }
            // Vision's normalized space is already origin-bottom-left, y up —
            // the same convention wall space uses.
            out[mapped] = Joint(
                point: Point2D(x: Double(p.location.x), y: Double(p.location.y)),
                confidence: Double(p.confidence)
            )
        }
        return out
    }

    static let visionJointMap: [VNHumanBodyPoseObservation.JointName: JointName] = [
        .nose: .nose, .leftEye: .leftEye, .rightEye: .rightEye,
        .leftEar: .leftEar, .rightEar: .rightEar, .neck: .neck,
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow, .rightElbow: .rightElbow,
        .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
        .root: .root
    ]

    /// Video orientation derived from a track's preferred transform.
    public enum VideoOrientation: Sendable {
        case up, right, down, left

        public var swapsAxes: Bool { self == .right || self == .left }

        public var cgOrientation: CGImagePropertyOrientation {
            switch self {
            case .up: .up
            case .right: .right
            case .down: .down
            case .left: .left
            }
        }
    }

    public static func orientation(for t: CGAffineTransform) -> VideoOrientation {
        // Compare against the four rotation cases; anything else falls back to
        // .up rather than failing, because a slightly odd transform is not a
        // reason to refuse the clip.
        let eps = 0.01
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < eps }
        if near(t.a, 0), near(t.b, 1), near(t.c, -1), near(t.d, 0) { return .right }
        if near(t.a, 0), near(t.b, -1), near(t.c, 1), near(t.d, 0) { return .left }
        if near(t.a, -1), near(t.b, 0), near(t.c, 0), near(t.d, -1) { return .down }
        return .up
    }
}
