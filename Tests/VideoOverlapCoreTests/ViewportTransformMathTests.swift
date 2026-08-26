import CoreGraphics
import Testing
@testable import VideoOverlapCore

@Suite("Results viewport transform")
struct ViewportTransformMathTests {
    @Test("Default zoom always returns the default centered position")
    func defaultZoomIsCentered() {
        for offset in [
            CGSize.zero,
            CGSize(width: 10, height: -10),
            CGSize(width: 10_000, height: -10_000)
        ] {
            #expect(ViewportTransformMath.clampedOffset(
                offset,
                zoom: 1,
                viewportSize: CGSize(width: 180, height: 320)
            ) == .zero)
            #expect(ViewportTransformMath.rubberBandedOffset(
                offset,
                zoom: 1,
                viewportSize: CGSize(width: 180, height: 320)
            ) == .zero)
        }
    }

    @Test("Offsets inside the valid video bounds are unchanged")
    func validOffsetsAreUnchanged() {
        let viewport = CGSize(width: 180, height: 320)
        let offset = CGSize(width: 80, height: -150)

        #expect(ViewportTransformMath.clampedOffset(
            offset,
            zoom: 2,
            viewportSize: viewport
        ) == offset)
        #expect(ViewportTransformMath.rubberBandedOffset(
            offset,
            zoom: 2,
            viewportSize: viewport
        ) == offset)
    }

    @Test("Elastic overscroll resists the drag and strict bounds settle at the edge")
    func overscrollIsElastic() {
        let viewport = CGSize(width: 180, height: 320)
        let attempted = CGSize(width: 400, height: -700)
        let elastic = ViewportTransformMath.rubberBandedOffset(
            attempted,
            zoom: 2,
            viewportSize: viewport
        )
        let settled = ViewportTransformMath.clampedOffset(
            elastic,
            zoom: 2,
            viewportSize: viewport
        )

        #expect(elastic.width > 90 && elastic.width < attempted.width)
        #expect(elastic.height < -160 && elastic.height > attempted.height)
        #expect(settled == CGSize(width: 90, height: -160))
    }

    @Test("Fifty thousand zoom and pan combinations remain finite and bounded")
    func stressTransforms() {
        var generator = SeededGenerator(state: 0x5EED_CAFE_F00D_BAAD)

        for _ in 0 ..< 50_000 {
            let viewport = CGSize(
                width: generator.value(in: 0 ... 500),
                height: generator.value(in: 0 ... 900)
            )
            let zoom = generator.value(in: 0.5 ... 6)
            let attempted = CGSize(
                width: generator.value(in: -10_000 ... 10_000),
                height: generator.value(in: -10_000 ... 10_000)
            )
            let clamped = ViewportTransformMath.clampedOffset(
                attempted,
                zoom: zoom,
                viewportSize: viewport
            )
            let elastic = ViewportTransformMath.rubberBandedOffset(
                attempted,
                zoom: zoom,
                viewportSize: viewport
            )

            #expect(clamped.width.isFinite && clamped.height.isFinite)
            #expect(elastic.width.isFinite && elastic.height.isFinite)

            if zoom <= 1 {
                #expect(clamped == .zero)
                #expect(elastic == .zero)
            } else {
                let maximumX = viewport.width * (zoom - 1) / 2
                let maximumY = viewport.height * (zoom - 1) / 2
                #expect(abs(clamped.width) <= maximumX)
                #expect(abs(clamped.height) <= maximumY)
                #expect(abs(elastic.width) <= abs(attempted.width))
                #expect(abs(elastic.height) <= abs(attempted.height))
            }
        }
    }
}

private struct SeededGenerator {
    var state: UInt64

    mutating func value(in range: ClosedRange<CGFloat>) -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let unit = CGFloat(Double(state >> 11) / Double(UInt64.max >> 11))
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}
