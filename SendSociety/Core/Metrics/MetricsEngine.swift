import Foundation

/// Everything measured at one frame. Also the input to the analytical overlays
/// in skeleton-only mode.
public struct FrameMetrics: Sendable, Codable, Hashable {
    public var index: Int
    public var timeSeconds: Double
    public var com: Point2D?
    public var comConfidence: Double
    /// Body-lengths per second.
    public var comSpeed: Double?
    public var load: LimbLoad
    public var baseOfSupport: BaseOfSupport
    public var hipDepth: DepthEstimate
    public var leftElbowDegrees: Double?
    public var rightElbowDegrees: Double?
    public var hipTwistDegrees: Double?
    public var activeContacts: Set<JointName>

    public init(
        index: Int,
        timeSeconds: Double,
        com: Point2D?,
        comConfidence: Double,
        comSpeed: Double?,
        load: LimbLoad,
        baseOfSupport: BaseOfSupport,
        hipDepth: DepthEstimate,
        leftElbowDegrees: Double?,
        rightElbowDegrees: Double?,
        hipTwistDegrees: Double?,
        activeContacts: Set<JointName>
    ) {
        self.index = index
        self.timeSeconds = timeSeconds
        self.com = com
        self.comConfidence = comConfidence
        self.comSpeed = comSpeed
        self.load = load
        self.baseOfSupport = baseOfSupport
        self.hipDepth = hipDepth
        self.leftElbowDegrees = leftElbowDegrees
        self.rightElbowDegrees = rightElbowDegrees
        self.hipTwistDegrees = hipTwistDegrees
        self.activeContacts = activeContacts
    }
}

/// One climber's measured climb.
public struct ClimbMetrics: Sendable, Codable {
    public var frames: [FrameMetrics]
    public var scale: ClimbScale
    public var calibration: SegmentCalibration
    public var warnings: [String]

    public init(frames: [FrameMetrics], scale: ClimbScale, calibration: SegmentCalibration, warnings: [String]) {
        self.frames = frames
        self.scale = scale
        self.calibration = calibration
        self.warnings = warnings
    }

    public func frame(at index: Int) -> FrameMetrics? {
        guard index >= 0, index < frames.count else { return nil }
        return frames[index]
    }
}

/// Deterministic Swift. Every number in this app is produced here or in one of
/// the estimators it calls — never by a language model.
public struct MetricsEngine: Sendable {

    public init() {}

    // MARK: Per-frame

    public func measure(
        sequence: PoseSequence,
        contacts: [Contact],
        scale: ClimbScale,
        config: TuningConfig
    ) -> ClimbMetrics {
        let contactStates = TimeAligner.contactStates(contacts: contacts, frameCount: sequence.count)
        let calibration = SegmentCalibration.calibrate(sequence: sequence, scale: scale, config: config)
        let depths = ForeshorteningDepthEstimator().hipDepthTrack(
            sequence: sequence, contacts: contactStates, scale: scale, config: config
        )
        let comEstimator = COMEstimator()
        let loadEstimator = LoadEstimator()

        var frames: [FrameMetrics] = []
        var previousCOM: Point2D?
        var previousTime: Double?

        for (i, frame) in sequence.frames.enumerated() {
            let comResult = comEstimator.estimate(frame)
            let com = comResult?.point
            let active = i < contactStates.count ? contactStates[i] : []
            let positions = LoadEstimator.activeContacts(contacts, atFrame: i)
            let load = loadEstimator.estimate(com: com, contactPositions: positions, scale: scale, config: config)

            // Only *loaded* contacts span the base of support. A trailing foot
            // resting on the wall with no weight on it does not hold anyone up.
            let loaded = positions.filter { load[$0.key] >= config.loadedContactFraction }.map(\.value)
            let bos = BaseOfSupport.compute(loadedContacts: loaded, com: com, scale: scale)

            var speed: Double?
            if let com, let p = previousCOM, let t = previousTime {
                let dt = max(1e-4, frame.timeSeconds - t)
                speed = scale.distance(p, com) / dt
            }
            if com != nil {
                previousCOM = com
                previousTime = frame.timeSeconds
            }

            frames.append(FrameMetrics(
                index: i,
                timeSeconds: frame.timeSeconds,
                com: com,
                comConfidence: comResult?.confidence ?? 0,
                comSpeed: speed,
                load: load,
                baseOfSupport: bos,
                hipDepth: i < depths.count ? depths[i] : .unavailable,
                leftElbowDegrees: elbowAngle(frame, side: .left, scale: scale),
                rightElbowDegrees: elbowAngle(frame, side: .right, scale: scale),
                hipTwistDegrees: hipTwist(frame, scale: scale),
                activeContacts: active
            ))
        }

        var warnings = calibration.warnings
        let depthAvailable = depths.filter { $0.zBodyLengths != nil }.count
        if depths.isEmpty || depthAvailable < depths.count / 10 {
            warnings.append("Hip depth is unavailable for most of the climb — limbs were too close to wall-parallel for foreshortening to resolve. Lower the depth confidence floor to see the raw estimate.")
        }
        if scale.isEstimated {
            warnings.append("Torso length was never tracked; a fallback body-length was substituted, so every normalized distance is approximate.")
        }
        return ClimbMetrics(frames: frames, scale: scale, calibration: calibration, warnings: warnings)
    }

    enum Side { case left, right }

    func elbowAngle(_ frame: PoseFrame, side: Side, scale: ClimbScale) -> Double? {
        let (shoulder, elbow, wrist): (JointName, JointName, JointName) = side == .left
            ? (.leftShoulder, .leftElbow, .leftWrist)
            : (.rightShoulder, .rightElbow, .rightWrist)
        guard let s = frame.joints[shoulder]?.point,
              let e = frame.joints[elbow]?.point,
              let w = frame.joints[wrist]?.point else { return nil }
        let a = scale.iso.angleDegrees(vertex: e, s, w)
        return a.isNaN ? nil : a
    }

    /// Angle between the shoulder line and the hip line. Flagging and
    /// backstepping show up here.
    func hipTwist(_ frame: PoseFrame, scale: ClimbScale) -> Double? {
        guard let ls = frame.joints[.leftShoulder]?.point,
              let rs = frame.joints[.rightShoulder]?.point,
              let lh = frame.joints[.leftHip]?.point,
              let rh = frame.joints[.rightHip]?.point else { return nil }
        let shoulder = scale.iso.vector(from: ls, to: rs)
        let hip = scale.iso.vector(from: lh, to: rh)
        guard shoulder.length > 1e-9, hip.length > 1e-9 else { return nil }
        let dot = shoulder.x * hip.x + shoulder.y * hip.y
        let c = (dot / (shoulder.length * hip.length)).clamped(to: -1 ... 1)
        let angle = acos(c) * 180 / .pi
        return angle.isNaN ? nil : angle
    }

    // MARK: Per-section

    public func sectionMetrics(
        section: Section,
        range: Range<Int>,
        metrics: ClimbMetrics,
        sequence: PoseSequence,
        contacts: [Contact],
        targetHold: Hold,
        config: TuningConfig
    ) -> SectionMetrics {
        let indices = Array(range).filter { $0 >= 0 && $0 < metrics.frames.count }
        guard !indices.isEmpty else {
            return SectionMetrics(
                sectionIndex: section.index,
                values: Dictionary(uniqueKeysWithValues: MetricKind.allCases.map { ($0, .unavailable) }),
                frameCount: 0,
                durationSeconds: 0,
                warnings: ["No frames in this move."]
            )
        }
        let frames = indices.map { metrics.frames[$0] }
        var values: [MetricKind: MetricValue] = [:]
        var warnings: [String] = []

        // Hip distance from wall.
        let depths = frames.compactMap { $0.hipDepth.zBodyLengths }
        let depthConfidence = frames.map(\.hipDepth.confidence).mean ?? 0
        let coverage = Double(depths.count) / Double(frames.count)
        if let mean = depths.mean, let peak = depths.max(), coverage > config.depthCoverageFloor {
            values[.hipDistanceMean] = MetricValue(value: mean, confidence: depthConfidence * coverage)
            values[.hipDistancePeak] = MetricValue(value: peak, confidence: depthConfidence * coverage)
        } else {
            values[.hipDistanceMean] = .unavailable
            values[.hipDistancePeak] = .unavailable
            warnings.append("Hip depth unavailable on this move — no foot was anchored, or limbs sat too close to the wall plane to resolve.")
        }

        // Straight-arm ratio.
        var straight = 0, armSamples = 0
        for f in frames {
            for angle in [f.leftElbowDegrees, f.rightElbowDegrees].compactMap({ $0 }) {
                armSamples += 1
                if angle >= config.straightArmDegrees { straight += 1 }
            }
        }
        values[.straightArmRatio] = armSamples > 0
            ? MetricValue(value: Double(straight) / Double(armSamples), confidence: min(1, Double(armSamples) / Double(frames.count * 2)))
            : .unavailable

        // COM path length and peak speed.
        var path = 0.0
        var previous: Point2D?
        for f in frames {
            if let com = f.com {
                if let p = previous { path += metrics.scale.distance(p, com) }
                previous = com
            }
        }
        let comCoverage = Double(frames.filter { $0.com != nil }.count) / Double(frames.count)
        values[.comPathLength] = comCoverage > config.comCoverageFloor
            ? MetricValue(value: path, confidence: comCoverage)
            : .unavailable
        let speeds = frames.compactMap(\.comSpeed)
        values[.comPeakVelocity] = speeds.isEmpty
            ? .unavailable
            : MetricValue(value: speeds.max()!, confidence: comCoverage)

        // Arm versus foot load. The most coachable quantity in the whole
        // pipeline: it is the difference between hanging off your arms and
        // standing on your feet. Only frames where the climber is actually on
        // the wall count — an airborne frame has no load to share.
        let onWall = frames.filter { !$0.activeContacts.isEmpty }
        let armShares = onWall.map(\.load.handTotal)
        if let mean = armShares.mean, let peak = armShares.max() {
            let coverage = Double(onWall.count) / Double(frames.count)
            values[.armLoadShare] = MetricValue(value: mean, confidence: comCoverage * coverage)
            values[.armLoadPeak] = MetricValue(value: peak, confidence: comCoverage * coverage)
        } else {
            values[.armLoadShare] = .unavailable
            values[.armLoadPeak] = .unavailable
        }

        // Feet on the wall but not carrying anything. Distinct from having no
        // feet on at all, and the thing a coach means by "use your feet".
        if !onWall.isEmpty {
            let unweighted = onWall.filter { frame in
                let footOn = JointName.feet.filter { frame.activeContacts.contains($0) }
                guard !footOn.isEmpty else { return false }
                return footOn.allSatisfy { frame.load[$0] < config.loadedContactFraction }
            }
            values[.unweightedFootTime] = MetricValue(
                value: Double(unweighted.count) / Double(onWall.count),
                confidence: comCoverage
            )
        } else {
            values[.unweightedFootTime] = .unavailable
        }

        // Task 7.4 — feet set before the reach, or repaired afterwards.
        //
        // A strong climber sets their feet and then moves. A weaker one commits
        // the hand and fixes the feet while already hanging off their arms.
        // Measured at each moment a hand *leaves* a hold: were both feet in
        // contact and bearing load at that instant?
        let handReleases = contacts.filter { $0.isHand && range.contains($0.endFrame) }
        if !handReleases.isEmpty {
            var prepared = 0
            for release in handReleases {
                guard let frame = metrics.frame(at: release.endFrame) else { continue }
                let footOn = JointName.feet.filter { frame.activeContacts.contains($0) }
                let loaded = footOn.filter { frame.load[$0] >= config.loadedContactFraction }
                if loaded.count >= 2 { prepared += 1 }
            }
            values[.feetSetBeforeReach] = MetricValue(
                value: Double(prepared) / Double(handReleases.count),
                confidence: min(1, Double(handReleases.count) / 2)
            )
        } else {
            values[.feetSetBeforeReach] = .unavailable
        }

        // Task 7.5 — how long a placed foot sits there before it takes any
        // weight. Placement count alone cannot see hesitation: placing once and
        // not trusting it reads as good technique.
        let footPlacementsInRange = contacts.filter { $0.isFoot && range.contains($0.startFrame) }
        var latencies: [Double] = []
        for placement in footPlacementsInRange {
            let window = placement.startFrame ... min(placement.endFrame, metrics.frames.count - 1)
            guard window.lowerBound <= window.upperBound else { continue }
            guard let loadedAt = window.first(where: { i in
                (metrics.frame(at: i)?.load[placement.joint] ?? 0) >= config.loadedContactFraction
            }) else {
                // Placed and never weighted at all — the worst case, charged the
                // full length of the contact rather than dropped.
                let start = metrics.frame(at: placement.startFrame)?.timeSeconds
                let end = metrics.frame(at: window.upperBound)?.timeSeconds
                if let start, let end { latencies.append(end - start) }
                continue
            }
            let start = metrics.frame(at: placement.startFrame)?.timeSeconds
            let weighted = metrics.frame(at: loadedAt)?.timeSeconds
            if let start, let weighted { latencies.append(weighted - start) }
        }
        values[.footCommitmentSeconds] = latencies.isEmpty
            ? .unavailable
            : MetricValue(value: latencies.mean!, confidence: min(1, Double(latencies.count) / 2))

        // Load asymmetry.
        let asymmetries = frames.map(\.load.asymmetry).filter { $0 > 0 }
        values[.loadAsymmetry] = asymmetries.isEmpty
            ? .unavailable
            : MetricValue(value: asymmetries.mean!, confidence: comCoverage)

        // Foot placements: foot contacts that *begin* inside this move.
        let placements = contacts.filter { $0.isFoot && range.contains($0.startFrame) }.count
        values[.footPlacementCount] = MetricValue(value: Double(placements), confidence: 1)

        // Hip twist.
        let twists = frames.compactMap(\.hipTwistDegrees)
        values[.hipTwist] = twists.isEmpty
            ? .unavailable
            : MetricValue(value: twists.mean!, confidence: Double(twists.count) / Double(frames.count))

        // Reach margin at the latch: COM-to-target-hold at the last frame.
        if let last = frames.last, let com = last.com {
            values[.reachMargin] = MetricValue(
                value: metrics.scale.distance(com, targetHold.position),
                confidence: last.comConfidence
            )
        } else {
            values[.reachMargin] = .unavailable
        }

        // Dwell is a cross-climber ratio, filled in when the delta is built.
        values[.sectionDwellRatio] = .unavailable

        let duration = (frames.last!.timeSeconds - frames.first!.timeSeconds)
        return SectionMetrics(
            sectionIndex: section.index,
            values: values,
            frameCount: frames.count,
            durationSeconds: duration,
            warnings: warnings
        )
    }

    // MARK: Deltas

    public func delta(
        section: Section,
        reference: SectionMetrics,
        attempt: SectionMetrics?,
        alignmentCost: Double?
    ) -> SectionDelta {
        var deltas: [MetricDelta] = []
        for kind in MetricKind.allCases {
            if kind == .sectionDwellRatio {
                let ratio: Double?
                if let attempt, reference.durationSeconds > 1e-3, attempt.durationSeconds > 0 {
                    ratio = attempt.durationSeconds / reference.durationSeconds
                } else {
                    ratio = nil
                }
                deltas.append(MetricDelta(
                    kind: kind,
                    reference: ratio == nil ? nil : 1.0,
                    attempt: ratio,
                    confidence: ratio == nil ? 0 : 1
                ))
                continue
            }
            let r = reference[kind]
            let a = attempt?[kind] ?? .unavailable
            deltas.append(MetricDelta(
                kind: kind,
                reference: r.value,
                attempt: a.value,
                confidence: min(r.confidence, a.confidence),
                referenceConfidence: r.confidence,
                attemptConfidence: a.confidence
            ))
        }
        return SectionDelta(
            sectionIndex: section.index,
            sectionName: section.displayName,
            deltas: deltas,
            divergence: section.divergence,
            attemptReached: section.attemptReached,
            alignmentCost: alignmentCost,
            warnings: reference.warnings + (attempt?.warnings ?? [])
        )
    }
}
