import CoreGraphics
import Foundation

/// A still of the wall with the climber removed.
///
/// Drawn behind the skeletons in skeleton-only mode, where holds are otherwise
/// numbered circles on flat grey and a hold derived two feet off a real one
/// looks exactly like a correct one.
///
/// **This is a backdrop and nothing else.** It never reaches `MetricsEngine`,
/// `RouteBuilder`, `ContactDetector` or registration. Every number in this app
/// is computed from pose; a picture of a wall is not evidence about a climber.
public struct WallPlate: Sendable {
    public var image: CGImage
    /// Share of pixels that had at least one sample with the climber elsewhere.
    /// Below 1 means some pixels fell back to the plain median and may ghost.
    public var coverage: Double
    public var sampleCount: Int
    public var warnings: [String]

    public init(image: CGImage, coverage: Double, sampleCount: Int, warnings: [String] = []) {
        self.image = image
        self.coverage = coverage
        self.sampleCount = sampleCount
        self.warnings = warnings
    }
}

/// Builds a clean plate from a clip by taking a **pose-masked temporal median**
/// over frames sampled across it.
///
/// The mask is the part that matters. A plain median needs every pixel to be
/// unoccluded in more than half the samples, and fails exactly where a climber
/// lingers — start holds, a long shake-out. Masking each sample by the pose
/// bounding box drops that requirement to *one* unoccluded sample per pixel.
/// The median over what survives then absorbs everything else that moved: a
/// bystander walking through, a brush on a mat, auto-exposure drift.
///
/// Wall space is the reference clip's own image space, so a plate built from
/// the reference needs no homography to sit under the skeleton canvas.
public struct WallPlateBuilder: Sendable {
    public init() {}

    /// One frame plus the region of it the climber occupies.
    public struct Sample: Sendable {
        public var image: CGImage
        /// Climber bounds, normalized and **y-up** — the pose convention, not
        /// the buffer's. `nil` masks nothing.
        public var mask: CGRect?

        public init(image: CGImage, mask: CGRect?) {
            self.image = image
            self.mask = mask
        }
    }

    public struct Result: Sendable {
        public var plate: WallPlate?
        public var warnings: [String]
    }

    /// Reads the clip and returns a plate, or nil with the reason in
    /// `warnings`. Uses the **already-cached** pose, so it never runs Vision.
    public func build(url: URL, pose: PoseSequence, config: TuningConfig) async -> Result {
        guard !pose.isEmpty else {
            return Result(plate: nil, warnings: ["No pose for this clip, so the wall backdrop could not be built. The skeleton view falls back to a plain background."])
        }
        let minimumSamples = 4
        guard pose.count >= minimumSamples else {
            return Result(plate: nil, warnings: ["This clip is \(pose.count) frames long — too short to build a wall backdrop from. The skeleton view falls back to a plain background."])
        }

        let wanted = min(max(minimumSamples, config.wallPlateSampleCount), pose.count)
        // Evenly spread, offset by half a step so neither end of the clip is
        // sampled twice — the first and last frames are the ones most likely to
        // catch the climber standing still.
        let indices = (0 ..< wanted).map { i in
            min(pose.count - 1, Int((Double(i) + 0.5) / Double(wanted) * Double(pose.count)))
        }
        let times = indices.compactMap { pose.frame(at: $0)?.timeSeconds }
        guard times.count == indices.count else {
            return Result(plate: nil, warnings: ["Could not read frame times for the wall backdrop."])
        }

        let side = Double(max(64, config.wallPlateMaxDimension))
        let decoded = await VideoFrameSource.images(
            url: url, seconds: times, maximumSize: CGSize(width: side, height: side)
        )

        var samples: [Sample] = []
        for (i, index) in indices.enumerated() {
            guard let image = decoded[times[i]] else { continue }
            samples.append(Sample(
                image: image,
                mask: pose.climberBounds(atFrame: index, padding: config.wallPlateMaskPadding)
            ))
        }
        guard samples.count >= minimumSamples else {
            return Result(plate: nil, warnings: ["Only \(samples.count) frames of this clip could be decoded, which is too few for a wall backdrop. The skeleton view falls back to a plain background."])
        }

        guard let composited = Self.composite(samples: samples, maxDimension: config.wallPlateMaxDimension) else {
            return Result(plate: nil, warnings: ["The wall backdrop could not be composited. The skeleton view falls back to a plain background."])
        }

        var warnings: [String] = []
        if composited.coverage < config.wallPlateCoverageFloor {
            warnings.append(String(
                format: "The climber covers %.0f%% of the wall in every sampled frame, so the backdrop ghosts there. It is a backdrop only — no measurement uses it.",
                (1 - composited.coverage) * 100
            ))
        }
        return Result(
            plate: WallPlate(
                image: composited.image,
                coverage: composited.coverage,
                sampleCount: samples.count,
                warnings: warnings
            ),
            warnings: warnings
        )
    }

    // MARK: The median itself

    /// Per-pixel median over the samples that do not have the climber there.
    ///
    /// Separated from decoding so it can be tested against ground truth with
    /// synthetic images and no video file: composite a known blob over a known
    /// image, mask the blob, assert the original comes back.
    ///
    /// Pixels with no unmasked sample fall back to the median of every sample —
    /// a ghost rather than a hole — and are counted out of `coverage`.
    public static func composite(samples: [Sample], maxDimension: Int) -> (image: CGImage, coverage: Double)? {
        guard let first = samples.first, samples.count >= 2 else { return nil }

        let longest = Double(max(first.width, first.height))
        let scale = longest > 0 ? min(1, Double(max(64, maxDimension)) / longest) : 1
        let width = max(1, Int((Double(first.width) * scale).rounded()))
        let height = max(1, Int((Double(first.height) * scale).rounded()))
        let rowBytes = width * 4
        let pixelCount = width * height

        // Rendered buffers, kept alive for as long as their pointers are used.
        var contexts: [CGContext] = []
        var masks: [(x0: Int, x1: Int, y0: Int, y1: Int)?] = []
        for sample in samples {
            guard let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            ctx.interpolationQuality = .medium
            ctx.draw(sample.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            contexts.append(ctx)
            masks.append(Self.bufferRect(sample.mask, width: width, height: height))
        }
        guard contexts.count >= 2 else { return nil }

        let n = contexts.count
        var output = [UInt8](repeating: 0, count: pixelCount * 4)
        var covered = 0

        let planes: [UnsafeMutablePointer<UInt8>] = contexts.compactMap {
            $0.data?.bindMemory(to: UInt8.self, capacity: pixelCount * 4)
        }
        guard planes.count == n else { return nil }

        output.withUnsafeMutableBufferPointer { out in
            // Scratch for one pixel's samples, insertion-sorted in place. n is
            // small (order 16), so this beats anything cleverer.
            var values = [UInt8](repeating: 0, count: n)
            values.withUnsafeMutableBufferPointer { scratch in
                for y in 0 ..< height {
                    for x in 0 ..< width {
                        let offset = y * rowBytes + x * 4
                        var unmasked = 0
                        for s in 0 ..< n {
                            if let m = masks[s], x >= m.x0, x < m.x1, y >= m.y0, y < m.y1 { continue }
                            unmasked += 1
                        }
                        let useAll = unmasked == 0
                        if !useAll { covered += 1 }

                        for channel in 0 ..< 3 {
                            var k = 0
                            for s in 0 ..< n {
                                if !useAll, let m = masks[s], x >= m.x0, x < m.x1, y >= m.y0, y < m.y1 { continue }
                                let v = planes[s][offset + channel]
                                var j = k
                                while j > 0, scratch[j - 1] > v {
                                    scratch[j] = scratch[j - 1]
                                    j -= 1
                                }
                                scratch[j] = v
                                k += 1
                            }
                            out[offset + channel] = k > 0 ? scratch[k / 2] : 0
                        }
                        out[offset + 3] = 255
                    }
                }
            }
        }

        guard let outContext = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let destination = outContext.data else { return nil }
        output.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: pixelCount * 4) }
        guard let image = outContext.makeImage() else { return nil }

        return (image, Double(covered) / Double(pixelCount))
    }

    /// Converts a pose-space rect (normalized, y-up, origin bottom-left) into
    /// half-open buffer row and column ranges (origin top-left).
    ///
    /// A `CGContext`'s backing buffer starts at the **top** row of the image
    /// while pose coordinates start at the bottom, so the y axis flips here and
    /// nowhere else.
    static func bufferRect(_ rect: CGRect?, width: Int, height: Int) -> (x0: Int, x1: Int, y0: Int, y1: Int)? {
        guard let rect, rect.width > 0, rect.height > 0 else { return nil }
        let x0 = max(0, Int((rect.minX * Double(width)).rounded(.down)))
        let x1 = min(width, Int((rect.maxX * Double(width)).rounded(.up)))
        let y0 = max(0, Int(((1 - rect.maxY) * Double(height)).rounded(.down)))
        let y1 = min(height, Int(((1 - rect.minY) * Double(height)).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, x1, y0, y1)
    }
}

private extension WallPlateBuilder.Sample {
    var width: Int { image.width }
    var height: Int { image.height }
}
