import Foundation

/// Every quantity the analysis layer can talk about.
///
/// **Code measures, the model narrates.** Nothing outside `MetricsEngine` may
/// produce one of these numbers, and the language model receives them already
/// computed. A model that estimates a quantity is a bug, not a feature.
public enum MetricKind: String, Sendable, Codable, CaseIterable, Hashable {
    case hipDistanceMean
    case hipDistancePeak
    case hipDistanceStart
    case hipDistanceEnd
    case armLoadShare
    case armLoadPeak
    case unweightedFootTime
    case feetSetBeforeReach
    case footCommitmentSeconds
    case straightArmRatio
    case comPathLength
    case comDisplacement
    case comPathEfficiency
    case comPeakVelocity
    case loadAsymmetry
    case footPlacementCount
    case hipTwist
    case reachMargin
    case sectionDwellRatio
    // Posture — added after a coaching review said the app measured effort but
    // not shape. A coach reads the pelvis first, then the knee, then the arm;
    // these are those reads, in that order.
    case pelvisTilt
    case pelvisTiltStart
    case pelvisTiltEnd
    case pelvisTurn
    case pelvisTurnStart
    case pelvisTurnEnd
    case torsoLean
    case torsoLeanStart
    case torsoLeanEnd
    case kneeDrive
    case pullingArmTime
    /// Armpit closed and the hand loaded: the lat is levering the body in.
    case latLoadTime
    /// Elbow bent and the hand loaded: the elbow flexors are holding it.
    case elbowFlexTime
    case diagonalLoadBalance

    public var displayName: String {
        switch self {
        case .hipDistanceMean: "Hip distance from wall (mean)"
        case .hipDistancePeak: "Hip distance from wall (peak)"
        case .hipDistanceStart: "Hip distance from wall (start)"
        case .hipDistanceEnd: "Hip distance from wall (finish)"
        case .armLoadShare: "Weight through the arms"
        case .armLoadPeak: "Weight through the arms (peak)"
        case .unweightedFootTime: "Feet on but unweighted"
        case .feetSetBeforeReach: "Feet set before the reach"
        case .footCommitmentSeconds: "Time to trust a foot"
        case .straightArmRatio: "Straight-arm time"
        case .comPathLength: "Centre-of-mass path length"
        case .comDisplacement: "Centre-of-mass start-to-finish travel"
        case .comPathEfficiency: "Centre-of-mass path directness"
        case .comPeakVelocity: "Peak centre-of-mass speed"
        case .loadAsymmetry: "Left/right load imbalance"
        case .footPlacementCount: "Foot placements"
        case .hipTwist: "Hip twist"
        case .reachMargin: "Reach extension at the latch"
        case .sectionDwellRatio: "Time on this move"
        case .pelvisTilt: "Hips off level"
        case .pelvisTiltStart: "Hips off level (start)"
        case .pelvisTiltEnd: "Hips off level (finish)"
        case .pelvisTurn: "Hips turned into the wall"
        case .pelvisTurnStart: "Hips turned into the wall (start)"
        case .pelvisTurnEnd: "Hips turned into the wall (finish)"
        case .torsoLean: "Lean off the plumb line"
        case .torsoLeanStart: "Lean off the plumb line (start)"
        case .torsoLeanEnd: "Lean off the plumb line (finish)"
        case .kneeDrive: "Knee driven past the toe"
        case .pullingArmTime: "Time pulling on the arms"
        case .latLoadTime: "Time pulling with the back"
        case .elbowFlexTime: "Time on bent, loaded arms"
        case .diagonalLoadBalance: "Diagonal load imbalance"
        }
    }

    /// Unit string. **No kilograms, no centimetres, no metres** — see
    /// `MetricUnitsTests`, which fails the build if one appears.
    public var unit: String {
        switch self {
        case .hipDistanceMean, .hipDistancePeak, .hipDistanceStart, .hipDistanceEnd,
             .comPathLength, .comDisplacement, .reachMargin, .kneeDrive: "body-lengths"
        case .comPeakVelocity: "body-lengths/s"
        case .straightArmRatio, .loadAsymmetry, .armLoadShare, .armLoadPeak,
             .unweightedFootTime, .feetSetBeforeReach, .pullingArmTime,
             .latLoadTime, .elbowFlexTime, .diagonalLoadBalance,
             .comPathEfficiency: "%"
        case .footCommitmentSeconds: "s"
        case .footPlacementCount: "count"
        case .hipTwist, .pelvisTilt, .pelvisTiltStart, .pelvisTiltEnd,
             .pelvisTurn, .pelvisTurnStart, .pelvisTurnEnd,
             .torsoLean, .torsoLeanStart, .torsoLeanEnd: "°"
        case .sectionDwellRatio: "×"
        }
    }

    /// One plain sentence saying what this measurement is, for a climber who
    /// has never read a coaching article.
    ///
    /// `displayName` names the row; this says what the row is for. The
    /// Differences sheet shows it beneath the figures, which is the only place
    /// in the app that explains a metric rather than printing it — Detailed
    /// Analytics is a reference table and assumes you already know.
    ///
    /// Deliberately free of figures and thresholds. It says what was counted,
    /// not what a good value is: a number that is good on a slab is bad on a
    /// steep wall, and this app measures no wall angle.
    public var plainMeaning: String {
        switch self {
        case .hipDistanceMean:
            "How far the hips sat off the wall through the whole span."
        case .hipDistancePeak:
            "The furthest the hips got from the wall at any single moment."
        case .hipDistanceStart:
            "How far the hips were off the wall as the span began."
        case .hipDistanceEnd:
            "How far the hips were off the wall at the end of the span."
        case .armLoadShare:
            "How much of the body weight the arms were holding rather than the feet."
        case .armLoadPeak:
            "The most weight the arms carried at any single moment."
        case .unweightedFootTime:
            "How much of the span the feet were on holds but carrying nothing."
        case .feetSetBeforeReach:
            "How often the feet were already placed before the hand went for the next hold."
        case .footCommitmentSeconds:
            "How long it took to put real weight on a foot after placing it."
        case .straightArmRatio:
            "How much of the span was spent hanging on straight arms rather than bent ones."
        case .comPathLength:
            "How far the body actually travelled to cross this span."
        case .comDisplacement:
            "How far the body ended up from where it started, in a straight line."
        case .comPathEfficiency:
            "How close the body's route was to a straight line from start to finish."
        case .comPeakVelocity:
            "The fastest the body moved at any point — high means a dynamic move."
        case .loadAsymmetry:
            "How unevenly the weight sat between the left and right sides."
        case .footPlacementCount:
            "How many times a foot was moved onto a hold across the span."
        case .hipTwist:
            "How far the hips turned away from square to the wall."
        case .reachMargin:
            "How stretched out the body was at the moment the next hold was caught."
        case .sectionDwellRatio:
            "How long this took, against the other climber's version of the same span."
        case .pelvisTilt:
            "How far one hip sat above the other rather than level."
        case .pelvisTiltStart:
            "How far one hip sat above the other as the span began."
        case .pelvisTiltEnd:
            "How far one hip sat above the other at the end of the span."
        case .pelvisTurn:
            "How far a hip was turned in towards the wall rather than square to it."
        case .pelvisTurnStart:
            "How far a hip was turned in towards the wall as the span began."
        case .pelvisTurnEnd:
            "How far a hip was turned in towards the wall at the end of the span."
        case .torsoLean:
            "How far the upper body hung off vertical."
        case .torsoLeanStart:
            "How far the upper body hung off vertical as the span began."
        case .torsoLeanEnd:
            "How far the upper body hung off vertical at the end of the span."
        case .kneeDrive:
            "How far the knee was driven across, past the foot it was standing on."
        case .pullingArmTime:
            "How much of the span was spent actively pulling — bent arm, loaded, back engaged."
        case .latLoadTime:
            "How much of the span the back and shoulders were levering the body in."
        case .elbowFlexTime:
            "How much of the span was spent on a bent arm with weight on it."
        case .diagonalLoadBalance:
            "How evenly the load was shared across the two opposing hand-and-foot diagonals."
        }
    }

    /// Whether a *lower* attempt value is generally the better technique. Used
    /// only to word a template sentence — never to score a climber.
    public var lowerIsBetter: Bool {
        switch self {
        case .hipDistanceMean, .hipDistancePeak, .hipDistanceStart, .hipDistanceEnd,
             .comPathLength, .loadAsymmetry,
             .footPlacementCount, .reachMargin, .sectionDwellRatio,
             .armLoadShare, .armLoadPeak, .unweightedFootTime,
             .footCommitmentSeconds, .pelvisTilt, .pelvisTiltStart, .pelvisTiltEnd,
             .torsoLean, .torsoLeanStart, .torsoLeanEnd, .pullingArmTime,
             .latLoadTime, .elbowFlexTime, .diagonalLoadBalance: true
        // Setting your feet before you move is the thing you want *more* of.
        case .feetSetBeforeReach: false
        case .straightArmRatio, .comPathEfficiency: false
        case .comPeakVelocity, .comDisplacement, .hipTwist: false
        // Turning a hip in and driving a knee past the toe are what the coach
        // demonstrates *instead* of pulling. More of them is the point.
        case .pelvisTurn, .pelvisTurnStart, .pelvisTurnEnd, .kneeDrive: false
        }
    }

    /// Metrics where a difference is only meaningful in magnitude, not in sign.
    public var isDirectionless: Bool {
        self == .comPeakVelocity || self == .comDisplacement || self == .hipTwist
    }
}

public struct MetricValue: Sendable, Codable, Hashable {
    /// `nil` when the metric could not be computed for this section. Never a
    /// sentinel number.
    public var value: Double?
    /// 0...1. Low confidence suppresses the metric in the UI rather than
    /// dressing a guess up as a measurement.
    public var confidence: Double
    public var note: String?

    public init(value: Double?, confidence: Double, note: String? = nil) {
        self.value = value
        self.confidence = confidence
        self.note = note
    }

    public static let unavailable = MetricValue(value: nil, confidence: 0)
}

public struct SectionMetrics: Sendable, Codable, Hashable {
    public var sectionIndex: Int
    public var values: [MetricKind: MetricValue]
    public var frameCount: Int
    public var durationSeconds: Double
    public var warnings: [String]

    public init(
        sectionIndex: Int,
        values: [MetricKind: MetricValue],
        frameCount: Int,
        durationSeconds: Double,
        warnings: [String] = []
    ) {
        self.sectionIndex = sectionIndex
        self.values = values
        self.frameCount = frameCount
        self.durationSeconds = durationSeconds
        self.warnings = warnings
    }

    public subscript(_ kind: MetricKind) -> MetricValue { values[kind] ?? .unavailable }
}

/// One metric compared across the two climbers.
public struct MetricDelta: Sendable, Codable, Hashable {
    public var kind: MetricKind
    public var reference: Double?
    public var attempt: Double?
    /// `attempt − reference`. `nil` when either side is missing.
    public var delta: Double?
    /// Confidence in the **comparison**: the weaker of the two sides, because a
    /// difference is only as trustworthy as its worse half.
    public var confidence: Double
    /// Confidence in each side on its own. Kept separately because a move where
    /// the two climbers did different things still has a well-measured attempt,
    /// and the climber's own numbers are worth reporting there even though no
    /// comparison is.
    public var referenceConfidence: Double
    public var attemptConfidence: Double

    public init(
        kind: MetricKind,
        reference: Double?,
        attempt: Double?,
        confidence: Double,
        referenceConfidence: Double? = nil,
        attemptConfidence: Double? = nil
    ) {
        self.kind = kind
        self.reference = reference
        self.attempt = attempt
        if let r = reference, let a = attempt {
            self.delta = a - r
        } else {
            self.delta = nil
        }
        self.confidence = confidence
        self.referenceConfidence = referenceConfidence ?? confidence
        self.attemptConfidence = attemptConfidence ?? confidence
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(MetricKind.self, forKey: .kind)
        reference = try c.decodeIfPresent(Double.self, forKey: .reference)
        attempt = try c.decodeIfPresent(Double.self, forKey: .attempt)
        delta = try c.decodeIfPresent(Double.self, forKey: .delta)
        confidence = try c.decode(Double.self, forKey: .confidence)
        referenceConfidence = try c.decodeIfPresent(Double.self, forKey: .referenceConfidence) ?? confidence
        attemptConfidence = try c.decodeIfPresent(Double.self, forKey: .attemptConfidence) ?? confidence
    }

    public var magnitude: Double { delta.map(abs) ?? 0 }

    /// True when the attempt is on the worse side of the reference.
    public var attemptIsWorse: Bool? {
        guard let delta, !kind.isDirectionless else { return nil }
        return kind.lowerIsBetter ? delta > 0 : delta < 0
    }
}

/// How big a difference is, in words rather than figures.
///
/// The copy says "slightly" / "clearly" / "a lot" and the exact number lives in
/// the evidence line. That is not hiding the measurement — it is putting it
/// where a reader can ask for it instead of where they have to wade through it.
public enum Magnitude: String, Sendable, Codable, CaseIterable {
    case negligible
    case slight
    case clear
    case large

    /// Adverb for a comparison: "your hips sat **clearly** further out".
    public var adverb: String {
        switch self {
        case .negligible: ""
        case .slight: "slightly"
        case .clear: "clearly"
        case .large: "a lot"
        }
    }

    public var isWorthReporting: Bool { self != .negligible }
}

/// The struct handed to the analysis layer. **This is the only thing an
/// `AnalysisProvider` ever sees** — no images, no raw pose.
public struct SectionDelta: Sendable, Codable, Hashable {
    public var sectionIndex: Int
    public var sectionName: String
    public var deltas: [MetricDelta]
    /// Set when the attempt did something structurally different here. When
    /// present, metric comparison is suppressed and this is reported instead.
    public var divergence: BetaDivergence?
    public var attemptReached: Bool
    /// Mean DTW cost for the section — high means the two climbers moved
    /// visibly differently, independent of any single metric.
    public var alignmentCost: Double?
    public var warnings: [String]

    public init(
        sectionIndex: Int,
        sectionName: String,
        deltas: [MetricDelta],
        divergence: BetaDivergence?,
        attemptReached: Bool,
        alignmentCost: Double?,
        warnings: [String] = []
    ) {
        self.sectionIndex = sectionIndex
        self.sectionName = sectionName
        self.deltas = deltas
        self.divergence = divergence
        self.attemptReached = attemptReached
        self.alignmentCost = alignmentCost
        self.warnings = warnings
    }

    public func delta(_ kind: MetricKind) -> MetricDelta? { deltas.first { $0.kind == kind } }

    /// Deltas that clear the significance threshold, largest first. What the
    /// template provider ranks and what the model is told to talk about.
    public func significantDeltas(threshold: Double) -> [MetricDelta] {
        deltas
            .filter { $0.delta != nil && $0.confidence > 0 && normalizedMagnitude($0) >= threshold }
            .sorted { normalizedMagnitude($0) > normalizedMagnitude($1) }
    }

    /// Which band a difference falls into, for wording it without a figure.
    public func magnitude(of d: MetricDelta, config: TuningConfig) -> Magnitude {
        guard d.delta != nil, d.confidence > 0 else { return .negligible }
        let m = normalizedMagnitude(d)
        let significance = config.deltaSignificanceThreshold
        if m >= significance * config.largeMagnitudeMultiple { return .large }
        if m >= significance * config.clearMagnitudeMultiple { return .clear }
        if m >= significance { return .slight }
        return .negligible
    }

    /// Puts differently-scaled metrics on one axis so "biggest difference" means
    /// something. Each metric is divided by a typical spread for its own unit.
    func normalizedMagnitude(_ d: MetricDelta) -> Double {
        let scale: Double
        switch d.kind {
        case .hipDistanceMean, .hipDistancePeak, .hipDistanceStart, .hipDistanceEnd,
             .comPathLength, .comDisplacement, .reachMargin: scale = 0.5
        case .comPathEfficiency: scale = 0.3
        case .comPeakVelocity: scale = 2.0
        case .straightArmRatio, .loadAsymmetry: scale = 0.3
        case .armLoadShare, .armLoadPeak: scale = 0.25
        case .unweightedFootTime, .feetSetBeforeReach: scale = 0.4
        case .footCommitmentSeconds: scale = 0.8
        case .footPlacementCount: scale = 3.0
        case .hipTwist: scale = 30.0
        case .sectionDwellRatio: scale = 1.0
        case .pelvisTilt, .pelvisTiltStart, .pelvisTiltEnd,
             .torsoLean, .torsoLeanStart, .torsoLeanEnd: scale = 15.0
        case .pelvisTurn, .pelvisTurnStart, .pelvisTurnEnd: scale = 25.0
        case .kneeDrive: scale = 0.4
        case .pullingArmTime, .latLoadTime, .elbowFlexTime: scale = 0.3
        case .diagonalLoadBalance: scale = 0.25
        }
        return d.magnitude / scale * d.confidence
    }
}
