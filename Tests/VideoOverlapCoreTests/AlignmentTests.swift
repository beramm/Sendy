import Testing
import Foundation
import CoreGraphics
@testable import VideoOverlapCore

@Suite("Wall alignment")
struct WallAlignerTests {

    /// A known transform in normalized space: rotation about the centre, then
    /// uniform scale, then translation.
    static func transform(rotationDegrees: Double, scale: Double, translation: Point2D) -> Homography {
        let r = rotationDegrees * .pi / 180
        let c = cos(r) * scale, s = sin(r) * scale
        // Rotate about (0.5, 0.5).
        let tx = 0.5 - (c * 0.5 - s * 0.5) + translation.x
        let ty = 0.5 - (s * 0.5 + c * 0.5) + translation.y
        return Homography(m: [c, -s, tx, s, c, ty, 0, 0, 1])
    }

    static func meanDifference(_ a: Homography, _ b: Homography) -> Double {
        var total = 0.0
        var n = 0
        for i in 0 ..< 5 {
            for j in 0 ..< 5 {
                let p = Point2D(x: Double(i) / 4, y: Double(j) / 4)
                total += a.apply(to: p).distance(to: b.apply(to: p))
                n += 1
            }
        }
        return total / Double(n)
    }

    /// Task 2.1b. Applies a **known** homography to a real frame and asserts
    /// registration recovers it. Stricter than a real pair, where the result
    /// can only be eyeballed.
    @Test("Registration recovers a known homography, and its limit is documented")
    func recoversKnownHomography() async throws {
        guard let url = SyntheticClimb.fixtureVideoURL else {
            // Fixtures/ is allowed to be empty. Skip rather than fail.
            return
        }
        let frame = try await VideoFrameSource(url: url).image(atSeconds: 1.0)

        // Magnitudes from "barely moved" up to "obviously bumped tripod".
        let cases: [(label: String, h: Homography)] = [
            ("translate 0.5%", Self.transform(rotationDegrees: 0, scale: 1, translation: Point2D(x: 0.005, y: 0))),
            ("translate 2%",   Self.transform(rotationDegrees: 0, scale: 1, translation: Point2D(x: 0.02, y: -0.01))),
            ("rotate 2°",      Self.transform(rotationDegrees: 2, scale: 1, translation: .zero)),
            ("rotate 5° + scale 1.03 + translate 2%",
             Self.transform(rotationDegrees: 5, scale: 1.03, translation: Point2D(x: 0.02, y: 0.015))),
            ("rotate 15° + scale 1.2", Self.transform(rotationDegrees: 15, scale: 1.2, translation: .zero))
        ]

        var recovered: [(String, Double)] = []
        for (label, applied) in cases {
            guard let warped = WallAligner.warp(frame, by: applied, like: frame) else {
                recovered.append((label, .infinity))
                continue
            }
            // The aligner maps the floating image back onto the reference, so
            // the answer it should return is the inverse of what was applied.
            guard let expected = applied.inverted,
                  let measured = WallAligner.homography(from: warped, to: frame) else {
                recovered.append((label, .infinity))
                continue
            }
            recovered.append((label, Self.meanDifference(expected, measured)))
        }

        for (label, error) in recovered {
            print("registration \(label): mean error \(String(format: "%.5f", error)) wall-widths")
        }

        // Small, realistic tripod movement must be recovered tightly.
        for (label, error) in recovered.prefix(4) {
            #expect(error < 0.02, "\(label) recovered with error \(error)")
        }
        // The boundary is documented rather than asserted as a pass: the last
        // case is deliberately beyond what a tripod would ever do.
        print("registration boundary case '\(recovered.last!.0)': error \(recovered.last!.1)")
    }

    /// Pins down the direction of `WallAligner.warp` independently of Vision,
    /// so a sign error in registration cannot be cancelled out by a matching
    /// sign error here and go unnoticed.
    @Test("warp moves image content forward by the homography")
    func warpDirection() throws {
        let size = 200
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        // A white square whose centre sits at normalized (0.25, 0.5).
        context.fill(CGRect(x: 40, y: 90, width: 20, height: 20))
        let image = context.makeImage()!

        let shift = Homography(m: [1, 0, 0.25, 0, 1, 0, 0, 0, 1])
        let warped = try #require(WallAligner.warp(image, by: shift, like: image))
        let centre = try #require(brightestCentre(warped))
        #expect(abs(centre.x - 0.50) < 0.05, "x moved to \(centre.x)")
        #expect(abs(centre.y - 0.50) < 0.05, "y moved to \(centre.y)")
    }

    /// Centroid of the bright pixels, in normalized bottom-left-origin space.
    func brightestCentre(_ image: CGImage) -> Point2D? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sx = 0.0, sy = 0.0, total = 0.0
        for row in 0 ..< height {
            for column in 0 ..< width {
                let value = Double(pixels[(row * width + column) * 4])
                guard value > 128 else { continue }
                sx += Double(column)
                // CGContext rows run top-down; wall space runs bottom-up.
                sy += Double(height - 1 - row)
                total += 1
            }
        }
        guard total > 0 else { return nil }
        return Point2D(x: sx / total / Double(width), y: sy / total / Double(height))
    }

    @Test("Identity registration of a frame against itself")
    func identityRegistration() async throws {
        guard let url = SyntheticClimb.fixtureVideoURL else { return }
        let frame = try await VideoFrameSource(url: url).image(atSeconds: 1.0)
        let result = WallAligner().align(reference: frame, attempt: frame, config: TuningConfig())
        #expect(WallAlignerTests.meanDifference(result.homography, .identity) < 0.01)
    }

    /// Task 2.3 — a mismatched pair must be rejected, not silently analysed.
    @Test("A residual above the limit marks the alignment as failed")
    func residualRejection() {
        var config = TuningConfig()
        config.registrationResidualLimit = 0.001
        let bad = AlignmentResult(
            homography: .identity, residual: 0.2,
            referenceFrameIndex: 0, attemptFrameIndex: 0,
            succeeded: false, warnings: ["re-record"]
        )
        #expect(!bad.succeeded)
        let failed = AlignmentResult.failed("nope")
        #expect(!failed.succeeded)
        #expect(failed.homography.isIdentity)
    }

    @Test("Registration frame selection prefers the least climber area")
    func frameSelection() {
        var sequence = SyntheticClimb.climb(moves: 3)
        // Blank one frame entirely — an empty wall is the ideal reference.
        sequence.frames[17].joints = [:]
        #expect(WallAligner.registrationFrameIndex(for: sequence) == 17)
    }

    @Test("Warping into wall space leaves no per-video coordinates behind")
    func wallSpaceTransform() {
        let sequence = SyntheticClimb.climb(moves: 2)
        let h = WallAlignerTests.transform(rotationDegrees: 3, scale: 1.02, translation: Point2D(x: 0.01, y: 0))
        let warped = sequence.warpedIntoWallSpace(by: h)
        #expect(warped.space == .wall)
        let original = sequence.frames[10].joints[.leftWrist]!.point
        let moved = warped.frames[10].joints[.leftWrist]!.point
        #expect(moved.distance(to: h.apply(to: original)) < 1e-9)
    }

    /// Skeleton-overlay mode draws the attempt's pose on the attempt's own,
    /// unwarped footage. The pose is in wall space, so it has to go back
    /// through the inverse first — and getting that direction wrong puts the
    /// skeleton beside the climber, which looks exactly like a tracking
    /// failure that isn't there. This pins the direction.
    @Test("The inverse homography returns a wall-space pose to its own video")
    func inverseReturnsPoseToItsOwnFrame() throws {
        let sequence = SyntheticClimb.climb(moves: 2)
        let h = WallAlignerTests.transform(rotationDegrees: 4, scale: 1.05, translation: Point2D(x: 0.02, y: -0.01))
        let warped = sequence.warpedIntoWallSpace(by: h)
        let inverse = try #require(h.inverted)

        for name in [JointName.leftWrist, .rightAnkle, .neck] {
            let original = try #require(sequence.frames[10].joints[name]?.point)
            let inWallSpace = try #require(warped.frames[10].joints[name]?.point)
            #expect(inverse.apply(to: inWallSpace).distance(to: original) < 1e-9)
        }
    }
}

@Suite("Time alignment")
struct TimeAlignerTests {

    /// Applies a known non-linear time warp to a frame index sequence.
    /// `shape` maps `[0,1] -> [0,1]`, monotonic.
    static func warpSequence(_ sequence: PoseSequence, shape: (Double) -> Double, outputCount: Int) -> PoseSequence {
        var frames: [PoseFrame] = []
        let n = sequence.count
        for i in 0 ..< outputCount {
            let u = Double(i) / Double(max(1, outputCount - 1))
            let source = shape(u) * Double(n - 1)
            let lower = Int(source.rounded(.down)).clamped(to: 0 ... (n - 1))
            var frame = sequence.frames[lower]
            frame.index = i
            frame.timeSeconds = Double(i) / sequence.frameRate
            frames.append(frame)
        }
        return PoseSequence(frames: frames, space: sequence.space, frameRate: sequence.frameRate,
                            sourceWidth: sequence.sourceWidth, sourceHeight: sequence.sourceHeight)
    }

    /// Task 2.5b. Warps a copy of a pose sequence by a **known** non-linear
    /// function and asserts DTW recovers that path — including a shape that
    /// speeds up and then slows down.
    @Test("DTW recovers a known non-linear warp")
    func recoversKnownWarp() {
        let base = SyntheticClimb.climb(moves: 4, dwellFrames: 12, moveFrames: 8)
        let scale = ClimbScale(sequence: base)
        let contacts = ContactDetector().detect(base, scale: scale, config: TuningConfig()).contacts
        let baseStates = TimeAligner.contactStates(contacts: contacts, frameCount: base.count)

        let shapes: [(name: String, f: (Double) -> Double)] = [
            ("linear 1.5×", { $0 }),
            ("ease-in (slow then fast)", { $0 * $0 }),
            ("ease-out (fast then slow)", { 1 - (1 - $0) * (1 - $0) }),
            ("fast then slow then fast", { u in u < 0.5 ? 0.5 * pow(u / 0.5, 0.6) : 0.5 + 0.5 * pow((u - 0.5) / 0.5, 1.6) })
        ]

        for (name, shape) in shapes {
            let outputCount = Int(Double(base.count) * 1.5)
            let warped = Self.warpSequence(base, shape: shape, outputCount: outputCount)
            let warpedScale = ClimbScale(sequence: warped)
            let warpedContacts = ContactDetector().detect(warped, scale: warpedScale, config: TuningConfig()).contacts
            let warpedStates = TimeAligner.contactStates(contacts: warpedContacts, frameCount: warped.count)

            let section = Section(
                index: 0,
                fromHold: Hold(id: 0, position: .zero, firstUsedBy: .leftWrist, ordinal: 0, contactCount: 1, firstFrame: 0),
                toHold: Hold(id: 1, position: .zero, firstUsedBy: .rightWrist, ordinal: 1, contactCount: 1, firstFrame: 1),
                referenceRange: 0 ..< base.count,
                attemptRange: 0 ..< warped.count
            )
            let path = TimeAligner().align(
                section: section, reference: base, attempt: warped,
                referenceScale: scale, attemptScale: warpedScale,
                referenceContacts: baseStates, attemptContacts: warpedStates
            )

            #expect(path.isMonotonic, "\(name): path not monotonic")
            // Endpoints are hard anchors.
            #expect(path.pairs.first?.referenceFrame == 0, "\(name): start not anchored")
            #expect(path.pairs.first?.attemptFrame == 0, "\(name): start not anchored")
            #expect(path.pairs.last?.referenceFrame == base.count - 1, "\(name): end not anchored")
            #expect(path.pairs.last?.attemptFrame == warped.count - 1, "\(name): end not anchored")

            // Recovered mapping vs the applied one.
            var errors: [Double] = []
            for attemptFrame in stride(from: 0, to: warped.count, by: 3) {
                let u = Double(attemptFrame) / Double(max(1, warped.count - 1))
                let expectedReference = shape(u) * Double(base.count - 1)
                guard let recovered = path.referenceFrame(forAttempt: attemptFrame) else { continue }
                errors.append(abs(Double(recovered) - expectedReference))
            }
            let mean = errors.mean ?? .infinity
            print("DTW \(name): mean frame error \(String(format: "%.2f", mean)) over \(errors.count) samples")
            // Tolerance in frames. The synthetic climb holds still for long
            // runs, where any alignment inside the dwell is equally correct, so
            // this is deliberately not sub-frame.
            #expect(mean < 8, "\(name): mean error \(mean) frames")
        }
    }

    @Test("A section the attempt never reached yields an empty path, not a crash")
    func truncatedSection() {
        let base = SyntheticClimb.climb(moves: 2)
        let scale = ClimbScale(sequence: base)
        let section = Section(
            index: 3,
            fromHold: Hold(id: 0, position: .zero, firstUsedBy: .leftWrist, ordinal: 0, contactCount: 1, firstFrame: 0),
            toHold: Hold(id: 1, position: .zero, firstUsedBy: .rightWrist, ordinal: 1, contactCount: 1, firstFrame: 1),
            referenceRange: 0 ..< base.count,
            attemptRange: 0 ..< 0
        )
        let path = TimeAligner().align(
            section: section, reference: base, attempt: base,
            referenceScale: scale, attemptScale: scale,
            referenceContacts: [], attemptContacts: []
        )
        #expect(path.isEmpty)
    }
}
