import Foundation
import AVFoundation
import CoreVideo
import Vision

/// Result of a shared-decode Vision pass. The existing `pose` name and model
/// remain the analytical 2D source of truth.
public struct PoseExtractionBundle: Sendable {
    public var pose: PoseSequence
    public var pose3D: PoseSequence3D

    public init(pose: PoseSequence, pose3D: PoseSequence3D) {
        self.pose = pose
        self.pose3D = pose3D
    }

    public func hasSynchronizedTimeline(tolerance: Double = 1e-6) -> Bool {
        guard pose.frames.count == pose3D.frames.count else { return false }
        return zip(pose.frames, pose3D.frames).allSatisfy { frame2D, frame3D in
            frame2D.index == frame3D.index
                && abs(frame2D.timeSeconds - frame3D.timeSeconds) <= tolerance
        }
    }
}

public protocol Pose3DExtractor: Sendable {
    func extract(
        url: URL,
        config: TuningConfig,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> PoseSequence3D
}

public protocol CombinedPoseExtractor: Sendable {
    func extract(
        url: URL,
        config: TuningConfig,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> PoseExtractionBundle
}

/// Apple Vision 3D-only extraction, used when analytical 2D pose is cached.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, *)
public struct VisionPose3DExtractor: Pose3DExtractor {
    public init() {}

    public func extract(
        url: URL,
        config: TuningConfig,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> PoseSequence3D {
        try await VisionPoseExtractionLoop.extract(
            url: url,
            config: config,
            include2D: false,
            progress: progress
        ).pose3D
    }
}

/// Runs modern 2D and 3D Vision requests against the same sampled pixel
/// buffer. A 3D miss or request error always emits an empty 3D frame so the
/// analytical 2D frame timeline can never shift beneath the renderer.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, *)
public struct VisionCombinedPoseExtractor: CombinedPoseExtractor {
    public init() {}

    public func extract(
        url: URL,
        config: TuningConfig,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> PoseExtractionBundle {
        let result = try await VisionPoseExtractionLoop.extract(
            url: url,
            config: config,
            include2D: true,
            progress: progress
        )
        guard let pose = result.pose else {
            throw PoseExtractionError.readerFailed("combined extraction produced no 2D sequence")
        }
        return PoseExtractionBundle(pose: pose, pose3D: result.pose3D)
    }
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, *)
private enum VisionPoseExtractionLoop {
    struct Result {
        var pose: PoseSequence?
        var pose3D: PoseSequence3D
    }

    static func extract(
        url: URL,
        config: TuningConfig,
        include2D: Bool,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> Result {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PoseExtractionError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let orientation = VisionPoseExtractor.orientation(for: transform)
        let displaySize = orientation.swapsAxes
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize

        let sourceRate = nominalRate > 0 ? Double(nominalRate) : 30
        let targetRate = max(1, config.workingFrameRate)
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

        var frames2D: [PoseFrame] = []
        var frames3D: [PoseFrame3D] = []
        var warnings2D: [String] = []
        var warnings3D: [String] = []
        var nextSampleTime = 0.0
        var emittedIndex = 0
        var decodedCount = 0
        var untracked2DCount = 0
        var untracked3DCount = 0
        var lastProgressReport = -1.0

        var poseRequest = DetectHumanBodyPoseRequest()
        poseRequest.detectsHands = false
        let pose3DRequest = DetectHumanBodyPose3DRequest()

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw PoseExtractionError.cancelled
            }
            decodedCount += 1
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { continue }
            guard pts + 1e-6 >= nextSampleTime else { continue }
            nextSampleTime = pts + sampleInterval
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            let handler = ImageRequestHandler(pixelBuffer, orientation: orientation.cgOrientation)

            var joints2D: [JointName: Joint] = [:]
            if include2D {
                do {
                    let observations = try await handler.perform(poseRequest)
                    if let observation = observations.max(by: { $0.confidence < $1.confidence }) {
                        joints2D = joints(from: observation)
                    }
                } catch {
                    warnings2D.append("Vision 2D failed on frame \(emittedIndex): \(error.localizedDescription)")
                }
                if joints2D.isEmpty { untracked2DCount += 1 }
                frames2D.append(PoseFrame(index: emittedIndex, timeSeconds: pts, joints: joints2D))
            }

            var joints3D: [JointName: Joint3D] = [:]
            do {
                // Separate performs preserve the usable 2D result if the 3D
                // stateful request fails, while still sharing this exact source
                // pixel buffer and sampling decision.
                let observations = try await handler.perform(pose3DRequest)
                if let observation = observations.max(by: { $0.confidence < $1.confidence }) {
                    joints3D = joints(from: observation)
                }
            } catch {
                warnings3D.append("Vision 3D failed on frame \(emittedIndex): \(error.localizedDescription)")
            }
            if joints3D.isEmpty { untracked3DCount += 1 }
            frames3D.append(PoseFrame3D(index: emittedIndex, timeSeconds: pts, joints: joints3D))
            emittedIndex += 1

            if duration > 0 {
                let value = min(1, pts / duration)
                if value - lastProgressReport > 0.01 {
                    lastProgressReport = value
                    progress(value)
                }
            }
        }

        if reader.status == .failed {
            throw PoseExtractionError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        progress(1)

        appendSummaryWarnings(
            to: &warnings3D,
            label: "3D body",
            frameCount: frames3D.count,
            untrackedCount: untracked3DCount,
            filename: url.lastPathComponent
        )
        if include2D {
            appendSummaryWarnings(
                to: &warnings2D,
                label: "person",
                frameCount: frames2D.count,
                untrackedCount: untracked2DCount,
                filename: url.lastPathComponent
            )
        }
        if decodedCount > 0 && effectiveRate < targetRate - 0.5 {
            let warning = String(format: "Source is %.0ffps; working rate reduced to %.0ffps.", sourceRate, effectiveRate)
            if include2D { warnings2D.append(warning) }
            warnings3D.append(warning)
        }

        let width = Int(displaySize.width.rounded())
        let height = Int(displaySize.height.rounded())
        let pose = include2D ? PoseSequence(
            frames: frames2D,
            space: .image,
            frameRate: effectiveRate,
            sourceWidth: width,
            sourceHeight: height,
            warnings: warnings2D
        ) : nil
        let pose3D = PoseSequence3D(
            frames: frames3D,
            frameRate: effectiveRate,
            sourceWidth: width,
            sourceHeight: height,
            warnings: warnings3D
        )
        return Result(pose: pose, pose3D: pose3D)
    }

    static func joints(from observation: HumanBodyPoseObservation) -> [JointName: Joint] {
        let recognized = observation.allJoints()
        var output: [JointName: Joint] = [:]
        for (visionName, appName) in pose2DJointMap {
            guard let joint = recognized[visionName], joint.confidence > 0 else { continue }
            output[appName] = Joint(
                point: Point2D(x: Double(joint.location.x), y: Double(joint.location.y)),
                confidence: Double(joint.confidence)
            )
        }
        return output
    }

    static func joints(from observation: HumanBodyPose3DObservation) -> [JointName: Joint3D] {
        var output: [JointName: Joint3D] = [:]
        for (visionName, appName) in pose3DJointMap {
            guard observation.joint(for: visionName) != nil else { continue }
            let transform = observation.cameraRelativePosition(for: visionName)
            let position = transform.columns.3
            output[appName] = Joint3D(
                point: Point3D(x: position.x, y: position.y, z: position.z),
                confidence: Double(observation.confidence)
            )
        }
        return output
    }

    static func appendSummaryWarnings(
        to warnings: inout [String],
        label: String,
        frameCount: Int,
        untrackedCount: Int,
        filename: String
    ) {
        if frameCount == 0 {
            warnings.append("No frames decoded from \(filename).")
        } else if untrackedCount > frameCount / 2 {
            warnings.append("No \(label) detected in \(untrackedCount) of \(frameCount) frames — check framing and lighting.")
        } else if untrackedCount > 0 {
            warnings.append("\(untrackedCount) of \(frameCount) frames had no \(label) detection.")
        }
    }

    static let pose2DJointMap: [HumanBodyPoseObservation.JointName: JointName] = [
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

    /// Only exact semantic matches. Vision 3D's centerHead/topHead/spine and
    /// centerShoulder are intentionally not renamed to the 2D neck/nose model.
    static let pose3DJointMap: [HumanBodyPose3DObservation.JointName: JointName] = [
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow, .rightElbow: .rightElbow,
        .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
        .root: .root
    ]
}
