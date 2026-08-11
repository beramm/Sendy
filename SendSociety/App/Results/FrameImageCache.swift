import Foundation
import AVFoundation
import CoreGraphics
import SwiftUI

/// Pulls still frames out of a video for the comparison views.
///
/// The three comparison modes render **stills at the current scrub position**
/// rather than running two synchronised players. That follows from the design:
/// there is no shared timeline between the two clips, so "playing" them
/// together means stepping both along the DTW path anyway. Stills make that
/// exact, and make skeleton overlays land on the right frame.
actor FrameImageCache {
    private var images: [String: CGImage] = [:]
    private var order: [String] = []
    private let limit = 60

    func image(url: URL, seconds: Double) async -> CGImage? {
        let key = "\(url.lastPathComponent)@\(Int(seconds * 60))"
        if let cached = images[key] { return cached }

        guard let image = try? await VideoFrameSource.image(
            url: url, seconds: seconds, maximumSize: CGSize(width: 900, height: 900)
        ) else {
            return nil
        }
        images[key] = image
        order.append(key)
        if order.count > limit, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
        return image
    }
}
