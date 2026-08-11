import Testing
import Foundation
@testable import VideoOverlapCore

@Suite("Metrics")
struct MetricsTests {

    /// Task 3.1 — a standing pose puts the COM near the navel: above the hips,
    /// well below the shoulders, and on the midline.
    @Test("COM of a standing pose lands near the navel")
    func standingCOM() throws {
        let frame = SyntheticClimb.standingFrame(hipY: 0.5)
        let result = try #require(COMEstimator().estimate(frame))
        let hipY = frame.hipCenter!.y
        let shoulderY = frame.shoulderCenter!.y
        #expect(result.point.y > hipY, "COM below the hips")
        #expect(result.point.y < shoulderY, "COM above the shoulders")
        // Navel height is roughly the lower third of the torso.
        let fraction = (result.point.y - hipY) / (shoulderY - hipY)
        #expect(fraction > 0.1 && fraction < 0.55, "COM at \(fraction) of the torso")
        #expect(abs(result.point.x - 0.5) < 0.02, "COM off the midline")
        #expect(result.confidence > 0.95, "most of the body should be tracked")
    }

    @Test("A partly tracked body reports reduced COM confidence")
    func partialCOMConfidence() throws {
        var frame = SyntheticClimb.standingFrame()
        for name in [JointName.leftKnee, .rightKnee, .leftAnkle, .rightAnkle] {
            frame.joints[name] = nil
        }
        let result = try #require(COMEstimator().estimate(frame))
        #expect(result.confidence < 0.9)
        #expect(result.confidence > 0.5)
    }

    /// Task 3.5 — per-frame limb loads sum to bodyweight.
    @Test("IDW loads sum to bodyweight and favour the nearest contact")
    func loadSumsToBodyweight() {
        let scale = ClimbScale(iso: .square, torsoLength: 0.12)
        let com = Point2D(x: 0.5, y: 0.5)
        let contacts: [JointName: Point2D] = [
            .leftWrist: Point2D(x: 0.45, y: 0.70),
            .rightWrist: Point2D(x: 0.55, y: 0.70),
            .leftAnkle: Point2D(x: 0.47, y: 0.30),
            .rightAnkle: Point2D(x: 0.53, y: 0.30)
        ]
        let load = LoadEstimator().estimate(com: com, contactPositions: contacts, scale: scale, config: TuningConfig())
        let total = load.fractions.values.reduce(0, +)
        #expect(abs(total - 1.0) < 1e-9)
        // Symmetric contacts share load evenly.
        #expect(abs(load[.leftWrist] - load[.rightWrist]) < 1e-9)

        // Move the COM toward the left hand: that hand takes more.
        let shifted = LoadEstimator().estimate(com: Point2D(x: 0.45, y: 0.65), contactPositions: contacts, scale: scale, config: TuningConfig())
        #expect(shifted[.leftWrist] > shifted[.rightWrist])
        #expect(abs(shifted.fractions.values.reduce(0, +) - 1.0) < 1e-9)
    }

    @Test("No contacts means no load, not a division by zero")
    func emptyLoad() {
        let load = LoadEstimator().estimate(
            com: Point2D(x: 0.5, y: 0.5), contactPositions: [:],
            scale: ClimbScale(iso: .square, torsoLength: 0.1), config: TuningConfig()
        )
        #expect(load.fractions.isEmpty)
        #expect(load.handTotal == 0)
    }

    /// Task 3.10 — COM containment in the base of support.
    @Test("COM inside and outside the base of support")
    func baseOfSupport() {
        let scale = ClimbScale(iso: .square, torsoLength: 0.1)
        let contacts = [
            Point2D(x: 0.40, y: 0.30), Point2D(x: 0.60, y: 0.30),
            Point2D(x: 0.40, y: 0.70), Point2D(x: 0.60, y: 0.70)
        ]
        let inside = BaseOfSupport.compute(loadedContacts: contacts, com: Point2D(x: 0.5, y: 0.5), scale: scale)
        #expect(inside.comInside)
        #expect((inside.comMarginBodyLengths ?? 0) < 0)

        let outside = BaseOfSupport.compute(loadedContacts: contacts, com: Point2D(x: 0.85, y: 0.5), scale: scale)
        #expect(!outside.comInside)
        #expect((outside.comMarginBodyLengths ?? 0) > 0)
        // 0.25 wall units out with a 0.1 torso is 2.5 body-lengths.
        #expect(abs((outside.comMarginBodyLengths ?? 0) - 2.5) < 0.1)
    }

    /// Task 6.0. Fewer than three loaded contacts is not a polygon, so there is
    /// no inside to be outside of — and reporting a margin anyway is what
    /// produced "your centre of mass left the base of support by 1.40
    /// body-lengths" for a climber who was simply hanging off two hands.
    @Test("A degenerate base of support reports no margin at all")
    func degenerateBaseOfSupport() {
        let scale = ClimbScale(iso: .square, torsoLength: 0.1)

        let single = BaseOfSupport.compute(loadedContacts: [Point2D(x: 0.5, y: 0.5)], com: Point2D(x: 0.6, y: 0.5), scale: scale)
        #expect(single.isDegenerate)
        #expect(single.comMarginBodyLengths == nil)

        // Two hands, no feet: a line. The COM hangs below it by construction.
        let hanging = BaseOfSupport.compute(
            loadedContacts: [Point2D(x: 0.45, y: 0.70), Point2D(x: 0.55, y: 0.70)],
            com: Point2D(x: 0.50, y: 0.50), scale: scale
        )
        #expect(hanging.isDegenerate)
        #expect(hanging.comMarginBodyLengths == nil, "hanging is not falling")

        // Three contacts is a real polygon and does report a margin.
        let real = BaseOfSupport.compute(
            loadedContacts: [Point2D(x: 0.4, y: 0.7), Point2D(x: 0.6, y: 0.7), Point2D(x: 0.5, y: 0.3)],
            com: Point2D(x: 0.5, y: 0.5), scale: scale
        )
        #expect(!real.isDegenerate)
        #expect(real.comInside)
    }

    /// Task 3.8 — no kilogram or centimetre value anywhere in the metric layer.
    @Test("No metric is expressed in mass or absolute length")
    func noAbsoluteUnits() {
        let banned = ["kg", "kilogram", "cm", "centimetre", "centimeter", "metre", "meter", "lb", "pound", "inch", "newton"]
        for kind in MetricKind.allCases {
            let unit = kind.unit.lowercased()
            for term in banned {
                // "body-lengths/s" legitimately contains no banned term; this
                // catches anything that starts sneaking one in.
                #expect(!unit.contains(term), "\(kind.rawValue) is expressed in \(kind.unit)")
            }
        }
        // And the same for anything the templates emit.
        #expect(!NumberGuard.forbiddenUnits.isEmpty)
    }

    /// Task 3.7 — the same move by two differently-sized climbers with the same
    /// technique yields near-equal normalized metrics.
    @Test("Body-length normalization makes two sizes comparable")
    func normalizationAcrossSizes() {
        let small = SyntheticClimb.climb(moves: 3)
        var large = small
        // A climber 1.4× larger doing exactly the same thing.
        for i in large.frames.indices {
            for (name, joint) in large.frames[i].joints {
                large.frames[i].joints[name] = Joint(
                    point: Point2D(x: 0.5 + (joint.point.x - 0.5) * 1.4, y: 0.5 + (joint.point.y - 0.5) * 1.4),
                    confidence: joint.confidence
                )
            }
        }
        let config = TuningConfig()
        func measure(_ sequence: PoseSequence) -> Double {
            let scale = ClimbScale(sequence: sequence)
            let contacts = ContactDetector().detect(sequence, scale: scale, config: config).contacts
            let metrics = MetricsEngine().measure(sequence: sequence, contacts: contacts, scale: scale, config: config)
            var path = 0.0
            var previous: Point2D?
            for f in metrics.frames {
                guard let com = f.com else { continue }
                if let p = previous { path += scale.distance(p, com) }
                previous = com
            }
            return path
        }
        let smallPath = measure(small)
        let largePath = measure(large)
        #expect(abs(smallPath - largePath) / max(smallPath, 1e-9) < 0.05,
                "COM path \(smallPath) vs \(largePath) body-lengths")
    }

    @Test("Segment calibration takes the upper tail of observed length")
    func segmentCalibration() {
        let sequence = SyntheticClimb.climb(moves: 3)
        let scale = ClimbScale(sequence: sequence)
        let calibration = SegmentCalibration.calibrate(sequence: sequence, scale: scale, config: TuningConfig())
        let thigh = calibration.length(.leftHip, .leftKnee)
        #expect(thigh != nil)
        // Every observation must be at or below the calibrated length, give or
        // take the percentile's own slack.
        var maxObserved = 0.0
        for f in sequence.frames {
            guard let a = f.joints[.leftHip]?.point, let b = f.joints[.leftKnee]?.point else { continue }
            maxObserved = max(maxObserved, scale.iso.distance(a, b))
        }
        #expect(thigh! <= maxObserved + 1e-9)
        #expect(thigh! > maxObserved * 0.7)
    }

    @Test("Elbow angle and hip twist are measured, not guessed")
    func angles() throws {
        var frame = SyntheticClimb.standingFrame(hipY: 0.5)
        // Straight arm: shoulder, elbow, wrist collinear.
        frame.joints[.leftShoulder] = Joint(point: Point2D(x: 0.45, y: 0.62), confidence: 0.9)
        frame.joints[.leftElbow] = Joint(point: Point2D(x: 0.45, y: 0.52), confidence: 0.9)
        frame.joints[.leftWrist] = Joint(point: Point2D(x: 0.45, y: 0.42), confidence: 0.9)
        let engine = MetricsEngine()
        let scale = ClimbScale(iso: .square, torsoLength: 0.12)
        let straight = try #require(engine.elbowAngle(frame, side: .left, scale: scale))
        #expect(abs(straight - 180) < 1)

        // Bent to a right angle.
        frame.joints[.leftWrist] = Joint(point: Point2D(x: 0.55, y: 0.52), confidence: 0.9)
        let bent = try #require(engine.elbowAngle(frame, side: .left, scale: scale))
        #expect(abs(bent - 90) < 1)

        // Square-on body: shoulders parallel to hips.
        let twist = try #require(engine.hipTwist(SyntheticClimb.standingFrame(), scale: scale))
        #expect(twist < 1)
    }
}

@Suite("Falls")
struct FallTests {

    /// Builds a fall or a dyno: all limbs release, then either nothing (fall)
    /// or a re-contact (dyno).
    func airborneClimb(reContact: Bool, frameRate: Double = 30) -> (ClimbMetrics, [Contact]) {
        var frames: [FrameMetrics] = []
        let scale = ClimbScale(iso: .square, torsoLength: 0.12)
        var y = 0.6
        var velocity = 0.0
        // A body-length is 0.12 wall units, so g ≈ 9.81 m/s² over a ~0.5m torso
        // is about 20 body-lengths/s², or 2.4 wall units/s².
        let g = 20.0 * 0.12
        for i in 0 ..< 90 {
            let t = Double(i) / frameRate
            let onWall = i < 30 || (reContact && i >= 45)
            if !onWall {
                velocity -= g / frameRate
                y += velocity / frameRate
            } else {
                velocity = 0
            }
            frames.append(FrameMetrics(
                index: i, timeSeconds: t,
                com: Point2D(x: 0.5, y: y), comConfidence: 1, comSpeed: abs(velocity),
                load: .none,
                baseOfSupport: .empty,
                hipDepth: .unavailable,
                leftElbowDegrees: 160, rightElbowDegrees: 160, hipTwistDegrees: 5,
                activeContacts: onWall ? [.leftWrist, .rightWrist, .leftAnkle, .rightAnkle] : []
            ))
        }
        let metrics = ClimbMetrics(frames: frames, scale: scale, calibration: SegmentCalibration(lengths: [:], samples: [:], warnings: []), warnings: [])
        return (metrics, [])
    }

    /// Task 3.9 — correct on a fall, and silent on a dyno.
    @Test("A fall is detected and a dyno is not")
    func fallVersusDyno() {
        let config = TuningConfig()
        let (fall, _) = airborneClimb(reContact: false)
        let fallReport = FallDetector().detect(metrics: fall, sections: [], useAttemptRange: true, config: config)
        #expect(fallReport.occurred)
        #expect((fallReport.fallFrame ?? 0) >= 30)

        let (dyno, _) = airborneClimb(reContact: true)
        let dynoReport = FallDetector().detect(metrics: dyno, sections: [], useAttemptRange: true, config: config)
        #expect(!dynoReport.occurred, "a dyno must not read as a fall")
    }

    @Test("A climber who stays on the wall produces no fall")
    func noFall() {
        let sequence = SyntheticClimb.climb(moves: 3)
        let scale = ClimbScale(sequence: sequence)
        let config = TuningConfig()
        let contacts = ContactDetector().detect(sequence, scale: scale, config: config).contacts
        let metrics = MetricsEngine().measure(sequence: sequence, contacts: contacts, scale: scale, config: config)
        let report = FallDetector().detect(metrics: metrics, sections: [], useAttemptRange: true, config: config)
        #expect(!report.occurred)
    }

    /// Task 3.13 — on a climb where a signal appears early and the fall comes
    /// later, the report names the earlier move.
    @Test("Cross-section attribution names the earlier move")
    func distalAttribution() {
        let config = TuningConfig()
        // Straight-arm ratio declines across six moves; the fall is on move 5.
        let sectionMetrics = (0 ..< 6).map { i in
            SectionMetrics(
                sectionIndex: i,
                values: [
                    .straightArmRatio: MetricValue(value: 0.8 - Double(i) * 0.1, confidence: 1),
                    .loadAsymmetry: MetricValue(value: 0.1, confidence: 1),
                    .reachMargin: MetricValue(value: 0.5, confidence: 1)
                ],
                frameCount: 30, durationSeconds: 1
            )
        }
        let report = FallReport(occurred: true, fallFrame: 200, fallSectionIndex: 5, confidence: 0.8, proximateSectionIndex: 5)
        let (metrics, contacts) = airborneClimb(reContact: false)
        let analyzed = FallAnalyzer().analyze(
            report: report, metrics: metrics, sections: [],
            sectionMetrics: sectionMetrics, deltas: [], contacts: contacts, config: config
        )
        #expect(!analyzed.fatigue.isEmpty)
        #expect(analyzed.fatigue.contains { $0.kind == .bentArmAccumulation })
        #expect(analyzed.distalSectionIndex != nil)
        #expect((analyzed.distalSectionIndex ?? 99) < 5, "distal cause should precede the fall")
        // Fatigue signals must be tagged as hypotheses, never as fact.
        #expect(analyzed.fatigue.allSatisfy { $0.status == .fatigueProxy })
        #expect(analyzed.mechanical.allSatisfy { $0.status == .mechanical })
    }
}

@Suite("Footwork")
struct FootworkTests {

    /// Builds one move where the feet are placed and loaded *before* the hand
    /// releases, or after it, and measures the difference.
    func metrics(feetFirst: Bool, config: TuningConfig = TuningConfig()) -> (SectionMetrics, ClimbMetrics) {
        let scale = ClimbScale(iso: .square, torsoLength: 0.12)
        let handRelease = 40
        let footPlaced = feetFirst ? 10 : 60

        var frames: [FrameMetrics] = []
        for i in 0 ..< 100 {
            let footOn = i >= footPlaced
            var fractions: [JointName: Double] = [.leftWrist: 0.5, .rightWrist: 0.5]
            var active: Set<JointName> = [.leftWrist, .rightWrist]
            if footOn {
                active.formUnion([.leftAnkle, .rightAnkle])
                fractions = [.leftWrist: 0.3, .rightWrist: 0.3, .leftAnkle: 0.2, .rightAnkle: 0.2]
            }
            frames.append(FrameMetrics(
                index: i, timeSeconds: Double(i) / 30,
                com: Point2D(x: 0.5, y: 0.5), comConfidence: 1, comSpeed: 0.1,
                load: LimbLoad(fractions: fractions),
                baseOfSupport: .empty, hipDepth: .unavailable,
                leftElbowDegrees: 160, rightElbowDegrees: 160, hipTwistDegrees: 5,
                activeContacts: active
            ))
        }
        let climb = ClimbMetrics(
            frames: frames, scale: scale,
            calibration: SegmentCalibration(lengths: [:], samples: [:], warnings: []), warnings: []
        )
        let contacts = [
            Contact(joint: .leftWrist, startFrame: 0, endFrame: handRelease, position: Point2D(x: 0.45, y: 0.7), confidence: 0.9),
            Contact(joint: .leftAnkle, startFrame: footPlaced, endFrame: 99, position: Point2D(x: 0.47, y: 0.3), confidence: 0.9),
            Contact(joint: .rightAnkle, startFrame: footPlaced, endFrame: 99, position: Point2D(x: 0.53, y: 0.3), confidence: 0.9)
        ]
        let hold = Hold(id: 1, position: Point2D(x: 0.5, y: 0.8), firstUsedBy: .leftWrist, ordinal: 1, contactCount: 1, firstFrame: 0)
        let section = Section(index: 0, fromHold: hold, toHold: hold, referenceRange: 0 ..< 100, attemptRange: 0 ..< 100)
        let result = MetricsEngine().sectionMetrics(
            section: section, range: 0 ..< 100, metrics: climb,
            sequence: SyntheticClimb.climb(moves: 1), contacts: contacts,
            targetHold: hold, config: config
        )
        return (result, climb)
    }

    /// Task 7.4 — a strong climber sets their feet and then moves.
    @Test("Feet set before the reach separates feet-first from hand-first")
    func feetSetBeforeReach() throws {
        let feetFirst = try #require(metrics(feetFirst: true).0[.feetSetBeforeReach].value)
        let handFirst = try #require(metrics(feetFirst: false).0[.feetSetBeforeReach].value)
        #expect(feetFirst > 0.99, "feet were down and loaded before the hand left")
        #expect(handFirst < 0.01, "the hand left before the feet were on")
    }

    /// Task 7.5 — placing a foot and not trusting it currently reads as good
    /// technique, because placement count cannot see hesitation.
    @Test("Foot commitment latency rises when load onto a placed foot is delayed")
    func footCommitment() throws {
        let scale = ClimbScale(iso: .square, torsoLength: 0.12)
        let config = TuningConfig()

        func latency(weightedAt: Int) throws -> Double {
            var frames: [FrameMetrics] = []
            for i in 0 ..< 100 {
                let loaded = i >= weightedAt
                frames.append(FrameMetrics(
                    index: i, timeSeconds: Double(i) / 30,
                    com: Point2D(x: 0.5, y: 0.5), comConfidence: 1, comSpeed: 0.1,
                    load: LimbLoad(fractions: [
                        .leftWrist: loaded ? 0.4 : 0.5,
                        .rightWrist: loaded ? 0.4 : 0.5,
                        .leftAnkle: loaded ? 0.2 : 0.0
                    ]),
                    baseOfSupport: .empty, hipDepth: .unavailable,
                    leftElbowDegrees: 160, rightElbowDegrees: 160, hipTwistDegrees: 5,
                    activeContacts: [.leftWrist, .rightWrist, .leftAnkle]
                ))
            }
            let climb = ClimbMetrics(
                frames: frames, scale: scale,
                calibration: SegmentCalibration(lengths: [:], samples: [:], warnings: []), warnings: []
            )
            let contacts = [Contact(joint: .leftAnkle, startFrame: 10, endFrame: 99, position: Point2D(x: 0.47, y: 0.3), confidence: 0.9)]
            let hold = Hold(id: 1, position: Point2D(x: 0.5, y: 0.8), firstUsedBy: .leftWrist, ordinal: 1, contactCount: 1, firstFrame: 0)
            let section = Section(index: 0, fromHold: hold, toHold: hold, referenceRange: 0 ..< 100, attemptRange: 0 ..< 100)
            let result = MetricsEngine().sectionMetrics(
                section: section, range: 0 ..< 100, metrics: climb,
                sequence: SyntheticClimb.climb(moves: 1), contacts: contacts,
                targetHold: hold, config: config
            )
            return try #require(result[.footCommitmentSeconds].value)
        }

        let prompt = try latency(weightedAt: 12)
        let hesitant = try latency(weightedAt: 70)
        #expect(prompt < 0.2, "weighted almost immediately, got \(prompt)s")
        #expect(hesitant > 1.5, "weighted two seconds later, got \(hesitant)s")
        #expect(hesitant > prompt)
    }

    /// Higher is better for this one, unlike almost every other metric.
    @Test("Setting feet early is scored as the good direction")
    func feetSetDirection() {
        #expect(MetricKind.feetSetBeforeReach.lowerIsBetter == false)
        #expect(MetricKind.footCommitmentSeconds.lowerIsBetter == true)
        let worse = MetricDelta(kind: .feetSetBeforeReach, reference: 0.9, attempt: 0.2, confidence: 1)
        #expect(worse.attemptIsWorse == true)
    }
}
