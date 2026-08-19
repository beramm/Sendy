import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import Vision

public struct AlignmentResult: Sendable, Codable {
    /// Maps a point in the attempt's normalized image space into the shared
    /// wall space, which is defined as the reference video's image space.
    public var homography: Homography
    /// Mean residual displacement in wall-widths after warping. Above
    /// `TuningConfig.registrationResidualLimit` the two clips aren't comparable.
    public var residual: Double
    public var referenceFrameIndex: Int
    public var attemptFrameIndex: Int
    public var succeeded: Bool
    public var warnings: [String]

    public init(
        homography: Homography,
        residual: Double,
        referenceFrameIndex: Int,
        attemptFrameIndex: Int,
        succeeded: Bool,
        warnings: [String]
    ) {
        self.homography = homography
        self.residual = residual
        self.referenceFrameIndex = referenceFrameIndex
        self.attemptFrameIndex = attemptFrameIndex
        self.succeeded = succeeded
        self.warnings = warnings
    }

    /// The identity alignment, used when registration fails. The pipeline keeps
    /// running with a visible warning rather than showing a blank screen — but
    /// `succeeded` is false and the UI must say so.
    public static func failed(_ reason: String, referenceFrameIndex: Int = 0, attemptFrameIndex: Int = 0) -> AlignmentResult {
        AlignmentResult(
            homography: .identity,
            residual: .infinity,
            referenceFrameIndex: referenceFrameIndex,
            attemptFrameIndex: attemptFrameIndex,
            succeeded: false,
            warnings: [reason]
        )
    }
}

/// Registers the attempt video's wall onto the reference video's wall.
///
/// The tripod **will** move — between clips, and per-frame if iPhone video
/// stabilization is left on. This step is mandatory, not an optimization.
/// Climbing walls register well: holds are high-contrast, textured and
/// non-repeating.
public struct WallAligner: Sendable {

    public init() {}

    // MARK: Frame selection (task 2.2)

    /// Picks the frame where the climber occupies the least image area, since
    /// the body is the only moving occluder on an otherwise static wall.
    /// Usually the first or last frame — climber on the ground or off frame.
    public static func registrationFrameIndex(for sequence: PoseSequence) -> Int {
        guard !sequence.frames.isEmpty else { return 0 }
        var bestIndex = 0
        var bestArea = Double.infinity
        for frame in sequence.frames {
            let points = frame.joints.values.map(\.point)
            // No detection at all is the ideal registration frame: an empty
            // wall. Score it as zero area.
            let area: Double
            if points.isEmpty {
                area = 0
            } else {
                let xs = points.map(\.x), ys = points.map(\.y)
                area = (xs.max()! - xs.min()!) * (ys.max()! - ys.min()!)
            }
            if area < bestArea {
                bestArea = area
                bestIndex = frame.index
            }
        }
        return bestIndex
    }

    // MARK: Registration

    /// Registers `attempt` onto `reference`.
    ///
    /// `mask` regions (the climbers' bounding boxes, in normalized coordinates)
    /// are filled flat before registration so the two bodies don't contribute
    /// features — the wall must drive the match, not the person.
    public func align(
        reference: CGImage,
        attempt: CGImage,
        referenceMask: CGRect? = nil,
        attemptMask: CGRect? = nil,
        referenceFrameIndex: Int = 0,
        attemptFrameIndex: Int = 0,
        config: TuningConfig
    ) -> AlignmentResult {
        let refPrepared = Self.mask(reference, rect: referenceMask)
        // Registration needs both images on the same pixel grid. A tripod pair
        // shot back to back always is, but a clip re-shot at a different
        // resolution is not, and refusing that outright would be a worse
        // failure than resampling it. Coordinates are normalized either way,
        // so this changes nothing downstream.
        let attPrepared = Self.resize(
            Self.mask(attempt, rect: attemptMask),
            to: CGSize(width: refPrepared.width, height: refPrepared.height)
        )

        guard let h = Self.homography(from: attPrepared, to: refPrepared) else {
            return .failed(
                "Registration failed — the two clips could not be matched. Re-record from the same tripod position with stabilization off.",
                referenceFrameIndex: referenceFrameIndex,
                attemptFrameIndex: attemptFrameIndex
            )
        }

        // Residual: warp the attempt by the recovered homography and register a
        // second time. A converged alignment leaves a near-identity residual;
        // the mean grid displacement of that residual is the error, in
        // wall-widths.
        var residual = Double.infinity
        if let warped = Self.warp(attPrepared, by: h, like: refPrepared),
           let second = Self.homography(from: warped, to: refPrepared) {
            residual = Self.meanGridDisplacement(second)
        } else {
            // Second pass could not run. That is not proof of failure, so keep
            // the transform and say the residual is unknown.
            residual = .nan
        }

        var warnings: [String] = []
        var succeeded = true
        if residual.isNaN {
            warnings.append("Registration residual could not be measured; alignment quality is unverified.")
        } else if residual > config.registrationResidualLimit {
            succeeded = false
            warnings.append(String(
                format: "Registration residual %.3f exceeds the limit %.3f. The two clips are probably not the same wall from the same position — re-record rather than trusting this comparison.",
                residual, config.registrationResidualLimit
            ))
        }
        if h.isIdentity {
            warnings.append("Registration returned the identity transform; the clips may already be aligned, or feature matching found nothing.")
        }

        return AlignmentResult(
            homography: h,
            residual: residual,
            referenceFrameIndex: referenceFrameIndex,
            attemptFrameIndex: attemptFrameIndex,
            succeeded: succeeded,
            warnings: warnings
        )
    }

    /// Runs `VNHomographicImageRegistrationRequest` and converts the result
    /// into a homography over **normalized** coordinates.
    ///
    /// Two conventions had to be pinned down empirically, and both are held in
    /// place by tests rather than by belief:
    ///
    /// 1. `warpTransform` operates on **pixel** coordinates, so it is
    ///    conjugated by the normalize/denormalize scaling here.
    /// 2. It maps **reference → floating**, the opposite direction to this
    ///    function's contract, so it is inverted.
    ///
    /// `WallAlignerTests.recoversKnownHomography` measures (2) against a known
    /// transform, and `warpDirection` independently pins the direction of
    /// `warp(_:by:like:)` so a sign error in one cannot silently cancel a sign
    /// error in the other.
    public static func homography(from floating: CGImage, to reference: CGImage) -> Homography? {
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: reference, options: [:])
        let handler = VNImageRequestHandler(cgImage: floating, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageHomographicAlignmentObservation else {
            return nil
        }
        let m = observation.warpTransform
        let pixel = Homography(m: [
            Double(m[0][0]), Double(m[1][0]), Double(m[2][0]),
            Double(m[0][1]), Double(m[1][1]), Double(m[2][1]),
            Double(m[0][2]), Double(m[1][2]), Double(m[2][2])
        ])
        return normalized(pixel, width: floating.width, height: floating.height).inverted
    }

    /// Conjugates a pixel-space homography into normalized `[0,1]` space:
    /// `H_norm = S⁻¹ · H_pixel · S`, where `S` scales normalized to pixels.
    static func normalized(_ pixel: Homography, width: Int, height: Int) -> Homography {
        let w = Double(width), h = Double(height)
        guard w > 0, h > 0 else { return pixel }
        let toPixels = Homography(m: [w, 0, 0, 0, h, 0, 0, 0, 1])
        let toNormalized = Homography(m: [1 / w, 0, 0, 0, 1 / h, 0, 0, 0, 1])
        // `concatenated(with:)` applies the receiver first.
        return toPixels.concatenated(with: pixel).concatenated(with: toNormalized)
    }

    /// Mean displacement over a 5×5 grid of normalized points. The single
    /// number that says how well two frames line up.
    public static func meanGridDisplacement(_ h: Homography) -> Double {
        var total = 0.0
        var n = 0
        for i in 0 ..< 5 {
            for j in 0 ..< 5 {
                let p = Point2D(x: Double(i) / 4, y: Double(j) / 4)
                total += p.distance(to: h.apply(to: p))
                n += 1
            }
        }
        return n > 0 ? total / Double(n) : .infinity
    }

    // MARK: Image helpers

    /// Flattens a rectangle of the image so the climber's body contributes no
    /// features to registration.
    static func mask(_ image: CGImage, rect: CGRect?) -> CGImage {
        guard let rect, rect.width > 0, rect.height > 0 else { return image }
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(
            x: rect.minX * Double(w),
            y: rect.minY * Double(h),
            width: rect.width * Double(w),
            height: rect.height * Double(h)
        ))
        return ctx.makeImage() ?? image
    }

    /// Resamples to a target pixel size, or returns the image unchanged when it
    /// is already that size.
    static func resize(_ image: CGImage, to size: CGSize) -> CGImage {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, image.width != width || image.height != height else { return image }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Warps `image` by a normalized-space homography, producing an image the
    /// same size as `template`.
    public static func warp(_ image: CGImage, by h: Homography, like template: CGImage) -> CGImage? {
        let w = Double(template.width), hgt = Double(template.height)
        // Core Image works in pixels with a bottom-left origin, matching the
        // normalized convention, so the transform only needs rescaling.
        let pixelH = pixelSpace(h, width: image.width, height: image.height)
        let ci = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIPerspectiveTransformWithExtent")
        guard filter != nil else { return nil }

        func corner(_ x: Double, _ y: Double) -> CGPoint {
            let p = pixelH.apply(to: Point2D(x: x, y: y))
            return CGPoint(x: p.x, y: p.y)
        }
        let iw = Double(image.width), ih = Double(image.height)
        filter!.setValue(ci, forKey: kCIInputImageKey)
        filter!.setValue(CIVector(cgRect: CGRect(x: 0, y: 0, width: w, height: hgt)), forKey: "inputExtent")
        filter!.setValue(CIVector(cgPoint: corner(0, ih)), forKey: "inputTopLeft")
        filter!.setValue(CIVector(cgPoint: corner(iw, ih)), forKey: "inputTopRight")
        filter!.setValue(CIVector(cgPoint: corner(iw, 0)), forKey: "inputBottomRight")
        filter!.setValue(CIVector(cgPoint: corner(0, 0)), forKey: "inputBottomLeft")
        guard let output = filter!.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(output, from: CGRect(x: 0, y: 0, width: w, height: hgt))
    }

    /// Inverse of `normalized(_:width:height:)`.
    static func pixelSpace(_ normalizedH: Homography, width: Int, height: Int) -> Homography {
        let w = Double(width), h = Double(height)
        guard w > 0, h > 0 else { return normalizedH }
        let toPixels = Homography(m: [w, 0, 0, 0, h, 0, 0, 0, 1])
        let toNormalized = Homography(m: [1 / w, 0, 0, 0, 1 / h, 0, 0, 0, 1])
        return toNormalized.concatenated(with: normalizedH).concatenated(with: toPixels)
    }
}

// MARK: - Wall-space transform (task 2.4)

extension PoseSequence {
    /// Warps every joint into wall space. After this, no stage below
    /// `WallAligner` ever sees a per-video coordinate.
    public func warpedIntoWallSpace(by h: Homography) -> PoseSequence {
        var out = self
        out.space = .wall
        for i in out.frames.indices {
            for (name, joint) in out.frames[i].joints {
                out.frames[i].joints[name] = Joint(
                    point: h.apply(to: joint.point),
                    confidence: joint.confidence
                )
            }
        }
        return out
    }

    /// Bounding box of the tracked body in normalized coordinates, padded, for
    /// masking during registration.
    public func climberBounds(atFrame index: Int, padding: Double = 0.05) -> CGRect? {
        guard let frame = frame(at: index) else { return nil }
        let points = frame.joints.values.map(\.point)
        guard !points.isEmpty else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(
            x: max(0, xs.min()! - padding),
            y: max(0, ys.min()! - padding),
            width: min(1, xs.max()! - xs.min()! + padding * 2),
            height: min(1, ys.max()! - ys.min()! + padding * 2)
        )
    }
}

/// Pulls single frames out of a video as `CGImage`, for registration and for
/// the overlay renderer.
public struct VideoFrameSource: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `AVAssetImageGenerator` is not `Sendable`, so it is created and consumed
    /// entirely inside this call rather than stored and passed across
    /// isolation boundaries.
    public func image(atSeconds seconds: Double, maximumSize: CGSize = CGSize(width: 1280, height: 1280)) async throws -> CGImage {
        try await Self.image(url: url, seconds: seconds, maximumSize: maximumSize)
    }

    /// Several frames from one clip in a single pass.
    ///
    /// One generator for the whole batch rather than one per frame: the clean
    /// plate needs ~16 frames, and building 16 generators over the same asset
    /// re-reads its index 16 times. Results are keyed by the **requested**
    /// seconds, since the generator is free to return them out of order and to
    /// land on a nearby frame.
    ///
    /// Frames that fail are simply absent from the result — a clip with a bad
    /// frame still produces a plate from the rest of it.
    public static func images(url: URL, seconds: [Double], maximumSize: CGSize) async -> [Double: CGImage] {
        guard !seconds.isEmpty else { return [:] }
        nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = maximumSize

        let times = seconds.map { CMTime(seconds: $0, preferredTimescale: 600) }
        var byRequestedValue: [Int64: Double] = [:]
        for (time, second) in zip(times, seconds) { byRequestedValue[time.value] = second }

        var images: [Double: CGImage] = [:]
        for await result in generator.images(for: times) {
            guard let image = try? result.image,
                  let second = byRequestedValue[result.requestedTime.value] else { continue }
            images[second] = image
        }
        return images
    }

    public static func image(url: URL, seconds: Double, maximumSize: CGSize) async throws -> CGImage {
        nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = maximumSize
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return image
    }
}
