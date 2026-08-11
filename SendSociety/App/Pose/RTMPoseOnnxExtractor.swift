import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import CoreImage
import ImageIO
import Vision
// In the app target this file is part of the same module as Core; in the SwiftPM
// build it is a separate target, so the CLI can exercise it against the Python
// implementation. Same source, two dependency graphs.
#if canImport(VideoOverlapCore)
import VideoOverlapCore
#endif
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

/// `Joint` is ambiguous once ARKit is in scope — it has one too. Naming the
/// pipeline's type explicitly avoids depending on which frameworks a given
/// target happens to import.
#if canImport(VideoOverlapCore)
typealias PoseJoint = VideoOverlapCore.Joint
#else
typealias PoseJoint = Joint
#endif

/// RTMPose on device, through ONNX Runtime.
///
/// **The same `.onnx` file the desktop script runs.** That is the point: a
/// Core ML conversion would have been a third artifact, and any difference
/// between phone and Mac could not then be attributed to the model or to the
/// conversion without redoing the whole comparison.
///
/// Vision supplies the person box instead of the 97 MB YOLOX detector the
/// Python side uses — Vision already locates a person for free, and dropping
/// YOLOX removes both a large download and a moving part. The split is Vision
/// for *finding* the climber, RTMPose for *keypoints*.
///
/// The arithmetic — SimCC decoding, the box transform, the coordinate flip —
/// lives in `RTMPoseDecoding` in Core, where it is unit-tested without needing
/// the model. Only session handling and pixel wrangling are here.
public struct RTMPoseOnnxExtractor: PoseExtractor {

    public init() {}

    public enum ModelError: Error, LocalizedError {
        case modelMissing
        case sessionFailed(String)
        case badOutput(String)

        public var errorDescription: String? {
            switch self {
            case .modelMissing:
                "The RTMPose model is not in the app bundle. Run Tools/rtmpose/fetch-model.sh and rebuild."
            case .sessionFailed(let s): "RTMPose could not start: \(s)"
            case .badOutput(let s): "RTMPose returned something unexpected: \(s)"
            }
        }
    }

    /// Set to run the model from a path rather than the app bundle — which is
    /// how the CLI checks this implementation against the Python one.
    nonisolated(unsafe) public static var explicitModelPath: String?

    /// Whether to hand the graph to CoreML (Neural Engine / GPU).
    ///
    /// **On by default, and the measurements are emphatic.** On the same clip
    /// and model:
    ///
    /// | | peak memory | throughput |
    /// |---|---|---|
    /// | CPU | 1.85 GB | 35 fps |
    /// | CoreML | **0.66 GB** | **80 fps** |
    ///
    /// Nearly 3× less memory *and* over twice the speed, because ONNX Runtime's
    /// CPU arena allocator grows across runs — measured climbing from 0.6 GB at
    /// 15 frames to 2.2 GB at 432, which is what terminated the app on device.
    /// CoreML takes most of the graph, so that arena barely gets used.
    ///
    /// This default was briefly set the other way on the theory that CoreML's
    /// per-session graph compilation was stalling startup. Measurement refuted
    /// it: the whole 432-frame run including model load takes 5.4 s.
    nonisolated(unsafe) public static var useCoreML = true

    /// Diagnostic: run everything except the model, to tell whether growing
    /// memory is the image pipeline or ONNX Runtime.
    nonisolated(unsafe) public static var skipInference = false

    public static var modelURL: URL? {
        if let explicitModelPath { return URL(fileURLWithPath: explicitModelPath) }
        return Bundle.main.url(forResource: "rtmpose_wholebody", withExtension: "onnx")
    }

    public static var isInstalled: Bool {
        #if canImport(OnnxRuntimeBindings)
        return modelURL != nil
        #else
        return false
        #endif
    }

    public func extract(
        url: URL,
        config: TuningConfig,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> PoseSequence {
        #if canImport(OnnxRuntimeBindings)
        guard let modelURL = Self.modelURL else { throw ModelError.modelMissing }

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
        let effectiveRate = min(max(1, config.workingFrameRate), sourceRate)
        let sampleInterval = 1.0 / effectiveRate

        let session: ORTSession
        var accelerator = "CPU"
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()

            // Neural Engine / GPU where available. Without this the model runs
            // CPU-only, which is fine on a Mac and slow on a phone — this model
            // is the large wholebody variant, and a 400-frame clip is a long
            // wait at CPU speed.
            //
            // Falls back silently to CPU when the provider is unavailable or
            // refuses the graph, because a slower extraction is a far better
            // outcome than a failed one.
            if Self.useCoreML, ORTIsCoreMLExecutionProviderAvailable() {
                do {
                    try options.appendCoreMLExecutionProvider(with: ORTCoreMLExecutionProviderOptions())
                    accelerator = "CoreML"
                } catch {
                    accelerator = "CPU (CoreML refused the model: \(error.localizedDescription))"
                }
            }
            try options.setIntraOpNumThreads(2)

            // **Cap ONNX Runtime's memory, or iOS kills the app.**
            //
            // The default CPU arena allocator is tuned for servers: it grabs
            // large blocks and keeps them. Measured peak resident memory running
            // this model was 2.2 GB — more than with the *larger* model on
            // CoreML — which is what actually terminated the app on device, not
            // the size of the weights. Frame rate made no difference precisely
            // because this is a one-time allocation, not per-frame growth.
            //
            // Shrinking the arena to each request trades a little speed for a
            // flat, predictable footprint, which is the right trade on a phone.
            try options.addConfigEntry(withKey: "session.use_env_allocators", value: "0")
            try options.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")
            try options.setGraphOptimizationLevel(.all)

            session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        } catch {
            throw ModelError.sessionFailed(error.localizedDescription)
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PoseExtractionError.readerFailed("cannot attach track output") }
        reader.add(output)
        guard reader.startReading() else {
            throw PoseExtractionError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        var frames: [PoseFrame] = []
        var warnings: [String] = []
        var nextSampleTime = 0.0
        var emitted = 0
        var untracked = 0
        var lastProgress = -1.0
        // The climber rarely jumps between frames, so last frame's box is a good
        // prior. It also covers the frames where person detection blinks out,
        // which is where a per-frame detector would drop the whole pose.
        var lastBox: CGRect?

        // One context for the whole clip. Creating a `CIContext` per frame
        // rebuilds its internal caches and pipeline every time — it is one of
        // the more expensive objects in the framework.
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw PoseExtractionError.cancelled
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite, pts + 1e-6 >= nextSampleTime else { continue }
            nextSampleTime = pts + sampleInterval
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            // **Every frame's work goes inside an autorelease pool.**
            //
            // Without it, each full-resolution `CGImage` lives until the whole
            // loop finishes: 432 frames of 720×1280 RGBA is about 1.6 GB, which
            // a Mac absorbs and iOS terminates the app for. This crashed on
            // device the first time RTMPose was selected, and read as "the model
            // is too heavy" when the model was not the problem.
            let frameResult: (joints: [JointName: PoseJoint], box: CGRect?)? = autoreleasepool {
                guard let image = Self.cgImage(from: pixelBuffer, orientation: orientation, context: ciContext) else {
                    return nil
                }

                let size = CGSize(width: image.width, height: image.height)
            // Track the box from the previous frame's keypoints, and only fall
            // back to detection when that is unavailable or the result looks
            // wrong.
            //
            // Detecting afresh every frame was the single biggest source of
            // error: Vision's person detector is less reliable than the YOLOX
            // the reference implementation uses, and on a busy wall with a small
            // climber it periodically picked a different region entirely. Median
            // agreement with the reference was a few pixels while p90 was ~1000
            // — a minority of frames looking somewhere else completely.
                var box = lastBox ?? Self.personBox(in: image, orientation: orientation)
                var joints: [JointName: PoseJoint] = [:]
                if let candidate = box {
                    joints = (try? Self.keypoints(image: image, box: candidate, size: size, session: session)) ?? [:]
                }
            // A tracked box that produced nothing usable means the climber moved
            // out from under it: re-detect once rather than drifting for the
            // rest of the clip.
                if Self.meanConfidence(joints) < 0.3, let detected = Self.personBox(in: image, orientation: orientation) {
                    if let retry = try? Self.keypoints(image: image, box: detected, size: size, session: session),
                       Self.meanConfidence(retry) > Self.meanConfidence(joints) {
                        joints = retry
                        box = detected
                    }
                }
                return (joints, Self.trackedBox(from: joints, imageSize: size) ?? box)
            }

            // A `CIContext` caches intermediates internally, and reusing one
            // across a whole clip grows that cache by roughly a full frame each
            // time — the autorelease pool cannot help, because the context is
            // holding them deliberately. Memory rose from 0.6 GB at 15 frames to
            // 2.2 GB at 432, which is what terminated the app on device.
            //
            // Building a context per frame is the other extreme and is slow, so
            // the cache is cleared instead.
            ciContext.clearCaches()

            let joints = frameResult?.joints ?? [:]
            lastBox = frameResult?.box ?? lastBox
            if joints.isEmpty { untracked += 1 }

            frames.append(PoseFrame(index: emitted, timeSeconds: pts, joints: joints))
            emitted += 1

            if duration > 0 {
                let p = min(1, pts / duration)
                if p - lastProgress > 0.01 { lastProgress = p; progress(p) }
            }
        }

        if reader.status == .failed {
            throw PoseExtractionError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        progress(1)

        if frames.isEmpty {
            warnings.append("No frames decoded from \(url.lastPathComponent).")
        } else if untracked > frames.count / 2 {
            warnings.append("No person detected in \(untracked) of \(frames.count) frames — check framing and lighting.")
        } else if untracked > 0 {
            warnings.append("\(untracked) of \(frames.count) frames had no detection.")
        }
        let sizeMB = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? Int)
            .flatMap { $0 } .map { $0 / 1_000_000 } ?? 0
        warnings.append("Pose produced by RTMPose — \(modelURL.lastPathComponent), \(sizeMB) MB, \(accelerator). Not Apple Vision.")

        return PoseSequence(
            frames: frames,
            space: .image,
            frameRate: effectiveRate,
            sourceWidth: Int(displaySize.width.rounded()),
            sourceHeight: Int(displaySize.height.rounded()),
            warnings: warnings
        )
        #else
        throw PoseExtractionError.sourceUnavailable("ONNX Runtime is not linked into this build.")
        #endif
    }

    #if canImport(OnnxRuntimeBindings)

    /// One frame through the model.
    static func keypoints(
        image: CGImage, box: CGRect, size: CGSize, session: ORTSession
    ) throws -> [JointName: PoseJoint] {
        let transform = RTMPoseDecoding.boxTransform(for: box)
        guard let tensorData = inputTensor(image: image, transform: transform) else { return [:] }
        if skipInference { return [:] }

        let shape: [NSNumber] = [1, 3, NSNumber(value: RTMPoseDecoding.inputHeight), NSNumber(value: RTMPoseDecoding.inputWidth)]
        let input = try ORTValue(tensorData: NSMutableData(data: tensorData), elementType: .float, shape: shape)
        let outputs = try session.run(
            withInputs: ["input": input],
            outputNames: ["simcc_x", "simcc_y"],
            runOptions: nil
        )
        guard let xValue = outputs["simcc_x"], let yValue = outputs["simcc_y"] else {
            throw ModelError.badOutput("missing simcc outputs")
        }
        let simccX = try floats(from: xValue)
        let simccY = try floats(from: yValue)

        // Keypoint count comes from the data rather than being assumed, so a
        // body-only model would still decode instead of reading past the end.
        let xBins = Int(RTMPoseDecoding.splitRatio) * RTMPoseDecoding.inputWidth
        guard xBins > 0, simccX.count % xBins == 0 else {
            throw ModelError.badOutput("simcc_x length \(simccX.count) is not a multiple of \(xBins)")
        }
        let keypointCount = simccX.count / xBins

        let decoded = RTMPoseDecoding.decodeSimCC(simccX: simccX, simccY: simccY, keypointCount: keypointCount)
        let inSource = decoded.points.map { RTMPoseDecoding.toSourcePixels($0, transform: transform) }
        return RTMPoseDecoding.joints(from: inSource, scores: decoded.scores, imageSize: size)
    }

    static func floats(from value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    /// Crops to the padded box, resizes to the model's input, and writes
    /// normalized planar RGB.
    ///
    /// The model wants NCHW float — all reds, then all greens, then all blues —
    /// which is not how any image buffer is laid out, so the interleave is
    /// undone here explicitly.
    /// Set to a directory to dump the preprocessed crops. The crop is what the
    /// model actually sees, and looking at it is the only way to tell a wrong
    /// box from a wrong normalisation — both present as uniformly low
    /// confidence.
    nonisolated(unsafe) public static var debugCropDirectory: String?
    nonisolated(unsafe) static var debugCropIndex = 0

    static func inputTensor(image: CGImage, transform: RTMPoseDecoding.BoxTransform) -> Data? {
        let width = RTMPoseDecoding.inputWidth
        let height = RTMPoseDecoding.inputHeight
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Stay in CoreGraphics' native bottom-left space and convert the box
        // instead of flipping the context.
        //
        // Flipping the context also flips the image drawn into it, so the first
        // attempt produced a double flip *and* a y-offset in the wrong
        // direction: the crop came out upside down with the climber sliding off
        // the top edge. Uniformly low confidence on every joint was the only
        // symptom, which reads as a bad model rather than a bad crop — hence
        // `debugCropDirectory`.
        context.interpolationQuality = .high

        let originX = transform.centre.x - transform.scale.width / 2
        // The box is in top-left pixels; CoreGraphics wants bottom-left.
        let originY = CGFloat(image.height) - (transform.centre.y + transform.scale.height / 2)
        context.scaleBy(
            x: CGFloat(width) / transform.scale.width,
            y: CGFloat(height) / transform.scale.height
        )
        context.translateBy(x: -originX, y: -originY)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        if let dir = debugCropDirectory, debugCropIndex < 4 {
            if let cropped = context.makeImage() {
                let path = "\(dir)/crop_\(debugCropIndex).png"
                if let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
                ) {
                    CGImageDestinationAddImage(dest, cropped, nil)
                    CGImageDestinationFinalize(dest)
                    FileHandle.standardError.write("wrote \(path)\n".data(using: .utf8)!)
                }
            }
            debugCropIndex += 1
        }

        var tensor = [Float](repeating: 0, count: 3 * width * height)
        let plane = width * height
        let mean = RTMPoseDecoding.mean
        let std = RTMPoseDecoding.std
        for i in 0 ..< plane {
            let r = Double(pixels[i * 4 + 0])
            let g = Double(pixels[i * 4 + 1])
            let b = Double(pixels[i * 4 + 2])
            // Channel order was A/B tested once the crop geometry was correct:
            // RGB and BGR score within noise of each other (0.47 vs 0.46 mean
            // wrist confidence), so the model is insensitive to it despite the
            // reference implementation feeding OpenCV's BGR. RGB is kept because
            // it matches the byte layout already in hand.
            tensor[i] = Float((r - mean.r) / std.r)
            tensor[plane + i] = Float((g - mean.g) / std.g)
            tensor[2 * plane + i] = Float((b - mean.b) / std.b)
        }
        return tensor.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    #endif

    static func meanConfidence(_ joints: [JointName: PoseJoint]) -> Double {
        guard !joints.isEmpty else { return 0 }
        return joints.values.reduce(0) { $0 + $1.confidence } / Double(joints.count)
    }

    /// The next frame's box, from this frame's keypoints.
    ///
    /// Standard practice in top-down pose pipelines, and here it replaces a
    /// per-frame detector that was the main source of disagreement with the
    /// reference implementation. Returns `nil` when too little tracked to
    /// trust, so the caller re-detects rather than following a bad box.
    static func trackedBox(from joints: [JointName: PoseJoint], imageSize: CGSize) -> CGRect? {
        let points = joints.values.filter { $0.confidence > 0.3 }.map(\.point)
        guard points.count >= 6 else { return nil }
        let xs = points.map { $0.x * Double(imageSize.width) }
        // Joints are in Vision's bottom-left space; the box is top-left pixels.
        let ys = points.map { (1 - $0.y) * Double(imageSize.height) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard rect.width > 8, rect.height > 8 else { return nil }
        return rect
    }

    /// Vision's person detector, standing in for YOLOX.
    static func personBox(in image: CGImage, orientation: VisionPoseExtractor.VideoOrientation) -> CGRect? {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let best = (request.results ?? []).max(by: { $0.confidence < $1.confidence })
        else { return nil }

        // Vision reports a normalized bottom-left-origin box; the rest of this
        // file works in top-left pixels.
        let w = Double(image.width), h = Double(image.height)
        let b = best.boundingBox
        return CGRect(
            x: b.minX * w,
            y: (1 - b.maxY) * h,
            width: b.width * w,
            height: b.height * h
        )
    }

    static func cgImage(
        from buffer: CVPixelBuffer,
        orientation: VisionPoseExtractor.VideoOrientation,
        context: CIContext
    ) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: buffer).oriented(orientation.cgOrientation)
        return context.createCGImage(ci, from: ci.extent)
    }
}
