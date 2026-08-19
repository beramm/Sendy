import Testing
import CoreGraphics
import Foundation
@testable import VideoOverlapCore

/// Ground-truth tests for the clean plate.
///
/// The pattern is the one the project prefers over real-pair fixtures: build a
/// synthetic case whose correct answer is known exactly, rather than a real one
/// judged by eye. A known wall image, a known blob composited over it, and the
/// assertion that the blob comes back out.
struct WallPlateTests {

    // MARK: Fixtures

    /// A wall with structure in it — a gradient plus blocks standing in for
    /// holds — so a plate that is merely "some colour" cannot pass.
    static func wall(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x * 200 / max(1, width - 1))
                pixels[i + 1] = UInt8(y * 200 / max(1, height - 1))
                pixels[i + 2] = ((x / 7) % 2 == 0 && (y / 5) % 2 == 0) ? 240 : 30
                pixels[i + 3] = 255
            }
        }
        return pixels
    }

    static func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Paints an opaque magenta blob over the wall and returns both the frame
    /// and the blob's bounds in **pose coordinates** — normalized, y-up.
    static func sample(width: Int, height: Int, blobColumn: Int, blobWidth: Int) -> WallPlateBuilder.Sample {
        var pixels = wall(width: width, height: height)
        let x0 = max(0, blobColumn), x1 = min(width, blobColumn + blobWidth)
        // A vertical band: it spans the full height, which is the hard case —
        // no row of the image is ever free of the climber.
        for y in 0 ..< height {
            for x in x0 ..< x1 {
                let i = (y * width + x) * 4
                pixels[i] = 255; pixels[i + 1] = 0; pixels[i + 2] = 255; pixels[i + 3] = 255
            }
        }
        let rect = CGRect(
            x: Double(x0) / Double(width), y: 0,
            width: Double(x1 - x0) / Double(width), height: 1
        )
        return WallPlateBuilder.Sample(image: image(pixels, width: width, height: height), mask: rect)
    }

    static func pixels(of image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buffer
    }

    /// Mean absolute per-channel error against the clean wall.
    static func error(_ plate: CGImage, width: Int, height: Int) -> Double {
        let got = pixels(of: plate)
        let want = wall(width: width, height: height)
        var total = 0.0
        var n = 0
        for i in stride(from: 0, to: got.count, by: 4) {
            for c in 0 ..< 3 {
                total += abs(Double(got[i + c]) - Double(want[i + c]))
                n += 1
            }
        }
        return total / Double(n)
    }

    /// Worst-case magenta contamination — the blob leaking into the plate.
    static func magentaPixels(_ plate: CGImage) -> Int {
        let got = pixels(of: plate)
        var count = 0
        for i in stride(from: 0, to: got.count, by: 4) where got[i] > 200 && got[i + 1] < 60 && got[i + 2] > 200 {
            count += 1
        }
        return count
    }

    // MARK: Tests

    @Test("A moving climber is removed and the wall comes back")
    func recoversWall() {
        let w = 96, h = 64
        let samples = (0 ..< 8).map { i in
            Self.sample(width: w, height: h, blobColumn: i * 12, blobWidth: 12)
        }
        let result = WallPlateBuilder.composite(samples: samples, maxDimension: max(w, h))
        let plate = try! #require(result)

        #expect(plate.coverage == 1.0)
        #expect(Self.magentaPixels(plate.image) == 0)
        #expect(Self.error(plate.image, width: w, height: h) < 2.0)
    }

    /// The case a plain temporal median gets wrong. The climber sits in one
    /// place for six of eight samples, so at those pixels the *majority* of
    /// samples are the climber and an unmasked median returns the climber.
    @Test("A climber occupying the majority of samples is still removed")
    func removesLingeringClimber() {
        let w = 96, h = 64
        var samples = (0 ..< 6).map { _ in
            Self.sample(width: w, height: h, blobColumn: 40, blobWidth: 12)
        }
        samples.append(Self.sample(width: w, height: h, blobColumn: 0, blobWidth: 12))
        samples.append(Self.sample(width: w, height: h, blobColumn: 80, blobWidth: 12))

        let masked = try! #require(WallPlateBuilder.composite(samples: samples, maxDimension: max(w, h)))
        #expect(masked.coverage == 1.0)
        #expect(Self.magentaPixels(masked.image) == 0)
        #expect(Self.error(masked.image, width: w, height: h) < 2.0)

        // And the same samples with the masks removed — the plain median this
        // stage exists to beat — must fail, or the test above proves nothing.
        let unmasked = try! #require(WallPlateBuilder.composite(
            samples: samples.map { WallPlateBuilder.Sample(image: $0.image, mask: nil) },
            maxDimension: max(w, h)
        ))
        #expect(Self.magentaPixels(unmasked.image) > 0)
    }

    @Test("A climber who never moves is reported, not hidden")
    func reportsUncoveredPixels() {
        let w = 96, h = 64
        let samples = (0 ..< 8).map { _ in
            Self.sample(width: w, height: h, blobColumn: 40, blobWidth: 12)
        }
        let plate = try! #require(WallPlateBuilder.composite(samples: samples, maxDimension: max(w, h)))

        // 12 of 96 columns are never exposed.
        #expect(abs(plate.coverage - (1.0 - 12.0 / 96.0)) < 0.02)
        // It ghosts there rather than punching a hole — degraded, never blank.
        #expect(Self.magentaPixels(plate.image) > 0)
    }

    @Test("Pose rects flip into buffer rows")
    func maskFlipsVertically() {
        // A rect hugging the pose-space bottom must land on the buffer's last
        // rows, because a CGContext buffer starts at the top of the image.
        let low = try! #require(WallPlateBuilder.bufferRect(
            CGRect(x: 0, y: 0, width: 1, height: 0.25), width: 100, height: 100
        ))
        #expect(low.y0 == 75)
        #expect(low.y1 == 100)

        let high = try! #require(WallPlateBuilder.bufferRect(
            CGRect(x: 0, y: 0.75, width: 1, height: 0.25), width: 100, height: 100
        ))
        #expect(high.y0 == 0)
        #expect(high.y1 == 25)

        #expect(WallPlateBuilder.bufferRect(nil, width: 100, height: 100) == nil)
        #expect(WallPlateBuilder.bufferRect(.zero, width: 100, height: 100) == nil)
    }

    @Test("One sample is not a median")
    func rejectsTooFewSamples() {
        let one = [Self.sample(width: 32, height: 32, blobColumn: 0, blobWidth: 4)]
        #expect(WallPlateBuilder.composite(samples: one, maxDimension: 32) == nil)
        #expect(WallPlateBuilder.composite(samples: [], maxDimension: 32) == nil)
    }
}
