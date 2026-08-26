import CoreGraphics

/// Deterministic viewport bounds shared by the Results interaction and its
/// stress tests. Keeping this outside SwiftUI makes every edge case testable
/// without manufacturing touch events or a video asset.
public enum ViewportTransformMath {
    public static func clampedOffset(
        _ offset: CGSize,
        zoom: CGFloat,
        minimumZoom: CGFloat = 1,
        viewportSize: CGSize
    ) -> CGSize {
        guard zoom > minimumZoom else { return .zero }
        let maximumX = max(0, viewportSize.width) * (zoom - 1) / 2
        let maximumY = max(0, viewportSize.height) * (zoom - 1) / 2
        return CGSize(
            width: offset.width.clamped(to: -maximumX ... maximumX),
            height: offset.height.clamped(to: -maximumY ... maximumY)
        )
    }

    public static func rubberBandedOffset(
        _ offset: CGSize,
        zoom: CGFloat,
        minimumZoom: CGFloat = 1,
        viewportSize: CGSize
    ) -> CGSize {
        guard zoom > minimumZoom else { return .zero }
        let width = max(0, viewportSize.width)
        let height = max(0, viewportSize.height)
        let maximumX = width * (zoom - 1) / 2
        let maximumY = height * (zoom - 1) / 2
        return CGSize(
            width: rubberBandedAxis(
                offset.width,
                limit: maximumX,
                viewportLength: width
            ),
            height: rubberBandedAxis(
                offset.height,
                limit: maximumY,
                viewportLength: height
            )
        )
    }

    private static func rubberBandedAxis(
        _ value: CGFloat,
        limit: CGFloat,
        viewportLength: CGFloat
    ) -> CGFloat {
        guard abs(value) > limit else { return value }
        let excess = abs(value) - limit
        let dimension = max(1, viewportLength)
        let resistance = (1 - 1 / (excess * 0.55 / dimension + 1)) * dimension
        return value < 0 ? -(limit + resistance) : limit + resistance
    }
}
