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
    /// The wall the route was derived from, behind the skeletons. Off gives
    /// back the plain diagram, which is easier to read and tells you nothing
    /// about whether a hold landed where a hold is.
    var wallBackdrop = true
    /// How far the backdrop is washed out before the skeletons go on top. A
    /// busy spray wall needs more of this than a plain one, and which it is
    /// only becomes clear on site — hence a control rather than a constant.
    var wallWash: Double = 0.45

    static let none = AnalyticalOverlays(
        centreOfMass: false, baseOfSupport: false, limbLoad: false,
        divergenceVectors: false, holds: false, wallBackdrop: false
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
    /// Off when the canvas is drawn over footage, where the video is the
    /// background and a wash over it hides the climber.
    var drawsBackground = true
    /// The wall with the climber removed, in this canvas's own coordinates —
    /// wall space is the reference clip's image space, so it needs no
    /// transform. Nil falls back to the plain diagram; it is a backdrop and no
    /// number on this canvas is derived from it.
    var wallPlate: CGImage?
    /// Overrides the colour of the climber in the `reference` slot.
    ///
    /// Skeleton-overlay mode draws one climber per pane and passes whichever
    /// climber that is through the reference slot, so without this the attempt
    /// came out green — the reference's colour — and the two panes were
    /// indistinguishable by colour in a view whose whole job is telling you
    /// which body the tracker is on.
    var soloColour: Color?
    /// Applied to every point before it reaches the canvas.
    ///
    /// Wall space **is** the reference video's image space, so the reference
    /// needs no transform. The attempt's pose was warped into wall space by
    /// `WallAligner`, so drawing it on the attempt's own unwarped footage needs
    /// the inverse — without it the skeleton sits beside the climber and reads
    /// as a tracking failure that isn't there.
    var transform: Homography?
    /// Off when this canvas shows one climber, so it doesn't report the other
    /// as having lost tracking when it was simply never asked for.
    var reportsTracking = true

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            if drawsBackground {
                context.fill(Path(rect), with: .color(.gray.opacity(0.12)))
            }
            // The plate is drawn in the same normalized frame as everything
            // else on this canvas, so it stretches to the full rect rather than
            // being letterboxed — a hold at (0.5, 0.5) must land on the wall
            // pixel at (0.5, 0.5), which is the entire point of showing it.
            if let wallPlate, overlays.wallBackdrop {
                context.draw(Image(decorative: wallPlate, scale: 1), in: rect)
                context.fill(
                    Path(rect),
                    with: .color(Color(.systemBackground).opacity(max(0, min(1, overlays.wallWash))))
                )
            }

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
                    colour: soloColour ?? .green, in: &context, size: size, label: "reference"
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
            if reportsTracking, !referenceTracked || !attemptTracked {
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
        // Two backgrounds, and the flag has to reach both. The canvas fill above
        // is the wall diagram's ground; this one is the view's. Skipping only
        // the first left an opaque card painted straight over the video, so
        // skeleton-overlay mode rendered as skeletons on nothing.
        .background(drawsBackground ? Color(.secondarySystemBackground) : Color.clear)
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
            let r: CGFloat = 7
            let ellipse = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))

            // **Three states, because "outside" and "no polygon" are different
            // claims.**
            //
            // `comInside` is false both when the COM has genuinely left the
            // base of support and when fewer than three contacts are loaded, so
            // there is no polygon to be inside of — a climber hanging off two
            // hands can only ever test as "outside". Drawing both as a red ring
            // made hanging look like falling, and made this dot claim something
            // `FallAnalyzer` explicitly refuses to claim: it skips degenerate
            // supports for exactly this reason.
            if metrics.baseOfSupport.isDegenerate {
                // White, over a dark halo. The first version used `.secondary`,
                // which is a grey chosen to recede against a UI background —
                // over gym footage of a pale wall it disappeared entirely. The
                // halo is what keeps it readable on light *and* dark footage,
                // since this one is drawn over video, not over a diagram.
                context.stroke(ellipse, with: .color(.black.opacity(0.45)), lineWidth: 5)
                context.stroke(
                    ellipse,
                    with: .color(.white),
                    style: StrokeStyle(lineWidth: 2.5, dash: [3, 3])
                )
            } else if metrics.baseOfSupport.comInside {
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
        let q = transform?.apply(to: p) ?? p
        return CGPoint(x: q.x * size.width, y: (1 - q.y) * size.height)
    }
}

/// One climber's skeleton drawn over their own footage.
///
/// **The tracking check.** Every number in this app comes from these joints, so
/// a metric that looks wrong is either a bad measurement or a bad pose, and no
/// other view separates those two: skeleton-only shows the pose without the
/// evidence, side-by-side shows the evidence without the pose.
///
/// No holds and no wall diagram — the video already shows the wall, and hold
/// circles drawn over real holds are noise.
struct SkeletonOverlayPane: View {
    @Environment(AppModel.self) private var model
    let title: String
    let video: VideoRef?
    let pose: PoseSequence
    let frameIndex: Int?
    let metrics: FrameMetrics?
    let scale: ClimbScale?
    /// Green for the reference, orange for the attempt — the same pairing as
    /// skeleton-only mode, so a colour means one climber across every view.
    let colour: Color
    /// `nil` for the reference, whose image space *is* wall space.
    let transform: Homography?
    let overlays: AnalyticalOverlays
    var unavailableReason: String = "not reached"

    @State private var image: CGImage?
    @State private var decodeFailure: String?
    @State private var cache = FrameImageCache()

    private var frame: PoseFrame? { frameIndex.flatMap { pose.frame(at: $0) } }

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            GeometryReader { geometry in
                // The skeleton has to land in the same rectangle the video is
                // drawn in, not in the pane. An aspect-fit image letterboxes
                // inside its frame, so the fitted rect is computed rather than
                // assumed — otherwise every joint is offset by the letterbox.
                let fitted = fittedRect(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        Rectangle().fill(Color(.secondarySystemFill))
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    SkeletonCanvas(
                        referenceFrame: frame,
                        referenceMetrics: metrics,
                        referenceScale: scale,
                        route: nil,
                        // Holds and the backdrop are forced off here whatever
                        // the toggles say: the wall is in the picture already.
                        overlays: AnalyticalOverlays(
                            centreOfMass: overlays.centreOfMass,
                            baseOfSupport: overlays.baseOfSupport,
                            limbLoad: overlays.limbLoad,
                            divergenceVectors: false,
                            holds: false,
                            wallBackdrop: false
                        ),
                        // A video cannot be rescaled without distorting it, so
                        // the skeleton is drawn where the joints actually are.
                        normalizeBodyLength: false,
                        drawsBackground: false,
                        soloColour: colour,
                        transform: transform,
                        reportsTracking: false
                    )
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)

                    if frameIndex == nil {
                        Text(unavailableReason)
                            .font(.caption)
                            .padding(4)
                            .background(.thinMaterial)
                    } else if frame?.hipCenter == nil {
                        Text("tracking lost on this frame")
                            .font(.caption2)
                            .padding(4)
                            .background(.thinMaterial)
                    }
                    if let decodeFailure {
                        VStack {
                            Spacer()
                            Text(decodeFailure).font(.caption2).padding(4).background(.thinMaterial)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
        }
        .task(id: frameIndex) { await load() }
    }

    /// Where an aspect-fit image of this size actually lands inside the pane.
    private func fittedRect(in size: CGSize) -> CGRect {
        guard let image, image.width > 0, image.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        let paneAspect = size.width / size.height
        if imageAspect > paneAspect {
            let height = size.width / imageAspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * imageAspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }

    /// Same rules as `ClimberPane`: a cancelled decode is not an absent frame,
    /// so the last good one stays on screen — and the decode is debounced, so
    /// a continuous drag doesn't cancel every attempt before one finishes and
    /// leave the video frozen under a skeleton that keeps moving.
    private func load() async {
        guard let video, let frame else {
            image = nil
            decodeFailure = nil
            return
        }
        if image != nil {
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
        }
        guard let url = await model.videoURL(video) else {
            decodeFailure = "the video file for this clip is missing from the session"
            return
        }
        if let decoded = await cache.image(url: url, seconds: frame.timeSeconds) {
            image = decoded
            decodeFailure = nil
        } else if !Task.isCancelled {
            decodeFailure = String(format: "frame %d (%.2fs) wouldn't decode", frameIndex ?? -1, frame.timeSeconds)
        }
    }
}
