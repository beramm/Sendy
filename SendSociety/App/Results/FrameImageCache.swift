import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import SwiftUI

/// Pulls still frames out of a video for the comparison views.
///
/// The three comparison modes render **stills at the current scrub position**
/// rather than running two synchronised players. That follows from the design:
/// there is no shared timeline between the two clips, so "playing" them
/// together means stepping both along the DTW path anyway. Stills make that
/// exact, and make skeleton overlays land on the right frame.
///
/// **One instance per results screen, shared by every pane.** It was one per
/// pane, which meant switching mode threw away every decoded frame and started
/// cold, and the two panes of a side-by-side never shared the generator for a
/// clip they both read from.
@MainActor
final class FrameImageCache {

    /// How closely a decode has to land on the requested time.
    ///
    /// This is the difference between a responsive scrubber and a frozen one.
    /// A tight tolerance forces the decoder to walk forward from the preceding
    /// keyframe — up to a whole GOP of frame decodes for one still — while a
    /// loose one returns the nearest keyframe outright. During a drag nobody
    /// can see which of two neighbouring frames they are looking at, so the
    /// drag gets keyframes and the position the finger stops on gets the frame
    /// it actually asked for.
    enum Fidelity: String, Hashable {
        /// Nearest keyframe. What a drag uses.
        case coarse
        /// The frame that was asked for. What a settled position uses.
        case exact

        var tolerance: CMTime {
            switch self {
            case .coarse: CMTime(value: 1, timescale: 6)
            case .exact: CMTime(value: 1, timescale: 60)
            }
        }
    }

    /// Why a request produced no image. `busy` is not a failure — a decode for
    /// this clip is already running and the pane should keep the frame it has.
    /// Reporting it as a failure is what made a fast drag print "wouldn't
    /// decode" over perfectly good footage.
    enum Result {
        case image(CGImage)
        case busy
        case failed
    }

    /// Sized for the pane it lands in, not for the source clip. A half-screen
    /// pane is ~600px wide on a 3x device; decoding 4K into it costs decode
    /// time and 3MB of cache per frame to throw both away at draw time.
    private static let maximumSize = CGSize(width: 640, height: 640)

    private struct Key: Hashable {
        var url: URL
        /// Requested time quantized to 1/60s — finer than any frame boundary
        /// the scrubber can land on.
        var sixtieths: Int
        var fidelity: Fidelity
    }

    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private let limit = 80

    /// One generator per (clip, fidelity), built once and reused.
    ///
    /// It used to be one per *frame request*: every scrubber tick constructed
    /// an `AVURLAsset` and an `AVAssetImageGenerator`, so every tick re-read
    /// the clip's index and spun up a decoder before it could seek. Fidelity is
    /// part of the key rather than a property mutated per request, so a
    /// generator is immutable once built and two panes can drive it at once.
    private var generators: [GeneratorKey: GeneratorBox] = [:]

    private struct GeneratorKey: Hashable {
        var url: URL
        var fidelity: Fidelity
    }

    /// `AVAssetImageGenerator` is not `Sendable`. It is only ever built here,
    /// only ever read through `image(at:)` — which is itself safe to call
    /// concurrently — and never mutated after construction.
    private struct GeneratorBox: @unchecked Sendable {
        let generator: AVAssetImageGenerator
    }

    /// Clips with a decode in flight. One at a time per clip: a drag emits
    /// ticks far faster than any decoder can answer them, and queueing every
    /// one of them means the picture on screen lags the finger by the whole
    /// backlog.
    private var busy: Set<URL> = []

    // MARK: Reads

    /// Synchronous look-up, for the tick a frame is asked for.
    ///
    /// A pane calls this **before** it does anything asynchronous, so a frame
    /// that is already decoded appears on the same run loop pass as the
    /// scrubber moved on — no task, no await, nothing to cancel.
    func cached(url: URL, seconds: Double, fidelity: Fidelity) -> CGImage? {
        if let hit = images[Key(url: url, sixtieths: Self.quantize(seconds), fidelity: fidelity)] {
            touch(Key(url: url, sixtieths: Self.quantize(seconds), fidelity: fidelity))
            return hit
        }
        // An exact frame satisfies a coarse request; the reverse is not true,
        // or scrubbing back over a span would permanently downgrade it to
        // keyframes.
        guard fidelity == .coarse else { return nil }
        let exact = Key(url: url, sixtieths: Self.quantize(seconds), fidelity: .exact)
        if let hit = images[exact] {
            touch(exact)
            return hit
        }
        return nil
    }

    /// The nearest thing already in hand, at any fidelity — used to keep a
    /// picture on screen while the right one decodes.
    func anyCached(url: URL, seconds: Double) -> CGImage? {
        cached(url: url, seconds: seconds, fidelity: .coarse)
    }

    func image(url: URL, seconds: Double, fidelity: Fidelity) async -> Result {
        if let hit = cached(url: url, seconds: seconds, fidelity: fidelity) { return .image(hit) }
        guard !busy.contains(url) else { return .busy }

        busy.insert(url)
        let box = generator(for: url, fidelity: fidelity)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        // **Unstructured on purpose.** The pane's load runs under
        // `.task(id:)`, which cancels it on every scrubber tick, and a decode
        // abandoned at 90% is work thrown away — that is what made a continuous
        // drag never finish a single frame. This task is not cancelled with the
        // caller, so the frame lands in the cache and the next tick is a hit.
        let decoded = await Task { await Self.decode(box, at: time) }.value
        busy.remove(url)

        guard let decoded else { return .failed }
        store(decoded, for: Key(url: url, sixtieths: Self.quantize(seconds), fidelity: fidelity))
        return .image(decoded)
    }

    // MARK: Internals

    private nonisolated static func decode(_ box: GeneratorBox, at time: CMTime) async -> CGImage? {
        try? await box.generator.image(at: time).image
    }

    private static func quantize(_ seconds: Double) -> Int { Int(seconds * 60) }

    private func generator(for url: URL, fidelity: Fidelity) -> GeneratorBox {
        let key = GeneratorKey(url: url, fidelity: fidelity)
        if let existing = generators[key] { return existing }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = fidelity.tolerance
        generator.requestedTimeToleranceAfter = fidelity.tolerance
        generator.maximumSize = Self.maximumSize
        let box = GeneratorBox(generator: generator)
        generators[key] = box
        return box
    }

    private func store(_ image: CGImage, for key: Key) {
        if images[key] == nil { order.append(key) }
        images[key] = image
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
    }

    private func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }
}

/// The frame one pane is currently showing, and how it got there.
///
/// Both video-bearing panes — side-by-side and skeleton-overlay — load frames
/// identically, and did so through two copies of the same function. Every fix
/// to scrubbing responsiveness had to be written twice, and the copies had
/// already drifted.
@MainActor
@Observable
final class VideoFrameLoader {
    /// The last frame that decoded. **Never cleared by a failed or skipped
    /// decode** — only by a real absence, meaning no clip, no frame index or no
    /// pose frame.
    private(set) var image: CGImage?
    /// A decode that was attempted and failed, which is a different claim from
    /// a frame that does not exist. The last good frame stays underneath it.
    private(set) var decodeFailure: String?

    func load(
        url: URL?,
        frameIndex: Int?,
        timeSeconds: Double?,
        scrubbing: Bool,
        cache: FrameImageCache
    ) async {
        guard let frameIndex, let timeSeconds else {
            image = nil
            decodeFailure = nil
            return
        }
        guard let url else {
            decodeFailure = "the video file for this clip is missing from the session"
            return
        }

        let fidelity: FrameImageCache.Fidelity = scrubbing ? .coarse : .exact

        // Same-tick hit: no await, so nothing can cancel between the scrubber
        // moving and the picture changing.
        if let hit = cache.cached(url: url, seconds: timeSeconds, fidelity: fidelity) {
            image = hit
            decodeFailure = nil
            return
        }
        // Otherwise put the nearest thing already decoded up immediately, so
        // the pane moves with the finger even while the right frame is still
        // being read.
        if let near = cache.anyCached(url: url, seconds: timeSeconds) { image = near }

        switch await cache.image(url: url, seconds: timeSeconds, fidelity: fidelity) {
        case .image(let decoded):
            image = decoded
            decodeFailure = nil
        case .busy:
            // A decode for this clip is already running. Keep what is on
            // screen; the next tick picks up the result.
            break
        case .failed:
            guard !Task.isCancelled else { return }
            decodeFailure = String(format: "frame %d (%.2fs) wouldn't decode", frameIndex, timeSeconds)
        }
    }
}

/// What a pane is being asked to show. Used as a `.task(id:)` key so that
/// letting go of the scrubber re-fires the load and upgrades the keyframe the
/// drag settled on to the frame that was actually asked for.
struct FrameRequest: Hashable {
    var url: URL?
    var frameIndex: Int?
    var scrubbing: Bool
}
