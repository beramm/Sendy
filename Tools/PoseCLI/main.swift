import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import VideoOverlapCore

// The Phase 0 pose harness (task 0.0d): decode frames, run pose, dump JSON,
// render skeletons. Exists so thresholds are tuned against real footage while
// each stage is written, instead of guessed and found wrong on a gym floor.

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

func arg(_ name: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func loadSequence(_ path: String) throws -> PoseSequence {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(PoseSequence.self, from: data)
}

func saveSequence(_ s: PoseSequence, to path: String) throws {
    let data = try JSONEncoder().encode(s)
    try data.write(to: URL(fileURLWithPath: path))
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

// MARK: - pose

func commandPose(_ args: [String]) async throws {
    guard let input = args.dropFirst().first else { throw CLIError("usage: posecli pose <video> --out poses.json") }
    let out = arg("out", args) ?? "poses.json"
    var config = TuningConfig()
    if let r = arg("rate", args), let v = Double(r) { config.workingFrameRate = v }

    let extractor = VisionPoseExtractor()
    let start = Date()
    let sequence = try await extractor.extract(url: URL(fileURLWithPath: input), config: config) { _ in }
    try saveSequence(sequence, to: out)
    let elapsed = Date().timeIntervalSince(start)

    print("frames:        \(sequence.count)")
    print("duration:      \(String(format: "%.2f", sequence.durationSeconds))s")
    print("frame rate:    \(sequence.frameRate)")
    print("source:        \(sequence.sourceWidth)x\(sequence.sourceHeight)")
    print("extraction:    \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", Double(sequence.count) / elapsed)) fps)")
    for w in sequence.warnings { print("warning:       \(w)") }
    print(qualityTable(sequence))
    print("wrote \(out)")
}

/// Task 0.4: fraction of frames where each joint clears confidence 0.5.
func qualityTable(_ s: PoseSequence) -> String {
    var lines = ["joint                 >0.5    >0.3   mean"]
    for name in JointName.allCases {
        let confs = s.frames.map { $0.joints[name]?.confidence ?? 0 }
        let above5 = Double(confs.filter { $0 > 0.5 }.count) / Double(max(1, confs.count))
        let above3 = Double(confs.filter { $0 > 0.3 }.count) / Double(max(1, confs.count))
        lines.append(pad(name.rawValue, 20) + String(format: " %5.1f%%  %5.1f%%  %.2f", above5 * 100, above3 * 100, confs.mean ?? 0))
    }
    return lines.joined(separator: "\n")
}

// MARK: - contacts

func configFrom(_ args: [String]) -> TuningConfig {
    var config = TuningConfig()
    if let v = arg("vthresh", args).flatMap(Double.init) { config.contactVelocityThreshold = v }
    if let v = arg("dwell", args).flatMap(Int.init) { config.contactDwellFrames = v }
    if let v = arg("eps", args).flatMap(Double.init) { config.holdClusterEpsilon = v }
    if let v = arg("merge", args).flatMap(Double.init) { config.contactMergeRadius = v }
    if let v = arg("mergegap", args).flatMap(Int.init) { config.contactMergeGapFrames = v }
    if let v = arg("conf", args).flatMap(Double.init) { config.contactConfidenceFloor = v }
    if let v = arg("extconf", args).flatMap(Double.init) { config.extremityConfidenceFloor = v }
    if let v = arg("gap", args).flatMap(Int.init) { config.maxInterpolatedGapFrames = v }
    return config
}

func commandContacts(_ args: [String]) throws {
    guard let input = args.dropFirst().first else { throw CLIError("usage: posecli contacts <poses.json>") }
    let config = configFrom(args)

    let raw = try loadSequence(input)
    let smoothed = PoseSmoother().process(raw, config: config)
    let scale = ClimbScale(sequence: smoothed)
    let result = ContactDetector().detect(smoothed, scale: scale, config: config)
    let route = RouteBuilder().build(contacts: result.contacts, scale: scale, config: config)

    print(String(format: "torso length: %.4f wall units (estimated: %@)", scale.torsoLength, scale.isEstimated ? "yes" : "no"))
    print("contacts: \(result.contacts.count)  holds: \(route.holds.count)  hand holds: \(route.handHolds.count)")
    for w in smoothed.warnings + result.warnings + route.warnings { print("warning: \(w)") }

    // Speed distribution — the number you actually need to pick a threshold.
    for joint in JointName.extremities {
        let speeds = (result.speeds[joint] ?? []).compactMap { $0 }
        guard !speeds.isEmpty else { print("\(joint.rawValue): no speed track"); continue }
        print(pad(joint.rawValue, 12) + String(format: " p10 %.4f  p25 %.4f  median %.4f  p75 %.4f  p90 %.4f  max %.3f",
                     speeds.percentile(0.10)!, speeds.percentile(0.25)!, speeds.median!,
                     speeds.percentile(0.75)!, speeds.percentile(0.90)!, speeds.max()!))
    }

    print("\njoint         start   end      x      y   conf")
    for c in result.contacts.sorted(by: { $0.startFrame < $1.startFrame }) {
        print(pad(c.joint.rawValue, 12) + String(format: " %5d %5d  %.3f  %.3f  %.2f",
                     c.startFrame, c.endFrame, c.position.x, c.position.y, c.confidence))
    }

    print("\nhold  by            x      y   contacts  firstFrame")
    for h in route.holds {
        print(String(format: "%4d  ", h.id) + pad(h.firstUsedBy.rawValue, 12)
              + String(format: " %.3f  %.3f  %8d  %10d", h.position.x, h.position.y, h.contactCount, h.firstFrame))
    }
}

// MARK: - sweep  (task 1.6, run headless)

func commandSweep(_ args: [String]) throws {
    guard let input = args.dropFirst().first else { throw CLIError("usage: posecli sweep <poses.json>") }
    let raw = try loadSequence(input)
    var base = configFrom(args)
    let smoothed = PoseSmoother().process(raw, config: base)
    let scale = ClimbScale(sequence: smoothed)

    let vs = [0.05, 0.10, 0.15, 0.20, 0.30, 0.40, 0.60, 0.80, 1.20]
    let ns = [3, 4, 6, 8, 12]
    print(String(format: "torso length %.4f wall units", scale.torsoLength))
    print("cell = contacts / holds / handHolds")
    print("v\\N   " + ns.map { String(format: "%15d", $0) }.joined())
    for v in vs {
        base.contactVelocityThreshold = v
        var row = String(format: "%.3f ", v)
        for n in ns {
            base.contactDwellFrames = n
            let r = ContactDetector().detect(smoothed, scale: scale, config: base)
            let route = RouteBuilder().build(contacts: r.contacts, scale: scale, config: base)
            row += String(format: "%6d/%3d/%3d ", r.contacts.count, route.holds.count, route.handHolds.count)
        }
        print(row)
    }
}

// MARK: - jitter (what is the noise floor on a joint that is not moving?)

/// Frame-to-frame movement of a joint *during a detected contact*, in pixels of
/// frame height. The limb is believed to be at rest, so whatever it moves here
/// is the noise floor — any real micro-movement has to clear it.
func jitterStats(_ sequence: PoseSequence, config: TuningConfig) -> [JointName: (median: Double, p90: Double, max: Double, samples: Int)] {
    let scale = ClimbScale(sequence: sequence)
    let contacts = ContactDetector().detect(sequence, scale: scale, config: config).contacts
    let pixels = Double(sequence.sourceHeight)
    var out: [JointName: (median: Double, p90: Double, max: Double, samples: Int)] = [:]
    for joint in JointName.extremities {
        var steps: [Double] = []
        for c in contacts where c.joint == joint {
            guard c.endFrame > c.startFrame else { continue }
            for i in (c.startFrame + 1) ... c.endFrame where i < sequence.count {
                guard let a = sequence.frames[i - 1].joints[joint]?.point,
                      let b = sequence.frames[i].joints[joint]?.point else { continue }
                steps.append(scale.iso.distance(a, b) * pixels)
            }
        }
        if let median = steps.median, let p90 = steps.percentile(0.90), let peak = steps.max() {
            out[joint] = (median, p90, peak, steps.count)
        }
    }
    return out
}

/// Fraction of frames each joint clears a confidence bar, and where it drops out.
func trackedFraction(_ sequence: PoseSequence, joint: JointName, above: Double) -> Double {
    let n = sequence.frames.filter { ($0.joints[joint]?.confidence ?? 0) > above }.count
    return Double(n) / Double(max(1, sequence.count))
}

/// Longest run of consecutive frames where a joint is missing entirely. A model
/// that loses a wrist for four seconds is a different problem from one that is
/// merely uncertain about it, and the mean confidence hides the difference.
func longestDropout(_ sequence: PoseSequence, joint: JointName) -> Int {
    var longest = 0, current = 0
    for f in sequence.frames {
        if f.joints[joint] == nil { current += 1; longest = max(longest, current) } else { current = 0 }
    }
    return longest
}

func commandJitter(_ args: [String]) throws {
    guard let input = args.dropFirst().first else { throw CLIError("usage: posecli jitter <poses.json>") }
    let config = configFrom(args)
    let raw = try loadSequence(input)
    let smoothed = PoseSmoother().process(raw, config: config)

    print("frame-to-frame movement of a joint DURING a detected contact — i.e. while it should be still")
    print("joint          samples   median      p90       max     (pixels of frame height)")
    let stats = jitterStats(smoothed, config: config)
    for joint in JointName.extremities {
        guard let j = stats[joint] else { print(pad(joint.rawValue, 14) + "  no contacts"); continue }
        print(pad(joint.rawValue, 14) + String(format: " %7d  %7.2f  %7.2f  %7.2f", j.samples, j.median, j.p90, j.max))
    }

    // Scale reference: how big is a foot in this footage?
    let pixels = Double(smoothed.sourceHeight)
    let iso = IsoMetric(sequence: smoothed)
    let torsos = smoothed.frames.compactMap { f -> Double? in
        guard let sh = f.shoulderCenter, let hp = f.hipCenter else { return nil }
        return iso.distance(sh, hp)
    }
    if let torso = torsos.median {
        print(String(format: "\nfor scale: torso %.0fpx · foot ~%.0fpx · a toe rolling onto an edge moves maybe %.0fpx",
                     torso * pixels, torso * pixels * 0.25, torso * pixels * 0.12))
    }
}

// MARK: - segment (task 7.3 — the whole chain, visible)

func commandSegment(_ args: [String]) throws {
    guard let input = args.dropFirst().first else { throw CLIError("usage: posecli segment <poses.json>") }
    let config = configFrom(args)
    let raw = try loadSequence(input)
    let smoothed = PoseSmoother().process(raw, config: config)
    let scale = ClimbScale(sequence: smoothed)
    let result = ContactDetector().detect(smoothed, scale: scale, config: config)
    let route = RouteBuilder().build(contacts: result.contacts, scale: scale, config: config)
    let match = RouteMatcher().match(contacts: result.contacts, to: route, scale: scale, config: config)
    let segmentation = SectionSegmenter().segment(
        route: route, reference: match, attempt: match,
        referenceFrameCount: smoothed.count, attemptFrameCount: smoothed.count
    )

    print(String(format: "torso %.4f wall units · %d frames @ %.0ffps", scale.torsoLength, smoothed.count, smoothed.frameRate))

    // Per-frame torso, which is a *divisor* in the skeleton renderer's
    // body-length normalisation. A frame whose torso collapses sends that
    // scale factor to infinity, so the spread here is worth seeing.
    let iso = IsoMetric(sequence: smoothed)
    let torsos = smoothed.frames.compactMap { f -> Double? in
        guard let sh = f.shoulderCenter, let hp = f.hipCenter else { return nil }
        let d = iso.distance(sh, hp)
        return d > 1e-9 ? d : nil
    }
    if let p05 = torsos.percentile(0.05), let p50 = torsos.median, let p95 = torsos.percentile(0.95), let lo = torsos.min() {
        let implausible = torsos.filter { $0 < p50 * 0.5 || $0 > p50 * 2.0 }.count
        print(String(format: "per-frame torso  min %.4f  p05 %.4f  median %.4f  p95 %.4f  · %d of %d frames outside 0.5–2× median",
                     lo, p05, p50, p95, implausible, torsos.count))
        let px = Double(smoothed.sourceHeight)
        print(String(format: "in pixels: torso %.0fpx · foot (~0.25 torso) %.0fpx · toe separation would be a few px of that",
                     p50 * px, p50 * px * 0.25))
    }
    print(String(format: "merge radius %.2f BL · cluster eps %.2f BL · gap %d frames",
                 config.contactMergeRadius, config.holdClusterEpsilon, config.contactMergeGapFrames))
    print("")
    print("CHAIN  raw \(result.rawContactCount) contacts → merged \(result.contacts.count) → \(route.holds.count) holds (\(route.handHolds.count) hand, \(route.footHolds.count) foot) → \(match.handAcquisitions.count) hand acquisitions → \(segmentation.sections.count) moves")
    print("")

    if !result.merges.isEmpty {
        print("MERGED AWAY  (the line that finds an over-eager merge radius)")
        for m in result.merges {
            print(pad(m.joint.rawValue, 12) + String(format: " kept %4d-%-4d  absorbed %4d-%-4d  distance %.3f BL  gap %2d frames",
                        m.keptRange.lowerBound, m.keptRange.upperBound,
                        m.absorbedRange.lowerBound, m.absorbedRange.upperBound,
                        m.distance, m.gapFrames))
        }
        print("")
    }

    print("HOLDS")
    print("  id      x      y  contacts  used by        first")
    for h in route.holds {
        let usedBy = [h.usedByHands ? "hands" : nil, h.usedByFeet ? "feet" : nil].compactMap { $0 }.joined(separator: "+")
        print(String(format: "  %2d  %.3f  %.3f  %8d  ", h.id, h.position.x, h.position.y, h.contactCount)
              + pad(usedBy, 13) + String(format: "%6d", h.firstFrame))
    }
    print("")

    print("HAND ACQUISITIONS  (these are the move boundaries)")
    for a in match.handAcquisitions {
        print(String(format: "  frame %4d → hold %2d", a.frame, a.holdID))
    }
    print("")

    print("MOVES")
    for section in segmentation.sections {
        print(String(format: "  %@  hold %2d → %2d   frames %4d-%4d",
                     section.displayName, section.fromHold.id, section.toHold.id,
                     section.referenceRange.lowerBound, section.referenceRange.upperBound))
    }
    for w in result.warnings + route.warnings + segmentation.warnings { print("  warning: \(w)") }
}

// MARK: - frames (skeleton render, task 0.3)

let skeletonEdges: [(JointName, JointName)] = [
    (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
    (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
    (.leftShoulder, .leftHip), (.rightShoulder, .rightHip), (.leftHip, .rightHip),
    (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
    (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    (.neck, .nose)
]

func commandFrames(_ args: [String]) async throws {
    let rest = Array(args.dropFirst())
    guard rest.count >= 2 else { throw CLIError("usage: posecli frames <video> <poses.json> --indices 10,50 --out dir") }
    let videoPath = rest[0]
    let sequence = try loadSequence(rest[1])
    let outDir = arg("out", args) ?? "frames"
    let indices = (arg("indices", args) ?? "0").split(separator: ",").compactMap { Int($0) }
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    var holds: [Hold] = []
    if args.contains("--holds") {
        let config = configFrom(args)
        let smoothed = PoseSmoother().process(sequence, config: config)
        let scale = ClimbScale(sequence: smoothed)
        let r = ContactDetector().detect(smoothed, scale: scale, config: config)
        holds = RouteBuilder().build(contacts: r.contacts, scale: scale, config: config).holds
    }

    let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    for index in indices {
        guard let frame = sequence.frame(at: index) else { print("no frame \(index)"); continue }
        let time = CMTime(seconds: frame.timeSeconds, preferredTimescale: 600)
        let (cgImage, _) = try await generator.image(at: time)
        let path = "\(outDir)/frame_\(String(format: "%05d", index)).png"
        try drawSkeleton(on: cgImage, frame: frame, holds: holds, to: path)
        print("wrote \(path)  t=\(String(format: "%.2f", frame.timeSeconds))s")
    }
}

func drawSkeleton(on image: CGImage, frame: PoseFrame, holds: [Hold], to path: String) throws {
    let w = image.width, h = image.height
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CLIError("cannot create bitmap context") }

    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    // CGContext origin is bottom-left, matching the wall-space convention.
    func px(_ p: Point2D) -> CGPoint { CGPoint(x: p.x * Double(w), y: p.y * Double(h)) }

    ctx.setLineWidth(max(2, Double(w) / 320))
    ctx.setStrokeColor(CGColor(red: 0, green: 1, blue: 0.4, alpha: 0.9))
    for (a, b) in skeletonEdges {
        guard let pa = frame.joints[a]?.point, let pb = frame.joints[b]?.point else { continue }
        ctx.move(to: px(pa)); ctx.addLine(to: px(pb))
    }
    ctx.strokePath()

    for (name, joint) in frame.joints {
        let r = Double(w) / 160
        let isExtremity = JointName.extremities.contains(name)
        ctx.setFillColor(isExtremity
            ? CGColor(red: 1, green: 0.3, blue: 0, alpha: 0.95)
            : CGColor(red: 1, green: 1, blue: 0, alpha: 0.7 * joint.confidence + 0.2))
        let p = px(joint.point)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    ctx.setStrokeColor(CGColor(red: 0.2, green: 0.6, blue: 1, alpha: 0.9))
    ctx.setLineWidth(max(2, Double(w) / 400))
    for hold in holds {
        let p = px(hold.position)
        let r = Double(w) / 90
        ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    guard let out = ctx.makeImage() else { throw CLIError("cannot render image") }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        throw CLIError("cannot create png destination")
    }
    CGImageDestinationAddImage(dest, out, nil)
    guard CGImageDestinationFinalize(dest) else { throw CLIError("png write failed") }
}

// MARK: - pipeline (end-to-end on real footage)

func commandPipeline(_ args: [String]) async throws {
    let rest = Array(args.dropFirst())
    guard rest.count >= 2 else { throw CLIError("usage: posecli pipeline <reference.mov> <attempt.mov>") }
    let config = configFrom(args)
    let root = URL(fileURLWithPath: arg("root", args) ?? NSTemporaryDirectory()).appendingPathComponent("posecli-sessions")
    let store = SessionStore(root: root)

    var session = try await store.create(name: "cli")
    let reference = try await store.importVideo(from: URL(fileURLWithPath: rest[0]), into: session, role: .reference, label: "Reference")
    let attempt = try await store.importVideo(from: URL(fileURLWithPath: rest[1]), into: session, role: .attempt, label: "Attempt 1")
    session.reference = reference
    session.attempts = [attempt]
    try await store.save(session)

    let pipeline = ProcessingPipeline(store: store)
    let start = Date()
    let result = try await pipeline.process(session: session, config: config) { p in
        FileHandle.standardError.write("  \(p.stageName) \(Int(p.fraction * 100))%\r".data(using: .utf8)!)
    }
    print("\nfirst run: \(String(format: "%.1f", Date().timeIntervalSince(start)))s")

    for stage in result.stages {
        print(pad(stage.name, 18) + String(format: "%7.2fs  ", stage.seconds) + pad(stage.status.rawValue, 9) + stage.detail)
    }
    print("\nroute: \(result.route.holds.count) holds (\(result.route.handHolds.count) hand)  moves: \(result.sections.count)")
    print(String(format: "registration residual %.5f  succeeded %@", result.alignment.residual, result.alignment.succeeded ? "yes" : "NO"))
    print("fall: \(result.fallReport.occurred ? "move \((result.fallReport.fallSectionIndex ?? -1) + 1)" : "none")")

    for analysis in result.analyses {
        print("\n\(analysis.headline)")
        for note in analysis.observations {
            print("  \(note.text)")
            for line in note.evidence.split(separator: "\n") { print("      · \(line)") }
        }
        if let drill = analysis.drill { print("  try: \(drill)") }
    }
    if let fall = result.fallAnalysis {
        print("\nFALL: \(fall.headline)")
        for note in fall.observations {
            print("  \(note.text)")
            for line in note.evidence.split(separator: "\n") { print("      · \(line)") }
        }
    }
    print("\nwarnings:")
    for warning in result.warnings { print("  • \(warning)") }

    // The reprocess guarantee, measured rather than asserted.
    var second = config
    second.contactVelocityThreshold *= 1.2
    let reprocessStart = Date()
    let again = try await pipeline.process(session: session, config: second)
    print(String(format: "\nreprocess: %.2fs  pose stage: %@", Date().timeIntervalSince(reprocessStart), again.stages[0].detail))
    try? FileManager.default.removeItem(at: root)
}

// MARK: - agree (does the Swift port match the Python reference?)

func commandAgree(_ args: [String]) throws {
    let rest = Array(args.dropFirst())
    guard rest.count >= 2 else { throw CLIError("usage: posecli agree <swift.json> <python.json>") }
    let a = try loadSequence(rest[0])
    let b = try loadSequence(rest[1])
    let pixels = Double(a.sourceHeight)

    print("per-joint disagreement between the two implementations, in pixels of frame height")
    print("joint          both present   median      p90       max")
    var worst = 0.0
    for name in JointName.allCases {
        var deltas: [Double] = []
        for (fa, fb) in zip(a.frames, b.frames) {
            guard let ja = fa.joints[name], let jb = fb.joints[name] else { continue }
            deltas.append(ja.point.distance(to: jb.point) * pixels)
        }
        guard let median = deltas.median, let p90 = deltas.percentile(0.90), let peak = deltas.max() else { continue }
        worst = max(worst, median)
        print(pad(name.rawValue, 14) + String(format: " %12d  %7.2f  %7.2f  %7.2f", deltas.count, median, p90, peak))
    }
    // Both implementations run the same model on the same frames. Anything past
    // a pixel means the preprocessing differs — a wrong crop or a missed
    // normalisation produces keypoints that look plausible and are wrong.
    let verdict = worst <= 1.0 ? "AGREE" : "DISAGREE"
    print(String(format: "\nworst median disagreement %.2f px → %@", worst, verdict as NSString))
}

// MARK: - compare (task 8.4 — does changing the pose model change the answer?)

/// One tracker's full run: the pose it produced and everything the pipeline
/// made of it.
struct TrackerRun {
    var label: String
    var referencePose: PoseSequence
    var attemptPose: PoseSequence
    var processed: ProcessedSession
}

/// Runs the **real** pipeline, with pose supplied rather than extracted.
///
/// Seeding the pose cache and then running `ProcessingPipeline` unchanged is
/// deliberate: a parallel implementation would drift from the app and the
/// comparison would stop meaning anything. Each tracker gets its own session so
/// the two can never read each other's cache — which is exactly the trap task
/// 8.0 exists to close inside the app.
func runTracker(
    label: String,
    referenceVideo: String,
    attemptVideo: String,
    referencePose: PoseSequence?,
    attemptPose: PoseSequence?,
    root: URL,
    config: TuningConfig
) async throws -> TrackerRun {
    let store = SessionStore(root: root.appendingPathComponent(label))
    var session = try await store.create(name: label)
    let reference = try await store.importVideo(from: URL(fileURLWithPath: referenceVideo), into: session, role: .reference, label: "Reference")
    let attempt = try await store.importVideo(from: URL(fileURLWithPath: attemptVideo), into: session, role: .attempt, label: "Attempt 1")
    session.reference = reference
    session.attempts = [attempt]
    try await store.save(session)

    // The label is only cosmetic here; each tracker already has its own store
    // root, so the two can never read each other's cache.
    let source = session.poseSource
    if let referencePose { try await store.cachePose(referencePose, session: session, video: reference, source: source) }
    if let attemptPose { try await store.cachePose(attemptPose, session: session, video: attempt, source: source) }

    let processed = try await ProcessingPipeline(store: store).process(session: session, config: config)
    let refUsed = try await store.cachedPose(session: session, video: reference, source: source) ?? processed.referencePose
    let attUsed = try await store.cachedPose(session: session, video: attempt, source: source) ?? processed.attemptPose
    return TrackerRun(label: label, referencePose: refUsed, attemptPose: attUsed, processed: processed)
}

func commandCompare(_ args: [String]) async throws {
    let rest = Array(args.dropFirst())
    guard rest.count >= 2 else {
        throw CLIError("""
        usage: posecli compare <reference.mov> <attempt.mov> \
                 [--a-ref pose.json --a-att pose.json] [--a-label Vision] \
                 --b-ref pose.json --b-att pose.json [--b-label Other]

        Omit --a-* to run Vision live as the baseline.
        """)
    }
    let config = configFrom(args)
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("posecli-compare-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let a = try await runTracker(
        label: arg("a-label", args) ?? "Vision",
        referenceVideo: rest[0], attemptVideo: rest[1],
        referencePose: try arg("a-ref", args).map(loadSequence),
        attemptPose: try arg("a-att", args).map(loadSequence),
        root: root, config: config
    )
    let b = try await runTracker(
        label: arg("b-label", args) ?? "Other",
        referenceVideo: rest[0], attemptVideo: rest[1],
        referencePose: try arg("b-ref", args).map(loadSequence),
        attemptPose: try arg("b-att", args).map(loadSequence),
        root: root, config: config
    )

    let jitterLimit = Double(arg("jitterlimit", args) ?? "2.0") ?? 2.0
    printComparison(a, b, config: config, jitterLimit: jitterLimit)
}

func printComparison(_ a: TrackerRun, _ b: TrackerRun, config: TuningConfig, jitterLimit: Double) {
    let width = 13
    func row(_ label: String, _ left: String, _ right: String) {
        print(pad(label, 30) + pad(left, width) + pad(right, width))
    }

    print("\n" + pad("", 30) + pad(a.label, width) + pad(b.label, width))
    print(String(repeating: "─", count: 30 + width * 2))

    print("\nPOSE — fraction of frames tracked above confidence 0.5")
    for (name, sequences) in [("reference", (a.referencePose, b.referencePose)), ("attempt", (a.attemptPose, b.attemptPose))] {
        print("  \(name)")
        for joint in JointName.extremities + [.leftHip, .leftShoulder] {
            row("    " + joint.rawValue,
                String(format: "%.0f%%", trackedFraction(sequences.0, joint: joint, above: 0.5) * 100),
                String(format: "%.0f%%", trackedFraction(sequences.1, joint: joint, above: 0.5) * 100))
        }
        row("    longest wrist dropout",
            "\(max(longestDropout(sequences.0, joint: .leftWrist), longestDropout(sequences.0, joint: .rightWrist))) fr",
            "\(max(longestDropout(sequences.1, joint: .leftWrist), longestDropout(sequences.1, joint: .rightWrist))) fr")
    }

    print("\nJITTER — px moved per frame while a limb is at rest (the noise floor)")
    let aJitter = jitterStats(a.attemptPose, config: config)
    let bJitter = jitterStats(b.attemptPose, config: config)
    for joint in JointName.extremities {
        row("  " + joint.rawValue,
            aJitter[joint].map { String(format: "%.2f px", $0.median) } ?? "—",
            bJitter[joint].map { String(format: "%.2f px", $0.median) } ?? "—")
    }
    // The toe question, decided rather than argued. A foot keypoint is only
    // useful for micro-movement if it sits still when the foot sits still.
    let footJitter = [bJitter[.leftAnkle]?.median, bJitter[.rightAnkle]?.median].compactMap { $0 }.max()
    if let footJitter {
        let verdict = footJitter <= jitterLimit ? "PASS" : "FAIL"
        print(String(format: "\n  foot-keypoint jitter %.2f px against a %.1f px limit → %@", footJitter, jitterLimit, verdict as NSString))
        print("  (a toe rolling onto an edge moves roughly 7–9 px at this framing, so the")
        print("   signal has to clear this floor by a comfortable margin to be measurable)")
    }

    print("\nCHAIN")
    for (name, runs) in [("reference", (a.processed, b.processed))] {
        _ = name
        row("  contacts (ref / att)",
            "\(runs.0.referenceContacts.count)/\(runs.0.attemptContacts.count)",
            "\(runs.1.referenceContacts.count)/\(runs.1.attemptContacts.count)")
        row("  holds", "\(runs.0.route.holds.count)", "\(runs.1.route.holds.count)")
        row("  hand holds", "\(runs.0.route.handHolds.count)", "\(runs.1.route.handHolds.count)")
        row("  moves", "\(runs.0.sections.count)", "\(runs.1.sections.count)")
        row("  moves attempt reached",
            "\(runs.0.sections.filter(\.attemptReached).count)",
            "\(runs.1.sections.filter(\.attemptReached).count)")
        row("  fall detected",
            runs.0.fallReport.occurred ? "move \((runs.0.fallReport.fallSectionIndex ?? -1) + 1)" : "no",
            runs.1.fallReport.occurred ? "move \((runs.1.fallReport.fallSectionIndex ?? -1) + 1)" : "no")
    }

    // The point of the whole exercise: does the climber get different advice?
    print("\nANALYSIS — what the climber is actually told")
    let moves = max(a.processed.analyses.count, b.processed.analyses.count)
    for i in 0 ..< moves {
        let left = a.processed.analysis(forSection: i)
        let right = b.processed.analysis(forSection: i)
        let same = left?.headline == right?.headline
        print("\n  Move \(i + 1)\(same ? "  (same)" : "  ← DIFFERENT")")
        print("    \(a.label): \(left?.headline ?? "—")")
        print("    \(b.label): \(right?.headline ?? "—")")
        if !same {
            for note in left?.observations ?? [] { print("      \(a.label) · \(note.text)") }
            for note in right?.observations ?? [] { print("      \(b.label) · \(note.text)") }
        }
    }

    for (label, run) in [(a.label, a.processed), (b.label, b.processed)] {
        print("\n\(label) warnings: \(run.warnings.count)")
    }
}

// MARK: - seed (drop a ready-made session into an app container)

func commandSeed(_ args: [String]) async throws {
    let rest = Array(args.dropFirst())
    guard rest.count >= 3 else { throw CLIError("usage: posecli seed <sessions-root> <reference.mov> <attempt.mov>") }
    let store = SessionStore(root: URL(fileURLWithPath: rest[0]))
    var session = try await store.create(name: "Fixture session")
    let reference = try await store.importVideo(from: URL(fileURLWithPath: rest[1]), into: session, role: .reference, label: "Reference")
    let attempt = try await store.importVideo(from: URL(fileURLWithPath: rest[2]), into: session, role: .attempt, label: "Attempt 1")
    session.reference = reference
    session.attempts = [attempt]
    try await store.save(session)
    print(session.id.uuidString)
}

// MARK: - drift (does the camera move *during* one clip?)

func commandDrift(_ args: [String]) async throws {
    guard let path = args.dropFirst().first else { throw CLIError("usage: posecli drift <video> [--step 2]") }
    let step = Double(arg("step", args) ?? "2") ?? 2
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let duration = try await asset.load(.duration).seconds
    let source = VideoFrameSource(url: URL(fileURLWithPath: path))
    let base = try await source.image(atSeconds: 0.5)

    print("drift of each frame against t=0.5s, in wall-widths")
    print("   t     mean-displacement")
    var times: [Double] = []
    var t = 0.5
    while t < duration - 0.2 { times.append(t); t += step }
    for t in times {
        guard let image = try? await source.image(atSeconds: t) else { continue }
        guard let h = WallAligner.homography(from: image, to: base) else {
            print(String(format: "%5.1f   registration failed", t)); continue
        }
        print(String(format: "%5.1f   %.4f", t, WallAligner.meanGridDisplacement(h)))
    }
}

// MARK: - entry

let cliArgs = Array(CommandLine.arguments.dropFirst())
guard let command = cliArgs.first else {
    print("""
    posecli — Phase 0 pose harness

      pose     <video> [--out poses.json] [--rate 30]
      contacts <poses.json> [--vthresh v] [--dwell n] [--eps e] [--merge m]
      sweep    <poses.json>
      segment  <poses.json> [--merge m] [--eps e] [--mergegap n]
      frames   <video> <poses.json> --indices 10,50 [--out dir] [--holds]
      pipeline <reference.mov> <attempt.mov>
      jitter   <poses.json>
      agree    <swift.json> <python.json>
      compare  <reference.mov> <attempt.mov> --b-ref p.json --b-att p.json
               [--a-ref p.json --a-att p.json] [--a-label X --b-label Y]
               [--jitterlimit 2.0]
    """)
    exit(1)
}

do {
    switch command {
    case "pose": try await commandPose(cliArgs)
    case "contacts": try commandContacts(cliArgs)
    case "sweep": try commandSweep(cliArgs)
    case "segment": try commandSegment(cliArgs)
    case "jitter": try commandJitter(cliArgs)
    case "frames": try await commandFrames(cliArgs)
    case "pipeline": try await commandPipeline(cliArgs)
    case "seed": try await commandSeed(cliArgs)
    case "compare": try await commandCompare(cliArgs)
    case "agree": try commandAgree(cliArgs)
    case "drift": try await commandDrift(cliArgs)
    default: throw CLIError("unknown command \(command)")
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
