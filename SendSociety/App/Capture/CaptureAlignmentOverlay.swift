#if os(iOS)
import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Chooses a visual camera-alignment target from the clip recorded first.
/// This is intentionally a single real frame rather than the processed wall
/// plate: the second capture happens before the comparison pipeline (and its
/// pose cache) has run.
enum CaptureAlignmentOverlay {
    /// Samples the whole clip and returns the frame with the least detected
    /// person area. An empty-wall frame wins; when every sample contains the
    /// climber, the least-obstructed one wins.
    nonisolated static func clearestWallFrame(url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration >= 0 else { return nil }

        let sampleCount = duration < 1 ? 4 : 20
        let lastSecond = max(0, duration - 1.0 / 60.0)
        let seconds = (0 ..< sampleCount).map { index in
            lastSecond * Double(index) / Double(max(1, sampleCount - 1))
        }
        let frames = await VideoFrameSource.images(
            url: url,
            seconds: seconds,
            maximumSize: CGSize(width: 1280, height: 1280)
        )

        var best: (obstruction: Double, image: CGImage)?
        for second in seconds {
            guard let image = frames[second] else { continue }
            let obstruction = personArea(in: image)
            if best == nil || obstruction < best!.obstruction {
                best = (obstruction, image)
            }
            // Nothing can beat a frame where Vision sees no person.
            if obstruction == 0 { break }
        }
        return best?.image
    }

    /// Normalized bounding-box area of the strongest person observation.
    /// A tiny non-zero floor prevents a partial observation from tying a
    /// genuinely empty frame.
    nonisolated private static func personArea(in image: CGImage) -> Double {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = (request.results ?? [])
                .max(by: { $0.confidence < $1.confidence }),
              let recognized = try? observation.recognizedPoints(.all)
        else { return 0 }

        let points = recognized.values
            .filter { $0.confidence >= 0.15 }
            .map(\.location)
        guard !points.isEmpty else { return 0 }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let area = Double((xs.max()! - xs.min()!) * (ys.max()! - ys.min()!))
        return max(0.000_001, area)
    }
}
#endif
