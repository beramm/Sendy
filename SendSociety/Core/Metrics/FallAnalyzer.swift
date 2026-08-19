import Foundation

/// Whether a signal can be stated as fact or only as a hypothesis. **This split
/// must survive into the UI copy** — a mechanical signal is demonstrable from
/// the geometry; a fatigue proxy is a correlation.
public enum EpistemicStatus: String, Sendable, Codable {
    case mechanical
    case fatigueProxy
}

public struct FallSignal: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case comOutsideBaseOfSupport
        case barnDoor
        case footSlip
        case hipPeel
        case bentArmAccumulation
        case armLoadAccumulation
        case sectionDwellRatio
        case loadAsymmetryTrend
        case reachMarginDecay
    }

    public var id: String { "\(kind.rawValue)-\(sectionIndex)-\(frameIndex ?? -1)" }
    public var kind: Kind
    public var status: EpistemicStatus
    public var sectionIndex: Int
    public var frameIndex: Int?
    /// Plain-language statement of what was measured. Contains only numbers
    /// that were computed here.
    public var detail: String
    public var value: Double?

    public init(kind: Kind, status: EpistemicStatus, sectionIndex: Int, frameIndex: Int?, detail: String, value: Double?) {
        self.kind = kind
        self.status = status
        self.sectionIndex = sectionIndex
        self.frameIndex = frameIndex
        self.detail = detail
        self.value = value
    }
}

public struct FallReport: Sendable, Codable, Hashable {
    public var occurred: Bool
    public var fallFrame: Int?
    public var fallSectionIndex: Int?
    public var confidence: Double
    /// Demonstrable from the geometry. State as fact.
    public var mechanical: [FallSignal]
    /// Correlational. State as hypothesis, never as cause.
    public var fatigue: [FallSignal]
    /// The move the fall happened on.
    public var proximateSectionIndex: Int?
    /// The earliest move where a contributing signal crossed threshold.
    /// Cross-section attribution is the point of the feature, so this is never
    /// omitted when it exists.
    public var distalSectionIndex: Int?
    public var warnings: [String]

    public init(
        occurred: Bool,
        fallFrame: Int? = nil,
        fallSectionIndex: Int? = nil,
        confidence: Double = 0,
        mechanical: [FallSignal] = [],
        fatigue: [FallSignal] = [],
        proximateSectionIndex: Int? = nil,
        distalSectionIndex: Int? = nil,
        warnings: [String] = []
    ) {
        self.occurred = occurred
        self.fallFrame = fallFrame
        self.fallSectionIndex = fallSectionIndex
        self.confidence = confidence
        self.mechanical = mechanical
        self.fatigue = fatigue
        self.proximateSectionIndex = proximateSectionIndex
        self.distalSectionIndex = distalSectionIndex
        self.warnings = warnings
    }

    public static let none = FallReport(occurred: false)
}

/// Fall detection and cause attribution.
///
/// A fall is: all four extremity contacts released, COM vertical acceleration
/// approaching g, sustained, **with no re-contact**. The re-contact clause is
/// the whole difference between a fall and a dyno — a dyno also releases every
/// limb, but it resolves back into contact.
public struct FallDetector: Sendable {

    public init() {}

    public func detect(
        metrics: ClimbMetrics,
        sections: [Section],
        useAttemptRange: Bool,
        config: TuningConfig,
        contacts: [Contact] = []
    ) -> FallReport {
        let frames = metrics.frames
        guard frames.count > 4 else {
            return FallReport(occurred: false, warnings: ["Too few frames to look for a fall."])
        }
        let frameRate = estimatedFrameRate(frames)
        let sustainFrames = max(2, Int((config.fallSustainSeconds * frameRate).rounded()))
        let recontactFrames = max(1, Int((config.fallRecontactWindowSeconds * frameRate).rounded()))

        // **Landing on the mat is not re-contact.**
        //
        // The re-contact clause exists to separate a fall from a dyno, and a
        // dyno resolves back onto *the wall*. A climber who comes off also
        // re-contacts something — the floor — within a few frames, and reading
        // that as "resolved back into contact" throws away every real fall.
        // Measured on `gym-testing/test1`: release at frame 1025, free fall to
        // −33 body-lengths/s², feet down at 1045 at y 0.11, and the whole fall
        // discarded as a dyno.
        //
        // The floor is read from the data the same way `SectionSegmenter` reads
        // it — lowest foot contact plus `groundMargin` — so the two stages
        // cannot disagree about where the ground is.
        let groundJoints = groundContactJoints(contacts: contacts, frameCount: frames.count, scale: metrics.scale, config: config)
        func offTheWall(_ i: Int) -> Bool {
            frames[i].activeContacts.subtracting(groundJoints[i]).isEmpty
        }

        // Vertical acceleration of the COM, body-lengths/s². Downward is
        // negative, so free fall is a large negative number.
        let accel = verticalAcceleration(frames, scale: metrics.scale)

        // A climber walking up to the wall has no contacts and a COM that
        // bobs — real footage has head and tail on it. Nothing before the
        // first contact is part of the climb, so nothing there can be a fall.
        guard let firstContact = frames.indices.first(where: { !offTheWall($0) }) else {
            return FallReport(occurred: false, warnings: ["No contacts at all, so a fall cannot be located."])
        }

        var candidateStart: Int?
        var fallFrame: Int?
        for i in frames.indices where i > firstContact {
            let released = offTheWall(i)
            let falling = (accel[i].map { $0 <= -config.fallAccelThreshold }) ?? false
            if released && falling {
                if candidateStart == nil { candidateStart = i }
                if let start = candidateStart, i - start + 1 >= sustainFrames {
                    // Re-contact inside the window means this was a dyno.
                    let windowEnd = min(frames.count - 1, i + recontactFrames)
                    let reContacted = (i ... windowEnd).contains { !offTheWall($0) }
                    if !reContacted {
                        // Report the frame they came off, not the frame the
                        // acceleration became unambiguous — free fall takes a
                        // few frames to build, and the moment of release is
                        // what a climber recognises on screen.
                        var release = start
                        while release > firstContact, offTheWall(release - 1) { release -= 1 }
                        fallFrame = release
                        break
                    } else {
                        candidateStart = nil
                    }
                }
            } else if !released {
                candidateStart = nil
            }
        }

        guard let fallFrame else {
            return FallReport(occurred: false)
        }

        // The move the fall happened on. A fall at the very last frame of a span
        // sits on its exclusive upper bound and is contained by nothing, and a
        // fall past the last move the attempt reached is contained by nothing
        // either — both used to land on `sections.last`, a move the attempt
        // never climbed, which is a move the results screen cannot show.
        func range(_ s: Section) -> Range<Int> { useAttemptRange ? s.attemptRange : s.referenceRange }
        let sectionIndex = sections.first { range($0).contains(fallFrame) }?.index
            ?? sections.last { !range($0).isEmpty && range($0).lowerBound <= fallFrame }?.index
            ?? sections.first { !range($0).isEmpty }?.index

        // Confidence from how cleanly the signals fired, not a fixed number.
        let accelMagnitude = accel[fallFrame].map { abs($0) / max(config.fallAccelThreshold, 1e-6) } ?? 1
        let confidence = min(1, 0.5 + 0.5 * min(accelMagnitude, 2) / 2)

        return FallReport(
            occurred: true,
            fallFrame: fallFrame,
            fallSectionIndex: sectionIndex,
            confidence: confidence,
            proximateSectionIndex: sectionIndex
        )
    }

    /// Per frame, the joints whose contact is with the **floor** rather than the
    /// wall. Empty at every frame when no contacts are supplied, which leaves
    /// the old behaviour intact for callers that have none.
    public func groundContactJoints(
        contacts: [Contact],
        frameCount: Int,
        scale: ClimbScale,
        config: TuningConfig
    ) -> [Set<JointName>] {
        var out = [Set<JointName>](repeating: [], count: frameCount)
        guard config.groundMargin > 0 else { return out }
        let footContacts = contacts.filter(\.isFoot)
        guard let floor = footContacts.map(\.position.y).min() else { return out }
        let line = floor + config.groundMargin * scale.torsoLength
        for c in contacts where c.position.y <= line {
            let lower = max(0, c.startFrame)
            let upper = min(frameCount - 1, c.endFrame)
            guard lower <= upper else { continue }
            for i in lower ... upper { out[i].insert(c.joint) }
        }
        return out
    }

    public func estimatedFrameRate(_ frames: [FrameMetrics]) -> Double {
        guard frames.count > 1 else { return 30 }
        let span = frames.last!.timeSeconds - frames.first!.timeSeconds
        guard span > 1e-3 else { return 30 }
        return Double(frames.count - 1) / span
    }

    /// Second derivative of COM height in **body-lengths/s²**, which is what
    /// `fallAccelThreshold` is quoted in. Wall units would make the threshold
    /// depend on how far back the tripod stood. `nil` where the COM wasn't
    /// tracked across the window.
    public func verticalAcceleration(_ frames: [FrameMetrics], scale: ClimbScale) -> [Double?] {
        var out = [Double?](repeating: nil, count: frames.count)
        guard frames.count > 2 else { return out }
        for i in 1 ..< (frames.count - 1) {
            guard let a = frames[i - 1].com, let b = frames[i].com, let c = frames[i + 1].com else { continue }
            let dt1 = max(1e-4, frames[i].timeSeconds - frames[i - 1].timeSeconds)
            let dt2 = max(1e-4, frames[i + 1].timeSeconds - frames[i].timeSeconds)
            let v1 = (b.y - a.y) / dt1
            let v2 = (c.y - b.y) / dt2
            out[i] = (v2 - v1) / ((dt1 + dt2) / 2) / scale.torsoLength
        }
        return out
    }
}

/// Turns a detected fall into a report that names both a proximate and a distal
/// cause, and keeps mechanical facts separate from fatigue hypotheses.
public struct FallAnalyzer: Sendable {

    public init() {}

    public func analyze(
        report: FallReport,
        metrics: ClimbMetrics,
        sections: [Section],
        sectionMetrics: [SectionMetrics],
        deltas: [SectionDelta],
        contacts: [Contact],
        config: TuningConfig
    ) -> FallReport {
        var out = report
        var mechanical: [FallSignal] = []
        var fatigue: [FallSignal] = []

        if report.occurred, let fallFrame = report.fallFrame {
            let frameRate = FallDetector().estimatedFrameRate(metrics.frames)
            let windowFrames = max(1, Int((config.proximateWindowSeconds * frameRate).rounded()))
            let start = max(0, fallFrame - windowFrames)
            let sectionOf: (Int) -> Int = { frame in
                sections.first { $0.attemptRange.contains(frame) }?.index ?? report.fallSectionIndex ?? 0
            }

            // COM outside the base of support — the strongest signal available.
            if let exit = (start ..< fallFrame).first(where: { i in
                guard let m = metrics.frame(at: i) else { return false }
                // A degenerate support has no inside, so "the COM left it" is
                // not a claim that can be made. Two hands and no feet is
                // hanging, not falling.
                guard !m.baseOfSupport.isDegenerate else { return false }
                guard let margin = m.baseOfSupport.comMarginBodyLengths else { return false }
                return !m.baseOfSupport.comInside && margin > config.bosMarginBodyLengths
            }) {
                let margin = metrics.frame(at: exit)?.baseOfSupport.comMarginBodyLengths ?? 0
                mechanical.append(FallSignal(
                    kind: .comOutsideBaseOfSupport,
                    status: .mechanical,
                    sectionIndex: sectionOf(exit),
                    frameIndex: exit,
                    detail: String(format: "Your centre of mass left the base of support %.2f body-lengths before you came off, and did not return.", margin),
                    value: margin
                ))
                // Barn-door: the exit is lateral rather than downward.
                if let m = metrics.frame(at: exit), let com = m.com,
                   let centroid = polygonCentroid(m.baseOfSupport.vertices) {
                    let v = metrics.scale.iso.vector(from: centroid, to: com)
                    if abs(v.x) > abs(v.y) * config.barnDoorLateralRatio {
                        mechanical.append(FallSignal(
                            kind: .barnDoor,
                            status: .mechanical,
                            sectionIndex: sectionOf(exit),
                            frameIndex: exit,
                            detail: "The centre of mass left sideways rather than downward — the signature of a barn door.",
                            value: abs(v.x) / metrics.scale.torsoLength
                        ))
                    }
                }
            }

            // Foot slip.
            if let slip = footSlip(metrics: metrics, contacts: contacts, in: start ..< fallFrame, config: config) {
                mechanical.append(FallSignal(
                    kind: .footSlip,
                    status: .mechanical,
                    sectionIndex: sectionOf(slip.frame),
                    frameIndex: slip.frame,
                    detail: String(format: "Your %@ came off downward at %.2f body-lengths/s while your hands were still loaded, with no unweighting first — a slip, not a foot move.", slip.joint == .leftAnkle ? "left foot" : "right foot", slip.speed),
                    value: slip.speed
                ))
            }

            // Hip peel: hip z rising monotonically before release.
            if let peel = hipPeel(metrics: metrics, in: start ..< fallFrame, config: config) {
                mechanical.append(FallSignal(
                    kind: .hipPeel,
                    status: .mechanical,
                    sectionIndex: sectionOf(start),
                    frameIndex: start,
                    detail: String(format: "Your hips moved %.2f body-lengths further from the wall through the last %.1f seconds, transferring load onto your arms.", peel, config.proximateWindowSeconds),
                    value: peel
                ))
            }

            if mechanical.isEmpty {
                out.warnings.append("A fall was detected but no mechanical cause could be identified in the \(Int(config.proximateWindowSeconds))s before it. The tracking may have dropped out.")
            }
        }

        // Fatigue proxies run across the whole climb, fall or no fall — they are
        // trends between sections, not events within one.
        fatigue.append(contentsOf: fatigueTrends(sectionMetrics: sectionMetrics, deltas: deltas, config: config))

        out.mechanical = mechanical
        out.fatigue = fatigue
        // Distal cause: the earliest section where any signal fired, when that
        // is earlier than the fall itself.
        let earliest = (mechanical + fatigue).map(\.sectionIndex).min()
        if let earliest, let proximate = out.proximateSectionIndex, earliest < proximate {
            out.distalSectionIndex = earliest
        }
        return out
    }

    struct Slip { var frame: Int; var joint: JointName; var speed: Double }

    /// Downward ankle velocity spike with hands still loaded and no preceding
    /// unweighting. Unweighting is what separates a slip from a deliberate
    /// foot move, so it is the discriminator, not the speed alone.
    func footSlip(metrics: ClimbMetrics, contacts: [Contact], in range: Range<Int>, config: TuningConfig) -> Slip? {
        let lower = max(1, range.lowerBound + 1)
        let upper = min(range.upperBound, metrics.frames.count)
        guard lower < upper else { return nil }
        for i in lower ..< upper {
            guard let current = metrics.frame(at: i), let previous = metrics.frame(at: i - 1) else { continue }
            for ankle in JointName.feet {
                // The foot was in contact and now is not.
                guard previous.activeContacts.contains(ankle), !current.activeContacts.contains(ankle) else { continue }
                // Hands still loaded.
                guard current.load.handTotal > config.loadedContactFraction else { continue }
                // No unweighting: the foot was carrying load right up to the
                // moment it left.
                guard previous.load[ankle] >= config.loadedContactFraction else { continue }
                let dt = max(1e-4, current.timeSeconds - previous.timeSeconds)
                guard let comNow = current.com, let comBefore = previous.com else { continue }
                let downward = (comBefore.y - comNow.y) / dt / metrics.scale.torsoLength
                if downward >= config.footSlipVelocityThreshold {
                    return Slip(frame: i, joint: ankle, speed: downward)
                }
            }
        }
        return nil
    }

    func hipPeel(metrics: ClimbMetrics, in range: Range<Int>, config: TuningConfig) -> Double? {
        let zs = range.compactMap { metrics.frame(at: $0)?.hipDepth.zBodyLengths }
        guard zs.count >= 4, let first = zs.first, let last = zs.last else { return nil }
        let rise = last - first
        // Require a mostly monotonic rise, not just a higher endpoint.
        let increases = zip(zs, zs.dropFirst()).filter { $1 > $0 }.count
        guard Double(increases) / Double(zs.count - 1) > config.hipPeelMonotonicFraction,
              rise > config.hipPeelMinimumRise else { return nil }
        return rise
    }

    /// Task 3.12. All four are computed **across** sections, never within one.
    func fatigueTrends(sectionMetrics: [SectionMetrics], deltas: [SectionDelta], config: TuningConfig) -> [FallSignal] {
        var out: [FallSignal] = []
        guard sectionMetrics.count >= 3 else { return out }

        func trend(_ kind: MetricKind) -> (slope: Double, firstCrossing: Int)? {
            let points = sectionMetrics.enumerated().compactMap { (i, m) -> (Double, Double)? in
                guard let v = m[kind].value else { return nil }
                return (Double(i), v)
            }
            guard points.count >= 3 else { return nil }
            let slope = linearSlope(points)
            // The section where the value first departs from the opening value
            // by more than the significance threshold.
            let baseline = points[0].1
            let crossing = points.first { abs($0.1 - baseline) > config.deltaSignificanceThreshold }?.0
            return (slope, Int(crossing ?? points[0].0))
        }

        if let t = trend(.straightArmRatio), t.slope < config.bentArmSlopeThreshold {
            out.append(FallSignal(
                kind: .bentArmAccumulation, status: .fatigueProxy, sectionIndex: t.firstCrossing, frameIndex: nil,
                detail: String(format: "Your straight-arm time fell by about %.0f percentage points per move across the climb. This is consistent with tiring, but it is a correlation, not a demonstrated cause.", abs(t.slope) * 100),
                value: t.slope
            ))
        }
        if let t = trend(.armLoadShare), t.slope > config.armLoadSlopeThreshold {
            out.append(FallSignal(
                kind: .armLoadAccumulation, status: .fatigueProxy, sectionIndex: t.firstCrossing, frameIndex: nil,
                detail: "More of your weight went through your arms with each move. Consistent with tiring feet or a growing reluctance to trust them — a correlation, not a demonstrated cause.",
                value: t.slope
            ))
        }
        if let t = trend(.loadAsymmetry), t.slope > config.loadAsymmetrySlopeThreshold {
            out.append(FallSignal(
                kind: .loadAsymmetryTrend, status: .fatigueProxy, sectionIndex: t.firstCrossing, frameIndex: nil,
                detail: String(format: "Left/right load imbalance grew by about %.0f percentage points per move. Possibly favouring one side; not demonstrated.", t.slope * 100),
                value: t.slope
            ))
        }
        if let t = trend(.reachMargin), t.slope > config.reachMarginSlopeThreshold {
            out.append(FallSignal(
                kind: .reachMarginDecay, status: .fatigueProxy, sectionIndex: t.firstCrossing, frameIndex: nil,
                detail: String(format: "You latched each hold from about %.2f body-lengths further out per move as the climb went on. Possibly reaching rather than moving in; not demonstrated.", t.slope),
                value: t.slope
            ))
        }
        let dwells = deltas.compactMap { d -> (Double, Double)? in
            guard let v = d.delta(.sectionDwellRatio)?.attempt else { return nil }
            return (Double(d.sectionIndex), v)
        }
        if dwells.count >= 3 {
            let slope = linearSlope(dwells)
            if slope > config.dwellRatioSlopeThreshold {
                out.append(FallSignal(
                    kind: .sectionDwellRatio, status: .fatigueProxy, sectionIndex: Int(dwells[0].0), frameIndex: nil,
                    detail: String(format: "You spent progressively longer on each move relative to the reference climb, about %.2f× more per move. Possibly slowing down; not demonstrated.", slope),
                    value: slope
                ))
            }
        }
        return out
    }

    func linearSlope(_ points: [(Double, Double)]) -> Double {
        let n = Double(points.count)
        let sumX = points.reduce(0) { $0 + $1.0 }
        let sumY = points.reduce(0) { $0 + $1.1 }
        let sumXY = points.reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = points.reduce(0) { $0 + $1.0 * $1.0 }
        let denominator = n * sumXX - sumX * sumX
        guard abs(denominator) > 1e-9 else { return 0 }
        return (n * sumXY - sumX * sumY) / denominator
    }

    func polygonCentroid(_ points: [Point2D]) -> Point2D? {
        guard !points.isEmpty else { return nil }
        return points.reduce(Point2D.zero, +) / Double(points.count)
    }
}
