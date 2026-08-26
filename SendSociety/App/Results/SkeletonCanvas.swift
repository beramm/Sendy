import SwiftUI

/// Which analytical overlays are drawn on top of shared skeleton surfaces.
///
/// These are illegible over real footage and obvious on a stick figure, which
/// is why skeleton-only mode exists. **The fall analysis is only properly
/// viewable here** — the story is "the COM exits the base of support and does
/// not return", and that cannot be rendered over video.
struct AnalyticalOverlays: Equatable {
    var centreOfMass = true
    var baseOfSupport = true
    var limbLoad = true
    /// Coach-readable pelvis geometry produced by `PostureEstimator`.
    var pelvisTriangle = true
    /// Vertical through the pelvis against the climber's torso line.
    var plumbLine = true
    /// Knee position relative to its ankle.
    var kneeLine = false
    var divergenceVectors = false
    /// Degree and offset text drawn onto the body. Diagnostic screens want it;
    /// Results does not — the numbers live in Detailed Analytics, and on
    /// footage they crowd the shape the overlay exists to show.
    var annotations = true
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
        pelvisTriangle: false, plumbLine: false, kneeLine: false,
        divergenceVectors: false, annotations: false, holds: false,
        wallBackdrop: false
    )

    /// What the Results comparison starts with: the body, the pelvis, and the
    /// centre of mass, and nothing else. Every other overlay is still one
    /// toggle away — this is a starting point, not a reduced feature set.
    ///
    /// The reads that come off first are the ones that need a second line to
    /// interpret: a plumb line and a base-of-support polygon are geometry about
    /// geometry, and over gym footage they read as clutter laid on the climber
    /// rather than as a measurement of them.
    ///
    /// Its opposite is ``live``, one menu item away.
    static let clean = AnalyticalOverlays(
        centreOfMass: true, baseOfSupport: false, limbLoad: false,
        pelvisTriangle: true, plumbLine: false, kneeLine: false,
        divergenceVectors: false, annotations: false, holds: false,
        wallBackdrop: true
    )

    /// This set with the hold circles off, for the wall-plate overlay: the
    /// wall is already in the picture, and circles drawn over real holds are
    /// noise.
    ///
    /// Both of these copy the receiver and change what differs, rather than
    /// listing every field. A field-by-field copy silently keeps the default
    /// for anything added later — which is exactly how Overlay ended up
    /// printing tilt and turn figures with Live Analytics switched off.
    var withoutHolds: AnalyticalOverlays {
        var copy = self
        copy.holds = false
        return copy
    }

    /// This set as drawn straight onto video: no holds, no wall diagram, and no
    /// divergence vectors, all of which belong to the synthetic wall view.
    var overFootage: AnalyticalOverlays {
        var copy = self
        copy.holds = false
        copy.wallBackdrop = false
        copy.divergenceVectors = false
        return copy
    }

    /// Everything the frame was measured for, drawn on the body: base of
    /// support, per-limb load, the plumb line, knee over toe, and the figures
    /// beside each of them.
    static let live = AnalyticalOverlays(
        centreOfMass: true, baseOfSupport: true, limbLoad: true,
        pelvisTriangle: true, plumbLine: true, kneeLine: true,
        divergenceVectors: false, annotations: true, holds: false,
        wallBackdrop: true
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
    /// Stable identity colors used everywhere in Results: REF is green and
    /// YOU is blue.
    var referenceColour: Color = ResultsStyle.reference
    var attemptColour: Color = ResultsStyle.attempt
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
            let canvasRect = CGRect(origin: .zero, size: size)
            let contentRect = aspectFittedRect(in: size)
            if drawsBackground {
                context.fill(Path(canvasRect), with: .color(.gray.opacity(0.12)))
            }
            // The wall, route and skeletons all use the same aspect-fitted
            // rectangle. Filling the card would preserve normalized coordinates
            // but distort their physical x/y scale whenever the card and source
            // video have different aspect ratios.
            if let wallPlate, overlays.wallBackdrop {
                context.draw(Image(decorative: wallPlate, scale: 1), in: contentRect)
                context.fill(
                    Path(contentRect),
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
                    colour: soloColour ?? referenceColour, in: &context, size: size, label: "reference"
                )
            }
            if let attemptFrame, attemptFrame.hipCenter != nil, attemptFrame.shoulderCenter != nil {
                draw(
                    frame: attemptFrame, metrics: attemptMetrics, scale: attemptScale,
                    colour: attemptColour, in: &context, size: size, label: "attempt"
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
        // **Line weight follows the climber, not the canvas.** A constant width
        // is only ever right at one distance from the wall: on a frame that
        // holds the whole route the body is small, and a 7pt limb swells until
        // the torso quad's own strokes meet and swallow the shape they are
        // drawing. Measuring the torso first keeps the skeleton reading the
        // same whether the climber fills the pane or crosses it.
        let torsoPixels: CGFloat = {
            guard let shoulder = frame.shoulderCenter, let hip = frame.hipCenter,
                  let s = normalized(shoulder, frame: frame, scale: scale),
                  let h = normalized(hip, frame: frame, scale: scale) else { return 0 }
            let a = point(s, in: size), b = point(h, in: size)
            return hypot(a.x - b.x, a.y - b.y)
        }()
        let boneWidth = min(max(torsoPixels * 0.085, 1.5), 9)

        for (a, b) in skeletonBones {
            guard let pa = normalized(frame, a, scale: scale), let pb = normalized(frame, b, scale: scale) else { continue }
            var path = Path()
            path.move(to: point(pa, in: size))
            path.addLine(to: point(pb, in: size))

            var width = boneWidth
            var strokeColour = colour
            if overlays.limbLoad, let metrics {
                // Per-limb load colouring: thicker and hotter means more of the
                // climber's weight is going through that limb. Off by default,
                // because a uniform limb is what makes the pose readable.
                let load = limbLoad(metrics: metrics, a: a, b: b)
                if load > 0 {
                    width = boneWidth * (1 + CGFloat(load))
                    strokeColour = colour.opacity(0.55 + load * 0.45)
                }
            }
            context.stroke(
                path,
                with: .color(strokeColour),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            )
        }

        for name in JointName.extremities {
            guard let p = normalized(frame, name, scale: scale),
                  metrics?.activeContacts.contains(name) == true else { continue }
            let c = point(p, in: size)
            let r = boneWidth * 0.8
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                with: .color(colour)
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

        drawPosture(
            frame: frame, metrics: metrics, scale: scale, colour: colour,
            in: &context, size: size, boneWidth: boneWidth
        )

        if overlays.centreOfMass, let com = metrics.com, let p = normalized(com, frame: frame, scale: scale) {
            let c = point(p, in: size)
            // Sized off the same body measure as the limbs, so the disc reads
            // as part of the skeleton rather than a sticker laid on top.
            let r = min(max(boneWidth * 1.25, 4), 12)
            let ellipse = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            // The word always appears, and always directly above the disc — a
            // coloured dot on a spray wall is indistinguishable from a hold
            // without it, and a fixed side keeps it findable rather than making
            // the reader hunt for wherever it fitted this frame. Above rather
            // than inside because the disc is sized to the climber and is
            // routinely too small to hold three letters.
            let labelText = Text("CoM").font(.system(size: max(9, r * 0.9), weight: .bold))

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
            if !overlays.baseOfSupport {
                context.fill(ellipse, with: .color(colour))
                drawComLabel(labelText, at: c, radius: r, colour: colour, in: &context)
            } else if metrics.baseOfSupport.isDegenerate {
                // White, over a dark halo. The first version used `.secondary`,
                // which is a grey chosen to recede against a UI background —
                // over gym footage of a pale wall it disappeared entirely. The
                // halo is what keeps it readable on light *and* dark footage,
                // since this one is drawn over video, not over a diagram.
                context.fill(ellipse, with: .color(.black.opacity(0.55)))
                context.stroke(
                    ellipse,
                    with: .color(.white),
                    style: StrokeStyle(lineWidth: 2.5, dash: [3, 3])
                )
                drawComLabel(labelText, at: c, radius: r, colour: .white, in: &context)
            } else if metrics.baseOfSupport.comInside {
                context.fill(ellipse, with: .color(colour))
                drawComLabel(labelText, at: c, radius: r, colour: colour, in: &context)
            } else {
                context.fill(ellipse, with: .color(.red))
                drawComLabel(labelText, at: c, radius: r, colour: .red, in: &context)
            }
        }
    }

    /// Draws the centre-of-mass label immediately above its disc.
    ///
    /// It carries a dark outline because it lands on gym footage rather than on
    /// a filled disc — a pale wall and a green label are the same brightness,
    /// and without the outline the word disappears exactly where the picture is
    /// busiest.
    private func drawComLabel(
        _ text: Text,
        at centre: CGPoint,
        radius: CGFloat,
        colour: Color,
        in context: inout GraphicsContext
    ) {
        let anchor = CGPoint(x: centre.x, y: centre.y - radius - 3)
        for dx in [-1.0, 1.0] as [CGFloat] {
            for dy in [-1.0, 1.0] as [CGFloat] {
                context.draw(
                    text.foregroundStyle(.black),
                    at: CGPoint(x: anchor.x + dx, y: anchor.y + dy),
                    anchor: .bottom
                )
            }
        }
        context.draw(text.foregroundStyle(colour), at: anchor, anchor: .bottom)
    }

    /// The three reads a coach draws on the body itself: pelvis, plumb line,
    /// and knee. Every figure comes from `PostureFrame`; rendering measures
    /// nothing and only presents the pipeline output.
    private func drawPosture(
        frame: PoseFrame,
        metrics: FrameMetrics,
        scale: ClimbScale?,
        colour: Color,
        in context: inout GraphicsContext,
        size: CGSize,
        boneWidth: CGFloat
    ) {
        let posture = metrics.posture

        if overlays.pelvisTriangle, let pelvis = posture.pelvis,
           let left = normalized(pelvis.leftHip, frame: frame, scale: scale),
           let right = normalized(pelvis.rightHip, frame: frame, scale: scale),
           let pubis = normalized(pelvis.pubis, frame: frame, scale: scale) {
            let a = point(left, in: size), b = point(right, in: size), c = point(pubis, in: size)
            var triangle = Path()
            triangle.move(to: a)
            triangle.addLine(to: b)
            triangle.addLine(to: c)
            triangle.closeSubpath()
            context.stroke(
                triangle,
                with: .color(colour),
                style: StrokeStyle(lineWidth: boneWidth * 0.85, lineCap: .round, lineJoin: .round)
            )

            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if overlays.annotations {
                var apexLine = Path()
                apexLine.move(to: mid)
                apexLine.addLine(to: c)
                context.stroke(
                    apexLine,
                    with: .color(colour.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                )

                var label = String(format: "%.0f° tilt", abs(pelvis.tiltDegrees))
                if let turn = pelvis.turnDegrees, pelvis.turnConfidence >= 0.3 {
                    label += String(format: " · %.0f° turned", turn)
                }
                context.draw(
                    Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(colour),
                    at: CGPoint(x: max(a.x, b.x) + 4, y: mid.y - 10),
                    anchor: .leading
                )
            }
        }

        if overlays.plumbLine, let pelvis = posture.pelvis,
           let centre = normalized(pelvis.center, frame: frame, scale: scale) {
            let hip = point(centre, in: size)
            let contentHeight = aspectFittedRect(in: size).height
            var plumb = Path()
            plumb.move(to: CGPoint(x: hip.x, y: hip.y - contentHeight * 0.30))
            plumb.addLine(to: CGPoint(x: hip.x, y: hip.y + contentHeight * 0.12))
            context.stroke(
                plumb,
                with: .color(.white.opacity(0.75)),
                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
            )

            if let shoulder = frame.shoulderCenter,
               let shoulderPoint = normalized(shoulder, frame: frame, scale: scale) {
                var body = Path()
                body.move(to: hip)
                body.addLine(to: point(shoulderPoint, in: size))
                context.stroke(body, with: .color(.yellow), lineWidth: 2)
            }
            if overlays.annotations, let lean = posture.torsoLeanDegrees, abs(lean) >= 1 {
                context.draw(
                    Text(String(format: "%.0f° %@", abs(lean), lean > 0 ? "right" : "left"))
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.yellow),
                    at: CGPoint(x: hip.x + 6, y: hip.y - contentHeight * 0.16),
                    anchor: .leading
                )
            }
        }

        if overlays.kneeLine {
            for (knee, ankle, offset) in [
                (JointName.leftKnee, JointName.leftAnkle, posture.leftKneeOverAnkle),
                (JointName.rightKnee, JointName.rightAnkle, posture.rightKneeOverAnkle)
            ] {
                guard let offset,
                      let k = normalized(frame, knee, scale: scale),
                      let a = normalized(frame, ankle, scale: scale) else { continue }
                let kneePoint = point(k, in: size), anklePoint = point(a, in: size)
                var vertical = Path()
                vertical.move(to: anklePoint)
                vertical.addLine(to: CGPoint(x: anklePoint.x, y: kneePoint.y))
                context.stroke(
                    vertical,
                    with: .color(.teal.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
                var across = Path()
                across.move(to: CGPoint(x: anklePoint.x, y: kneePoint.y))
                across.addLine(to: kneePoint)
                context.stroke(across, with: .color(.teal), lineWidth: 2)
                if overlays.annotations {
                    context.draw(
                        Text(String(format: "%.2f", abs(offset)))
                            .font(.system(size: 8)).foregroundStyle(.teal),
                        at: CGPoint(x: kneePoint.x, y: kneePoint.y - 8)
                    )
                }
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
        let rect = aspectFittedRect(in: size)
        return CGPoint(
            x: rect.minX + q.x * rect.width,
            y: rect.minY + (1 - q.y) * rect.height
        )
    }

    /// Preserves the source video's pixel aspect inside an arbitrary result
    /// card. The wall plate is authoritative when present; otherwise the climb
    /// scale carries the source width/height ratio through `IsoMetric.xScale`.
    private func aspectFittedRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let sourceAspect: CGFloat
        if let wallPlate, wallPlate.width > 0, wallPlate.height > 0 {
            sourceAspect = CGFloat(wallPlate.width) / CGFloat(wallPlate.height)
        } else if let scale = referenceScale ?? attemptScale {
            sourceAspect = CGFloat(scale.iso.xScale)
        } else {
            return CGRect(origin: .zero, size: size)
        }
        guard sourceAspect > 0 else { return CGRect(origin: .zero, size: size) }

        let canvasAspect = size.width / size.height
        if sourceAspect > canvasAspect {
            let height = size.width / sourceAspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * sourceAspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
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
    /// Green for the reference, blue for the attempt — the same pairing as
    /// skeleton-only mode, so a colour means one climber across every view.
    let colour: Color
    /// `nil` for the reference, whose image space *is* wall space.
    let transform: Homography?
    let overlays: AnalyticalOverlays
    /// Keyframes during an active drag and exact frames after it settles.
    let scrubbing: Bool
    /// Shared by all panes in one Results screen.
    let cache: FrameImageCache
    /// The Results screen places compact REF/YOU badges inside the footage. Nil
    /// preserves the current diagnostic screen's caption-above presentation.
    var badgeLabel: String? = nil
    var badgeColor: Color = .white
    var unavailableReason: String = "not reached"
    /// Expanded Results owns the title and controls outside the footage.
    var showsPaneLabel = true
    /// Shared with the neighbouring pane by ResultsView.
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero

    @State private var frames = VideoFrameLoader()
    @State private var url: URL?

    private var frame: PoseFrame? { frameIndex.flatMap { pose.frame(at: $0) } }

    var body: some View {
        VStack(spacing: badgeLabel == nil ? 2 : 0) {
            if badgeLabel == nil, showsPaneLabel {
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                // The skeleton has to land in the same rectangle the video is
                // drawn in, not in the pane. An aspect-fit image letterboxes
                // inside its frame, so the fitted rect is computed rather than
                // assumed — otherwise every joint is offset by the letterbox.
                let fitted = fittedRect(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        if let image = frames.image {
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
                            overlays: overlays.overFootage,
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
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .compositingGroup()
                    .scaleEffect(max(1, zoomScale))
                    .offset(panOffset)

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
                    if let decodeFailure = frames.decodeFailure {
                        VStack {
                            Spacer()
                            Text(decodeFailure).font(.caption2).padding(4).background(.thinMaterial)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }

                    if showsPaneLabel, let badgeLabel {
                        Text(badgeLabel)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(badgeColor)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 34)
                            .background(ResultsStyle.badgeSurface, in: .capsule)
                            .padding(10)
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: badgeLabel == nil ? 0 : ResultsStyle.paneCornerRadius))
        .task(id: video?.id) {
            guard let video else { url = nil; return }
            url = await model.videoURL(video)
        }
        .task(id: FrameRequest(url: url, frameIndex: frameIndex, scrubbing: scrubbing)) {
            await frames.load(
                url: url,
                frameIndex: frameIndex,
                timeSeconds: frame?.timeSeconds,
                scrubbing: scrubbing,
                cache: cache
            )
        }
    }

    /// Where an aspect-fit image of this size actually lands inside the pane.
    private func fittedRect(in size: CGSize) -> CGRect {
        guard let image = frames.image,
              image.width > 0, image.height > 0,
              size.width > 0, size.height > 0 else {
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
}
