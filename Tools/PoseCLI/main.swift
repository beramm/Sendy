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

// MARK: - route (why does this route have that many holds?)

/// The evidence behind `RouteBuilder`'s hold count.
///
/// Hold count is the number that decides whether the moves mean anything, and
/// three separate things move it: contacts made on the floor, the cluster
/// radius, and contacts touched exactly once. This prints all three so a hold
/// count can be argued with rather than eyeballed.
func commandRoute(_ args: [String]) throws {
    guard let input = args.dropFirst().first else { throw CLIError("usage: posecli route <poses.json>") }
    let config = configFrom(args)
    let smoothed = PoseSmoother().process(try loadSequence(input), config: config)
    let scale = ClimbScale(sequence: smoothed)
    let contacts = ContactDetector().detect(smoothed, scale: scale, config: config).contacts

    print(String(format: "torso %.4f wall units   contacts %d", scale.torsoLength, contacts.count))
    let dwells = contacts.map(\.frameCount).sorted()
    if !dwells.isEmpty {
        print("dwell frames: min \(dwells[0])  p25 \(dwells[dwells.count / 4])  median \(dwells[dwells.count / 2])  p75 \(dwells[3 * dwells.count / 4])  max \(dwells[dwells.count - 1])")
    }

    let feet = contacts.filter(\.isFoot)
    if let floor = feet.map(\.position.y).min() {
        let line = floor + config.groundMargin * scale.torsoLength
        let onGround = contacts.filter { $0.isFoot && $0.position.y <= line }
        print(String(format: "floor y %.3f  ground line %.3f  contacts on the floor %d", floor, line, onGround.count))
        for c in onGround.sorted(by: { $0.startFrame < $1.startFrame }) {
            print(String(format: "  floor  %@  f%d-%d  y %.3f", pad(c.joint.rawValue, 11), c.startFrame, c.endFrame, c.position.y))
        }
    }

    var nn: [Double] = []
    for (i, a) in contacts.enumerated() {
        var best = Double.infinity
        for (j, b) in contacts.enumerated() where i != j { best = min(best, scale.distance(a.position, b.position)) }
        if best.isFinite { nn.append(best) }
    }
    let s = nn.sorted()
    if !s.isEmpty {
        print(String(format: "nearest-neighbour BL: p10 %.2f  p25 %.2f  median %.2f  p75 %.2f  p90 %.2f  max %.2f",
                     s[s.count / 10], s[s.count / 4], s[s.count / 2], s[3 * s.count / 4], s[9 * s.count / 10], s[s.count - 1]))
    }

    print("\neps(BL)  holds  hand  single-contact")
    for eps in [0.20, 0.30, 0.40, 0.50, 0.60, 0.75, 0.90, 1.10, 1.40] {
        var c2 = config
        c2.holdClusterEpsilon = eps
        let r = RouteBuilder().build(contacts: contacts, scale: scale, config: c2)
        print(String(format: "%6.2f   %4d  %4d  %8d", eps, r.holds.count, r.handHolds.count, r.holds.filter { $0.contactCount == 1 }.count))
    }

    // Spread is the diameter of a cluster. A hold has a physical size, so a
    // "hold" whose contacts span more than about one hold width is a chain of
    // separate holds joined by single-linkage, not a hold.
    print("\nhold  n   spread(BL)  hand  x      y")
    let full = RouteBuilder().build(contacts: contacts, scale: scale, config: config)
    for h in full.holds {
        let members = contacts.filter { scale.distance($0.position, h.position) <= config.holdClusterEpsilon * 3 }
            .filter { c in full.holds.min(by: { scale.distance($0.position, c.position) < scale.distance($1.position, c.position) })?.id == h.id }
        var spread = 0.0
        for a in members { for b in members { spread = max(spread, scale.distance(a.position, b.position)) } }
        print(String(format: "%4d %3d   %8.2f   %@  %.3f  %.3f", h.ordinal + 1, h.contactCount, spread, h.isHandHold ? "yes " : "no  ", h.position.x, h.position.y))
    }

    let route = RouteBuilder().build(contacts: contacts, scale: scale, config: config)
    print("\nsingle-contact holds at eps \(config.holdClusterEpsilon):")
    for h in route.holds where h.contactCount == 1 {
        let c = contacts.first { $0.startFrame == h.firstFrame && $0.joint == h.firstUsedBy }
        print(String(format: "  hold %2d  %@ f%4d  dwell %3d  x %.3f  y %.3f  conf %.2f",
                     h.ordinal + 1, pad(h.firstUsedBy.rawValue, 11), h.firstFrame,
                     c?.frameCount ?? -1, h.position.x, h.position.y, c?.confidence ?? -1))
    }
    for w in route.warnings { print("warning: \(w)") }
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
        referenceFrameCount: smoothed.count, attemptFrameCount: smoothed.count,
        scale: scale, config: config
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

// MARK: - fall (why FallDetector said what it said)

/// Prints the two gates `FallDetector` ANDs together — "every contact
/// released" and "COM accelerating downward" — frame by frame, so a
/// non-detection can be pinned on one of them instead of guessed at.
func commandFall(_ args: [String]) throws {
    guard let input = args.dropFirst().first else { throw CLIError("usage: posecli fall <poses.json>") }
    var config = configFrom(args)
    if let v = arg("accel", args).flatMap(Double.init) { config.fallAccelThreshold = v }
    if let v = arg("sustain", args).flatMap(Double.init) { config.fallSustainSeconds = v }
    if let v = arg("recontact", args).flatMap(Double.init) { config.fallRecontactWindowSeconds = v }

    let raw = try loadSequence(input)
    let smoothed = PoseSmoother().process(raw, config: config)
    let scale = ClimbScale(sequence: smoothed)
    let contacts = ContactDetector().detect(smoothed, scale: scale, config: config)
    let metrics = MetricsEngine().measure(sequence: smoothed, contacts: contacts.contacts, scale: scale, config: config)
    let detector = FallDetector()
    let frameRate = detector.estimatedFrameRate(metrics.frames)
    let accel = detector.verticalAcceleration(metrics.frames, scale: metrics.scale)
    let sustainFrames = max(2, Int((config.fallSustainSeconds * frameRate).rounded()))
    let recontactFrames = max(1, Int((config.fallRecontactWindowSeconds * frameRate).rounded()))

    print(String(format: "%d frames @ %.1ffps · torso %.4f wall units · %d contacts",
                 metrics.frames.count, frameRate, scale.torsoLength, contacts.contacts.count))
    print(String(format: "gates: released AND accel <= %.1f BL/s², sustained %d frames, no re-contact within %d",
                 -config.fallAccelThreshold, sustainFrames, recontactFrames))

    let known = accel.compactMap { $0 }
    if let lo = known.min(), let hi = known.max() {
        let below = known.filter { $0 <= -config.fallAccelThreshold }.count
        print(String(format: "accel: %d of %d frames measured · min %.1f  p05 %.1f  median %.1f  p95 %.1f  max %.1f · %d frames past threshold",
                     known.count, accel.count, lo, known.percentile(0.05) ?? 0, known.median ?? 0,
                     known.percentile(0.95) ?? 0, hi, below))
    } else {
        print("accel: no frame had a COM in three consecutive frames — the COM track is the problem, not the threshold.")
    }

    // Release runs: the other gate, on its own. Ground contacts are excluded
    // here exactly as the detector excludes them, so a run listed as "long
    // enough" is one the detector also saw.
    let ground = detector.groundContactJoints(
        contacts: contacts.contacts, frameCount: metrics.frames.count, scale: metrics.scale, config: config
    )
    var runs: [(start: Int, end: Int)] = []
    var start: Int?
    for (i, f) in metrics.frames.enumerated() {
        if f.activeContacts.subtracting(ground[i]).isEmpty {
            if start == nil { start = i }
        } else if let s = start {
            runs.append((s, i - 1)); start = nil
        }
    }
    if let s = start { runs.append((s, metrics.frames.count - 1)) }
    let firstContact = metrics.frames.indices.first { !metrics.frames[$0].activeContacts.subtracting(ground[$0]).isEmpty }
    print("first frame on the wall: \(firstContact.map(String.init) ?? "never")")
    print("release runs (every limb off the wall; floor contacts don't count): \(runs.count)")
    for r in runs.suffix(20) {
        let window = accel[r.start ... r.end].compactMap { $0 }
        let minAccel = window.min()
        let length = r.end - r.start + 1
        print(String(format: "  frames %4d-%-4d  %4d frames (%.2fs)  min accel %@  %@",
                     r.start, r.end, length, Double(length) / frameRate,
                     minAccel.map { String(format: "%7.1f", $0) } ?? "      -",
                     length >= sustainFrames ? "long enough" : "too short"))
    }

    // The last few seconds, frame by frame — where a real fall has to live.
    let tailStart = max(0, metrics.frames.count - Int(frameRate * 4))
    print("\nlast 4 seconds")
    print(" frame     t   contacts               accel   comConf")
    for i in tailStart ..< metrics.frames.count {
        let f = metrics.frames[i]
        let names = f.activeContacts.map { $0.rawValue }.sorted().joined(separator: ",")
        let a = accel[i].map { String(format: "%7.1f", $0) } ?? "      -"
        print(String(format: "%6d %5.2f  ", i, f.timeSeconds)
              + pad(names.isEmpty ? "—" : names, 22)
              + " " + a + String(format: "  %.2f", f.comConfidence))
    }

    let report = detector.detect(metrics: metrics, sections: [], useAttemptRange: true, config: config, contacts: contacts.contacts)
    print("\nverdict: \(report.occurred ? "fall at frame \(report.fallFrame ?? -1)" : "no fall")")
    for w in report.warnings + contacts.warnings + metrics.warnings { print("warning: \(w)") }
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

    // Seeding the cache with pose pulled off a device reproduces exactly what
    // the app saw, without re-running Vision on a 100MB clip.
    if let path = arg("ref-pose", args) {
        try await store.cachePose(try loadSequence(path), session: session, video: reference, source: session.poseSource)
    }
    if let path = arg("att-pose", args) {
        try await store.cachePose(try loadSequence(path), session: session, video: attempt, source: session.poseSource)
    }

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

    // Sequences: the unit of comparison, bounded by holds both climbers used.
    let sequenceResult = result.sequences
    print(String(format: "\nSEQUENCES  %d, from %d anchors — anchor density %.0f%% of reference hand holds",
                 sequenceResult.sequences.count, sequenceResult.anchorIDs.count, sequenceResult.anchorDensity * 100))
    print("seq   anchors     reference        n   attempt          n   ratio  moves ref/att")
    for s in sequenceResult.sequences {
        print(String(
            format: "%3d   %3d→%-3d   %5d-%-5d %5d   %5d-%-5d %5d   %5.2f    %d / %d",
            s.index + 1, s.fromAnchorID, s.toAnchorID,
            s.referenceRange.lowerBound, s.referenceRange.upperBound, s.referenceRange.count,
            s.attemptRange.lowerBound, s.attemptRange.upperBound, s.attemptRange.count,
            s.frameRatio, s.referenceMoves.count, s.attemptMoves.count))
    }
    for w in sequenceResult.warnings { print("  warning: \(w)") }

    // Which of the reference's own moves each sequence claims. The results
    // screen marks the fall by asking whether the fall's move is in this list,
    // so an overlapping or over-wide range puts the marker on every bar.
    print("\nSEQUENCE → REFERENCE MOVES  (what the fall marker is tested against)")
    print("  fall move index: \(result.fallReport.fallSectionIndex.map(String.init) ?? "none")")
    print("  sections: \(result.sections.count), indices \(result.sections.map(\.index))")
    print("  reference beta moves: \(sequenceResult.referenceBeta.moves.count) — the index space referenceMoves lives in")
    for s in sequenceResult.sequences {
        // Exactly what ResultsView does to decide the fall marker.
        let sections = s.referenceMoves.filter { result.sections.indices.contains($0) }.map { result.sections[$0] }
        let marked = sections.contains { result.fallReport.fallSectionIndex == $0.index }
        print(String(format: "%3d   referenceMoves %2d..<%-2d  attemptMoves %2d..<%-2d   moves \(sections.map { $0.index + 1 })  fall marker: %@",
                     s.index + 1,
                     s.referenceMoves.lowerBound, s.referenceMoves.upperBound,
                     s.attemptMoves.lowerBound, s.attemptMoves.upperBound,
                     marked ? "YES" : "no"))
    }

    // Locked playback reads the attempt frame off these paths. An empty one is
    // a pane that shows nothing however far the scrubber moves.
    print("\nSEQUENCE WARP PATHS  (what locked scrubbing follows)")
    for s in sequenceResult.sequences {
        let path = result.sequenceWarpPaths.first { $0.sectionIndex == s.index }
        let pairs = path?.pairs.count ?? 0
        let refSpan = path.flatMap { p in p.pairs.map(\.referenceFrame).min().map { ($0, p.pairs.map(\.referenceFrame).max() ?? $0) } }
        print(String(format: "%3d   %5d pairs  mean cost %@  covers ref %@  monotonic %@",
                     s.index + 1, pairs,
                     path.map { String(format: "%.3f", $0.meanCost) } ?? "—",
                     refSpan.map { "\($0.0)-\($0.1)" } ?? "nothing",
                     (path?.isMonotonic ?? false) ? "yes" : "NO"))
    }

    // Per-move frame spans for both climbers.
    //
    // Every scrubber complaint from the gym — teleporting, a frozen pane, a
    // pane already on the next hold — has come down to one of these spans being
    // the wrong width, and each was diagnosed by reasoning about code rather
    // than reading the numbers. Printing them makes that a one-command check.
    //
    // `ratio` is attempt frames per reference frame. Far from 1 means locked
    // playback has to warp hard, which is what reads as teleporting.
    print("\nSPANS  (ref and attempt frame ranges per move)")
    print("move   reference        n   attempt          n   ratio  note")
    for s in result.sections {
        let refN = s.referenceRange.count
        let attN = s.attemptRange.count
        let ratio = refN > 0 ? Double(attN) / Double(refN) : 0
        print(String(
            format: "%4d   %5d-%-5d %5d   %5d-%-5d %5d   %5.2f  %@",
            s.index + 1,
            s.referenceRange.lowerBound, s.referenceRange.upperBound, refN,
            s.attemptRange.lowerBound, s.attemptRange.upperBound, attN,
            ratio,
            s.divergence.map { $0.kind.rawValue } ?? (s.attemptReached ? "" : "unreached")
        ))
    }

    // Both betas side by side, in hold order.
    //
    // "You climbed this differently" on every move is either true or a
    // matching failure, and the only thing that separates the two is seeing
    // which holds each climber's hands actually landed on, in which order.
    let matcher = RouteMatcher()
    let refMatch = matcher.match(contacts: result.referenceContacts, to: result.route, scale: result.referenceScale, config: config)
    let attMatch = matcher.match(contacts: result.attemptContacts, to: result.route, scale: result.referenceScale, config: config)
    print("\nHAND ACQUISITIONS  (the move boundaries — divergence lives here)")
    print("  reference: " + refMatch.handAcquisitions.map { "\($0.holdID)@\($0.frame)" }.joined(separator: "  "))
    print("  attempt:   " + attMatch.handAcquisitions.map { "\($0.holdID)@\($0.frame)" }.joined(separator: "  "))
    let refOrder = refMatch.handAcquisitions.map(\.holdID)
    let attOrder = attMatch.handAcquisitions.map(\.holdID)
    print("  reference holds: \(Array(Set(refOrder)).sorted())")
    print("  attempt holds:   \(Array(Set(attOrder)).sorted())")
    print("  shared (anchor candidates): \(Array(Set(refOrder).intersection(Set(attOrder))).sorted())")
    print("\nATTEMPT CONTACTS → HOLD  (off-route and unmatched hands are why moves vanish)")
    print("  joint         start   end   hold      x      y   conf")
    for m in attMatch.matched.sorted(by: { $0.contact.startFrame < $1.contact.startFrame }) {
        print("  " + pad(m.contact.joint.rawValue, 12)
              + String(format: " %5d %5d   ", m.contact.startFrame, m.contact.endFrame)
              + pad(m.holdID.map(String.init) ?? "—", 5)
              + String(format: " %.3f  %.3f   %.2f", m.contact.position.x, m.contact.position.y, m.contact.confidence))
    }

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
    // The plate has to survive a threshold change the same way pose does —
    // it depends on the video and its own three fields, and on nothing else.
    if let stage = again.stages.first(where: { $0.name == "Wall backdrop" }) {
        print("reprocess backdrop: \(stage.detail)")
    }

    // Written out so the plate can be looked at without a device: the whole
    // point of it is whether a derived hold lands on a real one.
    if let out = arg("plate-out", args), let plate = result.wallPlate {
        let url = URL(fileURLWithPath: out)
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, plate.image, nil)
            if CGImageDestinationFinalize(destination) {
                print("plate → \(out)  \(plate.image.width)×\(plate.image.height)")
            }
        }
    }

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
      route    <poses.json>
      segment  <poses.json> [--merge m] [--eps e] [--mergegap n]
      fall     <poses.json> [--accel a] [--sustain s] [--recontact s]
      frames   <video> <poses.json> --indices 10,50 [--out dir] [--holds]
      pipeline <reference.mov> <attempt.mov> [--plate-out wall.png]
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
    case "fall": try commandFall(cliArgs)
    case "jitter": try commandJitter(cliArgs)
    case "route": try commandRoute(cliArgs)
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
