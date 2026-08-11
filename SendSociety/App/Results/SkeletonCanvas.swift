import SwiftUI

/// Which analytical overlays are drawn on top of the skeletons.
///
/// These are illegible over real footage and obvious on a stick figure, which
/// is why skeleton-only mode exists. **The fall analysis is only properly
/// viewable here** — the story is "the COM exits the base of support and does
/// not return", and that cannot be rendered over video.
struct AnalyticalOverlays: Equatable {
    var centreOfMass = true
    var baseOfSupport = true
    var limbLoad = true
    var divergenceVectors = false
    var holds = true

    static let none = AnalyticalOverlays(
        centreOfMass: false, baseOfSupport: false, limbLoad: false,
        divergenceVectors: false, holds: false
    )
}

let skeletonBones: [(JointName, JointName)] = [
    (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
    (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
    (.leftShoulder, .leftHip), (.rightShoulder, .rightHip), (.leftHip, .rightHip),
    (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
    (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    (.neck, .nose)
]

/// Draws one or both skeletons on a plain wall diagram.
///
/// Renders from pose and route data alone — no video decode — so it works with
/// the video files absent and scrubbing is instant.
struct SkeletonCanvas: View {
    var referenceFrame: PoseFrame?
    var attemptFrame: PoseFrame?
    var referenceMetrics: FrameMetrics?
    var attemptMetrics: FrameMetrics?
    var referenceScale: ClimbScale?
    var attemptScale: ClimbScale?
    var route: Route?
    var overlays = AnalyticalOverlays()
    /// Draws both climbers at identical body-length scale. Only this mode can:
    /// a video cannot be rescaled without distorting it, a skeleton can. It
    /// makes the comparison about shape rather than size.
    var normalizeBodyLength = true

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(.gray.opacity(0.12)))

            if overlays.holds, let route {
                for hold in route.holds {
                    let p = point(hold.position, in: size)
                    let r: CGFloat = hold.isHandHold ? 9 : 6
                    context.stroke(
                        Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                        with: .color(hold.isHandHold ? .blue : .teal),
                        lineWidth: hold.isManual ? 3 : 1.5
                    )
                    context.draw(
                        Text("\(hold.ordinal + 1)").font(.system(size: 9)).foregroundStyle(.secondary),
                        at: CGPoint(x: p.x + r + 6, y: p.y)
                    )
                }
            }

            // A frame with no torso has nothing to anchor or scale a skeleton
            // to. Drawing one anyway produces a scribble that reads as a
            // tracking failure in the *tracker* rather than in this frame.
            if let referenceFrame, referenceFrame.hipCenter != nil, referenceFrame.shoulderCenter != nil {
                draw(
                    frame: referenceFrame, metrics: referenceMetrics, scale: referenceScale,
                    colour: .green, in: &context, size: size, label: "reference"
                )
            }
            if let attemptFrame, attemptFrame.hipCenter != nil, attemptFrame.shoulderCenter != nil {
                draw(
                    frame: attemptFrame, metrics: attemptMetrics, scale: attemptScale,
                    colour: .orange, in: &context, size: size, label: "attempt"
                )
            }

            let referenceTracked = referenceFrame?.hipCenter != nil
            let attemptTracked = attemptFrame?.hipCenter != nil
            if !referenceTracked || !attemptTracked {
                let who = !referenceTracked && !attemptTracked ? "Both climbers"
                    : (referenceTracked ? "The attempt" : "The reference climb")
                context.draw(
                    Text("\(who) lost tracking on this frame").font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: size.width / 2, y: 14)
                )
            }

            if overlays.divergenceVectors, let referenceFrame, let attemptFrame {
                for name in JointName.extremities + [.leftHip, .rightHip] {
                    guard let a = normalized(referenceFrame, name, scale: referenceScale),
                          let b = normalized(attemptFrame, name, scale: attemptScale) else { continue }
                    var path = Path()
                    path.move(to: point(a, in: size))
                    path.addLine(to: point(b, in: size))
                    context.stroke(path, with: .color(.red.opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
        }
        .background(Color(white: 0.96))
    }

    // MARK: Drawing

    private func draw(
        frame: PoseFrame,
        metrics: FrameMetrics?,
        scale: ClimbScale?,
        colour: Color,
        in context: inout GraphicsContext,
        size: CGSize,
        label: String
    ) {
        for (a, b) in skeletonBones {
            guard let pa = normalized(frame, a, scale: scale), let pb = normalized(frame, b, scale: scale) else { continue }
            var path = Path()
            path.move(to: point(pa, in: size))
            path.addLine(to: point(pb, in: size))

            var width: CGFloat = 2.5
            var strokeColour = colour
            if overlays.limbLoad, let metrics {
                // Per-limb load colouring: thicker and hotter means more of the
                // climber's weight is going through that limb.
                let load = limbLoad(metrics: metrics, a: a, b: b)
                if load > 0 {
                    width = 2.5 + CGFloat(load) * 10
                    strokeColour = colour.opacity(0.55 + load * 0.45)
                }
            }
            context.stroke(path, with: .color(strokeColour), lineWidth: width)
        }

        for name in JointName.extremities {
            guard let p = normalized(frame, name, scale: scale) else { continue }
            let onWall = metrics?.activeContacts.contains(name) ?? false
            let c = point(p, in: size)
            let r: CGFloat = onWall ? 6 : 4
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                with: .color(onWall ? colour : colour.opacity(0.35))
            )
        }

        guard let metrics else { return }

        if overlays.baseOfSupport, metrics.baseOfSupport.vertices.count >= 3 {
            var path = Path()
            let vertices = metrics.baseOfSupport.vertices.compactMap { normalized($0, frame: frame, scale: scale) }
            if let first = vertices.first {
                path.move(to: point(first, in: size))
                for v in vertices.dropFirst() { path.addLine(to: point(v, in: size)) }
                path.closeSubpath()
                context.fill(path, with: .color(colour.opacity(0.10)))
                context.stroke(path, with: .color(colour.opacity(0.7)), lineWidth: 1.5)
            }
        }

        if overlays.centreOfMass, let com = metrics.com, let p = normalized(com, frame: frame, scale: scale) {
            let c = point(p, in: size)
            // Filled when the COM is inside the base of support, hollow when it
            // is outside — the mechanical definition of falling.
            let inside = metrics.baseOfSupport.comInside
            let r: CGFloat = 7
            let ellipse = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            if inside {
                context.fill(ellipse, with: .color(colour))
            } else {
                context.stroke(ellipse, with: .color(.red), lineWidth: 3)
            }
        }
    }

    private func limbLoad(metrics: FrameMetrics, a: JointName, b: JointName) -> Double {
        for joint in [a, b] where JointName.extremities.contains(joint) {
            return metrics.load[joint]
        }
        return 0
    }

    /// Body-length normalization: both skeletons drawn about their own hip
    /// centre, scaled so one torso length is the same on screen for both.
    private func normalized(_ frame: PoseFrame, _ name: JointName, scale: ClimbScale?) -> Point2D? {
        guard let p = frame.joints[name]?.point else { return nil }
        return normalized(p, frame: frame, scale: scale)
    }

    private func normalized(_ p: Point2D, frame: PoseFrame, scale: ClimbScale?) -> Point2D? {
        guard normalizeBodyLength, let scale, let hip = frame.hipCenter else { return p }

        // The per-frame torso is a *divisor*, so a badly tracked frame where the
        // shoulders collapse toward the hips sends the scale factor to infinity
        // and flings every joint off the diagram. That produced skeletons that
        // looked like scribbles and read as a tracking failure when the tracking
        // was fine — the renderer was the failure.
        //
        // Two guards. Reject a per-frame torso that is implausible against the
        // climb's median, and clamp the resulting factor regardless.
        let median = scale.torsoLength
        let measured = frame.torsoLength
        let torso: Double
        if let measured, measured > median * 0.5, measured < median * 2.0 {
            torso = measured
        } else {
            torso = median
        }
        guard torso > 1e-6 else { return p }

        // Common on-screen body length, chosen so a climber fills a sensible
        // fraction of the diagram.
        let target = 0.10
        let factor = (target / torso).clamped(to: 0.25 ... 4.0)
        return Point2D(x: hip.x + (p.x - hip.x) * factor, y: hip.y + (p.y - hip.y) * factor)
    }

    /// Wall space is y-up; Canvas is y-down.
    private func point(_ p: Point2D, in size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
    }
}
