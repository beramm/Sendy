import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import SwiftUI

/// Pulls still frames out of a video for the comparison views.
///
/// The comparison modes render **stills at the current scrub position** rather
/// than running two synchronised players. There is no shared clock between the
/// clips, so stepping both through the DTW path keeps the displayed evidence
/// exact and makes skeleton overlays land on the corresponding frame.
///
/// **One instance per results screen, shared by every pane.** Switching modes
/// therefore retains decoded frames, and panes reading the same clip reuse the
/// same generator.
@MainActor
final class FrameImageCache {

    /// How closely a decode has to land on the requested time.
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
    enum Result {
        case image(CGImage)
        case busy
        case failed
    }

    /// Sized for the pane it lands in, not for the source clip.
    private static let maximumSize = CGSize(width: 640, height: 640)

    private struct Key: Hashable {
        var url: URL
        /// Requested time quantized to 1/60s.
        var sixtieths: Int
        var fidelity: Fidelity
    }

    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private let limit = 80

    /// One immutable generator per clip and fidelity.
    private var generators: [GeneratorKey: GeneratorBox] = [:]

    private struct GeneratorKey: Hashable {
        var url: URL
        var fidelity: Fidelity
    }

    /// `AVAssetImageGenerator` is not `Sendable`, but each generator is created
    /// here, never mutated afterwards, and only read through its concurrent
    /// async image API.
    private struct GeneratorBox: @unchecked Sendable {
        let generator: AVAssetImageGenerator
    }

    /// One in-flight decode per clip prevents scrubber ticks from building a
    /// backlog whose output trails behind the user's finger.
    private var busy: Set<URL> = []

    // MARK: Reads

    /// Synchronous lookup used before starting any cancellable task work.
    func cached(url: URL, seconds: Double, fidelity: Fidelity) -> CGImage? {
        let key = Key(url: url, sixtieths: Self.quantize(seconds), fidelity: fidelity)
        if let hit = images[key] {
            touch(key)
            return hit
        }
        // An exact frame satisfies a coarse request; the reverse is not true.
        guard fidelity == .coarse else { return nil }
        let exact = Key(url: url, sixtieths: Self.quantize(seconds), fidelity: .exact)
        if let hit = images[exact] {
            touch(exact)
            return hit
        }
        return nil
    }

    /// The nearest already-decoded frame at either fidelity.
    func anyCached(url: URL, seconds: Double) -> CGImage? {
        cached(url: url, seconds: seconds, fidelity: .coarse)
    }

    func image(url: URL, seconds: Double, fidelity: Fidelity) async -> Result {
        if let hit = cached(url: url, seconds: seconds, fidelity: fidelity) { return .image(hit) }
        guard !busy.contains(url) else { return .busy }

        busy.insert(url)
        let box = generator(for: url, fidelity: fidelity)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        // Unstructured on purpose: a scrubber tick may cancel its caller, but
        // allowing the decode to finish means the next tick can hit the cache.
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

/// The frame one pane is currently showing, shared by video and skeleton panes.
@MainActor
@Observable
final class VideoFrameLoader {
    /// The last successfully decoded frame. Failed or busy requests never clear
    /// it; only a genuinely absent clip/frame does.
    private(set) var image: CGImage?
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

        if let hit = cache.cached(url: url, seconds: timeSeconds, fidelity: fidelity) {
            image = hit
            decodeFailure = nil
            return
        }
        if let near = cache.anyCached(url: url, seconds: timeSeconds) { image = near }

        switch await cache.image(url: url, seconds: timeSeconds, fidelity: fidelity) {
        case .image(let decoded):
            image = decoded
            decodeFailure = nil
        case .busy:
            break
        case .failed:
            guard !Task.isCancelled else { return }
            decodeFailure = String(format: "frame %d (%.2fs) wouldn't decode", frameIndex, timeSeconds)
        }
    }
}

/// Task identity that also re-fires when a drag ends, upgrading its coarse
/// keyframe to the exact requested frame.
struct FrameRequest: Hashable {
    var url: URL?
    var frameIndex: Int?
    var scrubbing: Bool
}
