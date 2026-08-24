import Foundation

/// One side of the selected sequence's shared main difference.
///
/// REF and YOU always receive a pair produced from the same structural event
/// or metric. This prevents two unrelated absolute traits from masquerading as
/// the answer to "what was different here?"
public struct SequenceDifferenceFinding: Sendable, Codable, Hashable {
    public enum Relationship: String, Sendable, Codable, Hashable {
        case because
        /// Two measurements that describe the same visible movement without
        /// claiming that one caused the other.
        case whileContext = "while"
    }

    public var observation: String
    /// A second measured factor is a cause only when `relationship` is
    /// `.because`. `.whileContext` keeps a second visible difference without
    /// pretending it explains the first. Standalone, structural, similar, and
    /// unavailable findings may honestly omit it.
    public var cause: String?
    public var relationship: Relationship
    public var metricKind: MetricKind?
    public var confidence: Double
    public var unavailableReason: String?

    public var isAvailable: Bool { unavailableReason == nil }
    public var text: String {
        guard let cause, !cause.isEmpty else { return observation }
        return "\(observation) \(relationship.rawValue) \(lowercasedFirst(cause))"
    }

    /// One presentation sentence for a specific card identity. Observation
    /// and cause stay separate in the model so the causal contract remains
    /// testable, but the climber reads one continuous coaching thought.
    public func sentence(subject: String, causeSubject: String) -> String {
        if !isAvailable {
            return punctuated(text)
        }

        let lead = "\(subject) \(lowercasedFirst(observation))"
        guard let cause, !cause.isEmpty else { return punctuated(lead) }
        return punctuated("\(lead) \(relationship.rawValue) \(causeSubject) \(lowercasedFirst(cause))")
    }

    public init(
        observation: String,
        cause: String? = nil,
        relationship: Relationship = .because,
        metricKind: MetricKind?,
        confidence: Double,
        unavailableReason: String? = nil
    ) {
        self.observation = observation
        self.cause = cause
        self.relationship = relationship
        self.metricKind = metricKind
        self.confidence = confidence
        self.unavailableReason = unavailableReason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observation = try c.decode(String.self, forKey: .observation)
        cause = try c.decodeIfPresent(String.self, forKey: .cause)
        relationship = try c.decodeIfPresent(Relationship.self, forKey: .relationship) ?? .because
        metricKind = try c.decodeIfPresent(MetricKind.self, forKey: .metricKind)
        confidence = try c.decode(Double.self, forKey: .confidence)
        unavailableReason = try c.decodeIfPresent(String.self, forKey: .unavailableReason)
    }

    public static func unavailable(_ reason: String) -> SequenceDifferenceFinding {
        SequenceDifferenceFinding(
            observation: "Insight unavailable",
            cause: reason,
            metricKind: nil,
            confidence: 0,
            unavailableReason: reason
        )
    }

    private func lowercasedFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.lowercased() + String(value.dropFirst())
    }

    private func punctuated(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
        return trimmed + "."
    }
}

/// Exactly one pipeline-produced result for one comparison sequence.
///
/// `SectionAnalysis` remains detailed per-move pipeline output for provider
/// compatibility and instrumentation. This type is the Results screen's
/// contract: one shared main difference expressed once for REF and once for
/// YOU, plus the comparison state and supporting numbers.
public struct SequenceAnalysis: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case coaching
        case structural
        case fall
        case similar
        case unavailable
    }

    public var sequenceIndex: Int
    public var kind: Kind
    public var observation: String
    public var cause: String?
    /// The headline measurements — the four most divergent, in rank order.
    public var metrics: [MetricDelta]
    /// Everything else that was measured reliably here, ranked, with the
    /// headline four removed. The Results screen keeps this behind a
    /// disclosure: a coach who reads twelve numbers reads none of them, but
    /// hiding measurements that exist is not the same as not taking them.
    public var additionalMetrics: [MetricDelta]
    /// How many metrics were computed for this sequence but never cleared the
    /// confidence floor. Reported so an absent metric is distinguishable from
    /// one that merely ranked low — a silent blank is the failure mode this
    /// project's fail-soft rule exists to prevent.
    public var suppressedMetricCount: Int
    public var comparisonIsValid: Bool
    public var numbersUnavailableReason: String?
    /// Paired summaries of the same main difference. Optional so previously
    /// encoded analyses remain decodable; new pipeline output supplies both.
    public var referenceFinding: SequenceDifferenceFinding?
    public var attemptFinding: SequenceDifferenceFinding?
    /// Move indices whose measurements contributed to this result. This makes
    /// the sequence-level conclusion auditable without exposing all moves in
    /// the Results UI.
    public var sourceSectionIndices: [Int]

    public var id: Int { sequenceIndex }

    public init(
        sequenceIndex: Int,
        kind: Kind,
        observation: String,
        cause: String?,
        metrics: [MetricDelta],
        comparisonIsValid: Bool,
        numbersUnavailableReason: String?,
        sourceSectionIndices: [Int],
        referenceFinding: SequenceDifferenceFinding? = nil,
        attemptFinding: SequenceDifferenceFinding? = nil,
        additionalMetrics: [MetricDelta] = [],
        suppressedMetricCount: Int = 0
    ) {
        self.sequenceIndex = sequenceIndex
        self.kind = kind
        self.observation = observation
        self.cause = cause
        self.metrics = metrics
        self.additionalMetrics = additionalMetrics
        self.suppressedMetricCount = suppressedMetricCount
        self.comparisonIsValid = comparisonIsValid
        self.numbersUnavailableReason = numbersUnavailableReason
        self.sourceSectionIndices = sourceSectionIndices
        self.referenceFinding = referenceFinding
        self.attemptFinding = attemptFinding
    }

    /// Legacy comparative sentence for logs and non-card surfaces. The current
    /// Results main screen uses `referenceFinding` and `attemptFinding`.
    public var sentence: String {
        if let cause, !cause.isEmpty {
            return "\(observation) because \(cause)."
        }
        return "\(observation)."
    }
}

/// Reduces move-level measurements into one honest sequence-level finding.
///
/// The pipeline normally supplies a delta measured directly across both
/// anchor-to-anchor spans. That makes one-versus-three moves comparable as a
/// sequence without pretending their individual moves correspond. Aggregating
/// move deltas remains as a deterministic fallback for callers without direct
/// sequence measurements.
public struct SequenceAnalysisComposer: Sendable {
    public var config: TuningConfig

    public init(config: TuningConfig = TuningConfig()) {
        self.config = config
    }

    public func compose(
        sequence: ClimbSequence,
        sectionDeltas: [SectionDelta],
        sequenceDelta: SectionDelta? = nil,
        fallReport: FallReport,
        fallAnalysis: SectionAnalysis?
    ) -> SequenceAnalysis {
        var result = composeComparison(
            sequence: sequence,
            sectionDeltas: sectionDeltas,
            sequenceDelta: sequenceDelta,
            fallReport: fallReport,
            fallAnalysis: fallAnalysis
        )
        let moveIndices = Array(sequence.referenceMoves)
        let moves = moveIndices.compactMap { index in
            sectionDeltas.first { $0.sectionIndex == index }
        }
        let comparisonMetrics = sequenceDelta.map { reliableComparableMetrics($0.deltas) }
            ?? aggregateComparableMetrics(moves)
        let pair = mainDifference(
            sequence: sequence,
            moveDeltas: moves,
            metrics: comparisonMetrics,
            result: result,
            fallReport: fallReport
        )
        result.referenceFinding = pair.reference
        result.attemptFinding = pair.attempt

        let selectedEvidence = pair.metricKinds.compactMap { kind in
            comparisonMetrics.first(where: { $0.kind == kind })
        }
        result.metrics = Array(unique(selectedEvidence + result.metrics).prefix(4))
        if !result.metrics.isEmpty { result.numbersUnavailableReason = nil }

        // The cap is a presentation decision, not a measurement one. Everything
        // else that was measured reliably is carried through so the Results
        // sheet can offer it, ranked, without recomputing anything.
        let headlineKinds = Set(result.metrics.map(\.kind))
        let pool = unique(comparisonMetrics + aggregateAttemptMetrics(moves))
        result.additionalMetrics = ranked(pool).filter { !headlineKinds.contains($0.kind) }
        result.suppressedMetricCount = suppressedMetricKinds(
            sequenceDelta: sequenceDelta,
            moves: moves
        ).count
        return result
    }

    private func composeComparison(
        sequence: ClimbSequence,
        sectionDeltas: [SectionDelta],
        sequenceDelta: SectionDelta?,
        fallReport: FallReport,
        fallAnalysis: SectionAnalysis?
    ) -> SequenceAnalysis {
        let moveIndices = Array(sequence.referenceMoves)
        let deltas = moveIndices.compactMap { index in
            sectionDeltas.first { $0.sectionIndex == index }
        }

        if let fall = fallResult(
            sequence: sequence,
            moveIndices: moveIndices,
            deltas: deltas,
            report: fallReport,
            analysis: fallAnalysis
        ) {
            return fall
        }

        // A move-level beta difference does not invalidate a complete sequence
        // when both endpoints are shared anchors. Only fall back to the old
        // divergence states when no direct anchor-to-anchor comparison exists.
        if sequenceDelta == nil {
            if let unavailable = unavailableResult(sequence: sequence, deltas: deltas) {
                return unavailable
            }
            let hasTwoSharedAnchors = sequence.fromAnchorID >= 0
                && sequence.toAnchorID >= 0
                && sequence.fromAnchorID != sequence.toAnchorID
            if !hasTwoSharedAnchors {
                return ownNumbersResult(
                    sequence: sequence,
                    observation: "This sequence cannot be compared with the reference",
                    cause: "it is not bounded by the same two reliably matched hand holds in both clips",
                    deltas: deltas
                )
            }
        }

        let aggregateMetrics: [MetricDelta]
        if let sequenceDelta {
            aggregateMetrics = reliableComparableMetrics(sequenceDelta.deltas)
        } else {
            aggregateMetrics = aggregateComparableMetrics(deltas)
        }
        let aggregateDelta = SectionDelta(
            sectionIndex: sequence.index,
            sectionName: sequence.displayName,
            deltas: aggregateMetrics,
            divergence: nil,
            attemptReached: sequence.attemptReached,
            alignmentCost: nil,
            warnings: sequenceDelta?.warnings ?? deltas.flatMap(\.warnings)
        )

        let existingFinding = primaryFinding(in: aggregateDelta)
        if let finding = existingFinding, finding.because != nil {
            return SequenceAnalysis(
                sequenceIndex: sequence.index,
                kind: .coaching,
                observation: sentencePart(finding.claim),
                cause: finding.because.map(causePart),
                metrics: supportingMetrics(primary: finding.metrics, aggregate: aggregateDelta),
                comparisonIsValid: true,
                numbersUnavailableReason: nil,
                sourceSectionIndices: moveIndices
            )
        }

        if let pair = causalMetricPair(in: aggregateDelta) {
            let observation = differencePhrases(for: pair.outcome.kind)
            let cause = differencePhrases(for: pair.cause.kind)
            let attemptHigher = (pair.outcome.delta ?? 0) > 0
            let causeAttemptHigher = (pair.cause.delta ?? 0) > 0
            return SequenceAnalysis(
                sequenceIndex: sequence.index,
                kind: .coaching,
                observation: attemptHigher ? observation.higher : observation.lower,
                cause: causeAttemptHigher ? cause.higher : cause.lower,
                metrics: supportingMetrics(primary: [pair.outcome, pair.cause], aggregate: aggregateDelta),
                comparisonIsValid: true,
                numbersUnavailableReason: nil,
                sourceSectionIndices: moveIndices
            )
        }

        if let finding = existingFinding {
            return SequenceAnalysis(
                sequenceIndex: sequence.index,
                kind: .coaching,
                observation: sentencePart(finding.claim),
                cause: finding.because.map(causePart),
                metrics: supportingMetrics(primary: finding.metrics, aggregate: aggregateDelta),
                comparisonIsValid: true,
                numbersUnavailableReason: nil,
                sourceSectionIndices: moveIndices
            )
        }

        // Move-count differences only exist at sequence level. They are a real
        // structural finding, but no biomechanical cause is claimed unless the
        // aggregate measurements independently license one above.
        if sequence.moveCountDelta > 0 {
            return SequenceAnalysis(
                sequenceIndex: sequence.index,
                kind: .structural,
                observation: "You used more moves to cross this sequence than the reference climber",
                cause: nil,
                metrics: Array(ranked(aggregateMetrics).prefix(4)),
                comparisonIsValid: true,
                numbersUnavailableReason: aggregateMetrics.isEmpty
                    ? "No reliable measurements are available for this structural difference."
                    : nil,
                sourceSectionIndices: moveIndices
            )
        }

        if sequence.moveCountDelta < 0 {
            return SequenceAnalysis(
                sequenceIndex: sequence.index,
                kind: .structural,
                observation: "You crossed this sequence in fewer moves than the reference climber",
                cause: nil,
                metrics: Array(ranked(aggregateMetrics).prefix(4)),
                comparisonIsValid: true,
                numbersUnavailableReason: aggregateMetrics.isEmpty
                    ? "No reliable measurements are available for this structural difference."
                    : nil,
                sourceSectionIndices: moveIndices
            )
        }

        if !aggregateMetrics.isEmpty {
            return SequenceAnalysis(
                sequenceIndex: sequence.index,
                kind: .similar,
                observation: "You climbed this sequence much like the reference",
                cause: "nothing measured here stood out enough to be worth changing",
                metrics: Array(ranked(aggregateMetrics).prefix(4)),
                comparisonIsValid: true,
                numbersUnavailableReason: nil,
                sourceSectionIndices: moveIndices
            )
        }

        return SequenceAnalysis(
            sequenceIndex: sequence.index,
            kind: .unavailable,
            observation: "This sequence could not be measured reliably",
            cause: "the pose tracking did not provide enough confident data for a fair comparison",
            metrics: [],
            comparisonIsValid: false,
            numbersUnavailableReason: "No reliable measurements are available for this sequence.",
            sourceSectionIndices: moveIndices
        )
    }

    // MARK: Priority states

    private func fallResult(
        sequence: ClimbSequence,
        moveIndices: [Int],
        deltas: [SectionDelta],
        report: FallReport,
        analysis: SectionAnalysis?
    ) -> SequenceAnalysis? {
        guard let analysis else { return nil }
        let isFallSequence = report.fallSectionIndex.map(moveIndices.contains) ?? false
        let isCauseSequence = report.distalSectionIndex.map(moveIndices.contains) ?? false
        guard isFallSequence || isCauseSequence else { return nil }

        let sourceIndex = isFallSequence ? report.fallSectionIndex : report.distalSectionIndex
        let sourceDeltas = sourceIndex.map { index in deltas.filter { $0.sectionIndex == index } } ?? []
        let metrics = Array(ranked(aggregateComparableMetrics(sourceDeltas)).prefix(4))

        return SequenceAnalysis(
            sequenceIndex: sequence.index,
            kind: .fall,
            observation: sentencePart(isFallSequence ? analysis.headline : "This is where the fall started"),
            cause: analysis.observations.first.map { causePart($0.text) },
            metrics: metrics,
            comparisonIsValid: true,
            numbersUnavailableReason: metrics.isEmpty
                ? "No reliable comparison metrics support this fall finding."
                : nil,
            sourceSectionIndices: sourceIndex.map { [$0] } ?? moveIndices
        )
    }

    private func unavailableResult(
        sequence: ClimbSequence,
        deltas: [SectionDelta]
    ) -> SequenceAnalysis? {
        if let divergence = deltas.compactMap(\.divergence).first(where: { $0.kind == .differentHandOrder }) {
            return ownNumbersResult(
                sequence: sequence,
                observation: "You climbed this sequence in a different order",
                cause: divergence.detail,
                deltas: deltas
            )
        }

        if deltas.contains(where: { $0.divergence?.kind == .truncated }) {
            return ownNumbersResult(
                sequence: sequence,
                observation: "This is where your go ended",
                cause: "you started this sequence but did not finish it",
                deltas: deltas
            )
        }

        if let divergence = deltas.compactMap(\.divergence).first {
            return ownNumbersResult(
                sequence: sequence,
                observation: "You climbed this sequence differently",
                cause: divergence.detail,
                deltas: deltas
            )
        }

        if !sequence.attemptReached || deltas.contains(where: { !$0.attemptReached }) {
            return SequenceAnalysis(
                sequenceIndex: sequence.index,
                kind: .unavailable,
                observation: "You did not reach this sequence",
                cause: "your go ended before this part of the climb, so there is nothing fair to compare yet",
                metrics: [],
                comparisonIsValid: false,
                numbersUnavailableReason: "No attempt footage or measurements are available for this sequence.",
                sourceSectionIndices: Array(sequence.referenceMoves)
            )
        }

        return nil
    }

    private func ownNumbersResult(
        sequence: ClimbSequence,
        observation: String,
        cause: String,
        deltas: [SectionDelta]
    ) -> SequenceAnalysis {
        let metrics = Array(ranked(aggregateAttemptMetrics(deltas)).prefix(4))
        return SequenceAnalysis(
            sequenceIndex: sequence.index,
            kind: .structural,
            observation: sentencePart(observation),
            cause: causePart(cause),
            metrics: metrics,
            comparisonIsValid: false,
            numbersUnavailableReason: metrics.isEmpty
                ? "The movements are not comparable, and no reliable attempt-only measurements are available."
                : nil,
            sourceSectionIndices: Array(sequence.referenceMoves)
        )
    }

    // MARK: Aggregation

    private func reliableComparableMetrics(_ metrics: [MetricDelta]) -> [MetricDelta] {
        metrics.filter {
            $0.reference != nil
                && $0.attempt != nil
                && $0.confidence >= config.jointConfidenceFloor
        }
    }

    private func aggregateComparableMetrics(_ deltas: [SectionDelta]) -> [MetricDelta] {
        MetricKind.allCases.compactMap { kind in
            let samples = deltas.compactMap { section -> MetricDelta? in
                guard section.divergence == nil,
                      section.attemptReached,
                      let metric = section.delta(kind),
                      metric.reference != nil,
                      metric.attempt != nil,
                      metric.confidence >= config.jointConfidenceFloor
                else { return nil }
                return metric
            }
            guard !samples.isEmpty else { return nil }

            let reference = aggregate(samples, value: \.reference, confidence: \.referenceConfidence, kind: kind)
            let attempt = aggregate(samples, value: \.attempt, confidence: \.attemptConfidence, kind: kind)
            let comparisonConfidence = mean(samples.map(\.confidence))
            return MetricDelta(
                kind: kind,
                reference: reference,
                attempt: attempt,
                confidence: comparisonConfidence,
                referenceConfidence: mean(samples.map(\.referenceConfidence)),
                attemptConfidence: mean(samples.map(\.attemptConfidence))
            )
        }
    }

    private func aggregateAttemptMetrics(_ deltas: [SectionDelta]) -> [MetricDelta] {
        MetricKind.allCases.compactMap { kind in
            let samples = deltas.compactMap { section -> MetricDelta? in
                guard let metric = section.delta(kind),
                      metric.attempt != nil,
                      metric.attemptConfidence >= config.jointConfidenceFloor
                else { return nil }
                return metric
            }
            guard !samples.isEmpty else { return nil }

            let confidence = mean(samples.map(\.attemptConfidence))
            return MetricDelta(
                kind: kind,
                reference: nil,
                attempt: aggregate(samples, value: \.attempt, confidence: \.attemptConfidence, kind: kind),
                confidence: 0,
                referenceConfidence: 0,
                attemptConfidence: confidence
            )
        }
    }

    private struct DifferencePair {
        var reference: SequenceDifferenceFinding
        var attempt: SequenceDifferenceFinding
        /// Observation first, then its cause. Keeping these with the selected
        /// wording prevents Detailed Analytics from showing evidence chosen by
        /// an older, different ranking path.
        var metricKinds: [MetricKind] = []
    }

    private enum CausalDirection {
        case same
        case opposite

        func matches(outcome: Double, cause: Double) -> Bool {
            guard abs(outcome) > 1e-9, abs(cause) > 1e-9 else { return false }
            let sameSign = (outcome > 0) == (cause > 0)
            return self == .same ? sameSign : !sameSign
        }
    }

    private struct CausalMetricRule {
        var outcome: MetricKind
        var cause: MetricKind
        var direction: CausalDirection
    }

    /// The pelvis is the first coaching read because it often explains the
    /// downstream load seen at the arms and feet. It receives priority only
    /// when the difference is clear; slight hip noise must not hide a stronger,
    /// more useful difference elsewhere.
    private var hipPriorityMetrics: Set<MetricKind> {
        [
            .hipDistanceMean, .hipDistancePeak, .hipDistanceStart, .hipDistanceEnd,
            .hipTwist,
            .pelvisTilt, .pelvisTiltStart, .pelvisTiltEnd,
            .pelvisTurn, .pelvisTurnStart, .pelvisTurnEnd
        ]
    }

    /// Relationships the deterministic measurements can support. Body
    /// position and COM rules intentionally come before the older arm/foot
    /// rules so equal-strength evidence is not biased toward the original,
    /// narrower catalog.
    private var causalMetricRules: [CausalMetricRule] {
        [
            // Finish position and reach geometry.
            CausalMetricRule(outcome: .hipDistanceEnd, cause: .pelvisTurnEnd, direction: .opposite),
            CausalMetricRule(outcome: .hipDistanceEnd, cause: .kneeDrive, direction: .opposite),
            CausalMetricRule(outcome: .reachMargin, cause: .hipDistanceEnd, direction: .same),

            // Centre-of-mass travel and movement economy.
            CausalMetricRule(outcome: .comPathEfficiency, cause: .footPlacementCount, direction: .opposite),
            CausalMetricRule(outcome: .comPathLength, cause: .footPlacementCount, direction: .same),
            CausalMetricRule(outcome: .comDisplacement, cause: .comPathEfficiency, direction: .same),
            CausalMetricRule(outcome: .sectionDwellRatio, cause: .comPathLength, direction: .same),
            CausalMetricRule(outcome: .sectionDwellRatio, cause: .comPathEfficiency, direction: .opposite),

            // Balance and pelvis/torso shape.
            CausalMetricRule(outcome: .loadAsymmetry, cause: .torsoLeanEnd, direction: .same),
            CausalMetricRule(outcome: .loadAsymmetry, cause: .pelvisTiltEnd, direction: .same),
            CausalMetricRule(outcome: .pelvisTurnEnd, cause: .kneeDrive, direction: .same),

            // Existing load, footwork, and timing mechanisms.
            CausalMetricRule(outcome: .armLoadShare, cause: .hipDistanceMean, direction: .same),
            CausalMetricRule(outcome: .armLoadShare, cause: .hipDistanceEnd, direction: .same),
            CausalMetricRule(outcome: .armLoadShare, cause: .unweightedFootTime, direction: .same),
            CausalMetricRule(outcome: .armLoadShare, cause: .feetSetBeforeReach, direction: .opposite),
            CausalMetricRule(outcome: .sectionDwellRatio, cause: .footCommitmentSeconds, direction: .same),
            CausalMetricRule(outcome: .armLoadShare, cause: .reachMargin, direction: .same),
            CausalMetricRule(outcome: .armLoadShare, cause: .straightArmRatio, direction: .opposite),

            // Prefer an independently measured hip explanation for loaded
            // upper-body effort. Arm load remains a fallback cause when the
            // hips do not differ clearly enough to support one of these.
            CausalMetricRule(outcome: .latLoadTime, cause: .hipDistanceMean, direction: .same),
            CausalMetricRule(outcome: .latLoadTime, cause: .pelvisTurn, direction: .opposite),
            CausalMetricRule(outcome: .elbowFlexTime, cause: .hipDistanceMean, direction: .same),
            CausalMetricRule(outcome: .elbowFlexTime, cause: .pelvisTurn, direction: .opposite),
            CausalMetricRule(outcome: .latLoadTime, cause: .armLoadShare, direction: .same),
            CausalMetricRule(outcome: .elbowFlexTime, cause: .armLoadShare, direction: .same),
            CausalMetricRule(outcome: .pullingArmTime, cause: .pelvisTurn, direction: .opposite),
            CausalMetricRule(outcome: .pullingArmTime, cause: .pelvisTurnEnd, direction: .opposite),
            CausalMetricRule(outcome: .loadAsymmetry, cause: .torsoLean, direction: .same),
            CausalMetricRule(outcome: .armLoadShare, cause: .pelvisTilt, direction: .same)
        ]
    }

    private func causalMetricPair(
        in delta: SectionDelta
    ) -> (outcome: MetricDelta, cause: MetricDelta)? {
        let significant = delta.significantDeltas(threshold: config.deltaSignificanceThreshold)
        let byKind = Dictionary(uniqueKeysWithValues: significant.map { ($0.kind, $0) })
        var bestHip: (outcome: MetricDelta, cause: MetricDelta, score: Double)?
        var bestOther: (outcome: MetricDelta, cause: MetricDelta, score: Double)?
        let clearThreshold = config.deltaSignificanceThreshold * config.clearMagnitudeMultiple

        for rule in causalMetricRules {
            guard let outcome = byKind[rule.outcome],
                  let cause = byKind[rule.cause],
                  let outcomeDelta = outcome.delta,
                  let causeDelta = cause.delta,
                  rule.direction.matches(outcome: outcomeDelta, cause: causeDelta)
            else { continue }

            // The weaker half limits the claim. A huge observation paired with
            // a barely visible cause should lose to two mutually clear reads.
            let score = min(
                delta.normalizedMagnitude(outcome),
                delta.normalizedMagnitude(cause)
            )
            let candidate = (outcome, cause, score)
            let isClearHipRead = score >= clearThreshold
                && (hipPriorityMetrics.contains(rule.outcome) || hipPriorityMetrics.contains(rule.cause))
            if isClearHipRead {
                if bestHip == nil || score > bestHip!.score {
                    bestHip = candidate
                }
            } else if bestOther == nil || score > bestOther!.score {
                bestOther = candidate
            }
        }
        let selected = bestHip ?? bestOther
        return selected.map { ($0.outcome, $0.cause) }
    }

    /// Chooses one shared answer to "what was most different in this
    /// sequence?" Fall and non-comparable states take priority. Move-count
    /// differences remain visible in the sequence strip but never become the
    /// insight because they do not explain why the movement differed. A
    /// validated two-metric relationship is preferred; if the pipeline can
    /// measure a difference but cannot license causality, Results reports the
    /// strongest contrast as context instead of showing a false data gap.
    private func mainDifference(
        sequence: ClimbSequence,
        moveDeltas: [SectionDelta],
        metrics: [MetricDelta],
        result: SequenceAnalysis,
        fallReport: FallReport
    ) -> DifferencePair {
        if result.kind == .fall {
            let fallIsHere = fallReport.fallSectionIndex.map(sequence.referenceMoves.contains) ?? false
            return paired(
                reference: "Stayed on through this sequence",
                attempt: fallIsHere ? "Fell during this sequence" : "This is where the fall started"
            )
        }

        if !result.comparisonIsValid {
            if !sequence.attemptReached
                || moveDeltas.contains(where: { !$0.attemptReached || $0.divergence?.kind == .truncated }) {
                return paired(
                    reference: "Completed this sequence",
                    attempt: "Did not complete this sequence"
                )
            }
            if moveDeltas.contains(where: { $0.divergence?.kind == .differentHandOrder }) {
                return paired(
                    reference: "Used the reference hold order",
                    attempt: "Used a different hold order"
                )
            }
            if moveDeltas.contains(where: { $0.divergence != nil }) {
                return paired(
                    reference: "Used the reference movement",
                    attempt: "Used a different movement"
                )
            }
            let reason = result.numbersUnavailableReason
                ?? "The sequence does not have two reliable shared anchors for comparison."
            return DifferencePair(reference: .unavailable(reason), attempt: .unavailable(reason))
        }

        let delta = SectionDelta(
            sectionIndex: sequence.index,
            sectionName: sequence.displayName,
            deltas: metrics,
            divergence: nil,
            attemptReached: sequence.attemptReached,
            alignmentCost: nil
        )
        if metrics.isEmpty {
            let reason = result.numbersUnavailableReason
                ?? "No reliable measurements are available for this sequence."
            return DifferencePair(reference: .unavailable(reason), attempt: .unavailable(reason))
        }

        if let pair = causalMetricPair(in: delta) {
            return metricDifference(pair.outcome, causeMetric: pair.cause)
        }

        let significant = delta.significantDeltas(
            threshold: config.deltaSignificanceThreshold
        )
        if significant.count >= 2 {
            return metricDifference(
                significant[0],
                causeMetric: significant[1],
                relationship: .whileContext
            )
        }
        if let only = significant.first {
            return metricDifference(only, causeMetric: nil)
        }

        return paired(
            reference: "Matched the other climber closely across the measured body positions",
            attempt: "Matched the reference closely across the measured body positions"
        )
    }

    private func metricDifference(
        _ metric: MetricDelta,
        causeMetric: MetricDelta?,
        relationship: SequenceDifferenceFinding.Relationship = .because
    ) -> DifferencePair {
        guard let referenceValue = metric.reference, let attemptValue = metric.attempt else {
            let reason = "The main difference is missing one climber's measurement."
            return DifferencePair(reference: .unavailable(reason), attempt: .unavailable(reason))
        }

        let phrases = differencePhrases(for: metric.kind)
        let referenceIsHigher = referenceValue > attemptValue
        let causes = causeMetric.flatMap(causePhrases)
        return DifferencePair(
            reference: SequenceDifferenceFinding(
                observation: referenceIsHigher ? phrases.higher : phrases.lower,
                cause: causes.map { $0.reference },
                relationship: relationship,
                metricKind: metric.kind,
                confidence: metric.confidence
            ),
            attempt: SequenceDifferenceFinding(
                observation: referenceIsHigher ? phrases.lower : phrases.higher,
                cause: causes.map { $0.attempt },
                relationship: relationship,
                metricKind: metric.kind,
                confidence: metric.confidence
            ),
            metricKinds: [metric.kind] + (causeMetric.map { [$0.kind] } ?? [])
        )
    }

    private func paired(
        reference: String,
        attempt: String,
        referenceCause: String? = nil,
        attemptCause: String? = nil
    ) -> DifferencePair {
        DifferencePair(
            reference: SequenceDifferenceFinding(
                observation: reference,
                cause: referenceCause,
                metricKind: nil,
                confidence: 1
            ),
            attempt: SequenceDifferenceFinding(
                observation: attempt,
                cause: attemptCause,
                metricKind: nil,
                confidence: 1
            )
        )
    }

    private func causePhrases(
        _ metric: MetricDelta
    ) -> (reference: String, attempt: String)? {
        guard let referenceValue = metric.reference, let attemptValue = metric.attempt else {
            return nil
        }
        let phrases = differencePhrases(for: metric.kind)
        return referenceValue > attemptValue
            ? (phrases.higher, phrases.lower)
            : (phrases.lower, phrases.higher)
    }

    private func differencePhrases(for kind: MetricKind) -> (higher: String, lower: String) {
        switch kind {
        case .hipDistanceMean, .hipDistancePeak:
            ("Stayed farther from the wall", "Stayed closer to the wall")
        case .hipDistanceStart:
            ("Started farther from the wall", "Started closer to the wall")
        case .hipDistanceEnd:
            ("Finished farther from the wall", "Finished closer to the wall")
        case .armLoadShare, .armLoadPeak:
            ("Put more weight through the arms", "Kept more weight off the arms")
        case .unweightedFootTime:
            ("Left the feet unweighted longer", "Kept more weight through the feet")
        case .feetSetBeforeReach:
            ("Set feet before reaching more often", "Reached before the feet were set more often")
        case .footCommitmentSeconds:
            ("Took longer to trust the feet", "Committed to the feet sooner")
        case .straightArmRatio:
            ("Used straighter arms", "Climbed with more bent arms")
        case .comPathLength:
            ("Took a longer movement path", "Moved more directly")
        case .comDisplacement:
            ("Made more start-to-finish body progress", "Made less start-to-finish body progress")
        case .comPathEfficiency:
            ("Took a more direct body path", "Took a less direct body path")
        case .comPeakVelocity:
            ("Moved more dynamically", "Moved more statically")
        case .loadAsymmetry:
            ("Distributed load less evenly", "Distributed load more evenly")
        case .footPlacementCount:
            ("Used more foot placements", "Used fewer foot placements")
        case .hipTwist:
            ("Rotated the hips more", "Rotated the hips less")
        case .reachMargin:
            ("Reached from farther away", "Moved closer before reaching")
        case .sectionDwellRatio:
            ("Took longer", "Moved through faster")
        case .pelvisTilt:
            ("Climbed with more hip tilt", "Kept the hips more level")
        case .pelvisTiltStart:
            ("Started with more hip tilt", "Started with more level hips")
        case .pelvisTiltEnd:
            ("Finished with more hip tilt", "Finished with more level hips")
        case .pelvisTurn:
            ("Turned the hips more into the wall", "Stayed squarer to the wall")
        case .pelvisTurnStart:
            ("Started with the hips more turned into the wall", "Started squarer to the wall")
        case .pelvisTurnEnd:
            ("Finished with the hips more turned into the wall", "Finished squarer to the wall")
        case .torsoLean:
            ("Leaned farther off vertical", "Stayed more centered")
        case .torsoLeanStart:
            ("Started farther off vertical", "Started more centered")
        case .torsoLeanEnd:
            ("Finished farther off vertical", "Finished more centered")
        case .kneeDrive:
            ("Used more knee drive", "Used less knee drive")
        case .pullingArmTime:
            ("Pulled longer with the arms", "Relied less on the arms")
        case .latLoadTime:
            ("Pulled in with the back and shoulders longer", "Relied less on the back and shoulders")
        case .elbowFlexTime:
            ("Held bent, loaded arms longer", "Spent less time on bent, loaded arms")
        case .diagonalLoadBalance:
            ("Loaded the diagonals less evenly", "Loaded the diagonals more evenly")
        }
    }

    private func aggregate(
        _ samples: [MetricDelta],
        value: KeyPath<MetricDelta, Double?>,
        confidence: KeyPath<MetricDelta, Double>,
        kind: MetricKind
    ) -> Double? {
        let values = samples.compactMap { sample -> (Double, Double)? in
            guard let value = sample[keyPath: value] else { return nil }
            return (value, sample[keyPath: confidence])
        }
        guard !values.isEmpty else { return nil }

        if kind.isSequenceAdditive {
            return values.reduce(0) { $0 + $1.0 }
        }

        let weight = values.reduce(0) { $0 + $1.1 }
        guard weight > 0 else { return mean(values.map(\.0)) }
        return values.reduce(0) { $0 + $1.0 * $1.1 } / weight
    }

    private func primaryFinding(in delta: SectionDelta) -> Finding? {
        let findings = FindingComposer(config: config).compose(delta)
        let candidates = findings.contains(where: { $0.because != nil })
            ? findings.filter { $0.because != nil }
            : findings
        return candidates.max { lhs, rhs in
            findingScore(lhs, in: delta) < findingScore(rhs, in: delta)
        }
    }

    private func findingScore(_ finding: Finding, in delta: SectionDelta) -> Double {
        finding.metrics.map(delta.normalizedMagnitude).max() ?? 0
    }

    private func supportingMetrics(primary: [MetricDelta], aggregate: SectionDelta) -> [MetricDelta] {
        let extra = aggregate.significantDeltas(threshold: config.deltaSignificanceThreshold)
        return Array(unique(primary + extra).prefix(4))
    }

    private func ranked(_ metrics: [MetricDelta]) -> [MetricDelta] {
        let delta = SectionDelta(
            sectionIndex: 0,
            sectionName: "Sequence",
            deltas: metrics,
            divergence: nil,
            attemptReached: true,
            alignmentCost: nil
        )
        return metrics.sorted {
            let lhs = $0.delta == nil ? $0.attemptConfidence : delta.normalizedMagnitude($0)
            let rhs = $1.delta == nil ? $1.attemptConfidence : delta.normalizedMagnitude($1)
            return lhs > rhs
        }
    }

    /// Metrics this sequence produced a value for that never cleared the
    /// confidence floor, so they were dropped before ranking.
    ///
    /// Counted per *kind*, not per sample: a metric that was unreliable in
    /// every move is one missing measurement from the reader's point of view,
    /// not seven.
    private func suppressedMetricKinds(
        sequenceDelta: SectionDelta?,
        moves: [SectionDelta]
    ) -> Set<MetricKind> {
        let sources = sequenceDelta.map { [$0] } ?? moves
        var measured: Set<MetricKind> = []
        var reliable: Set<MetricKind> = []
        for section in sources {
            for metric in section.deltas where metric.attempt != nil || metric.reference != nil {
                measured.insert(metric.kind)
                if metric.confidence >= config.jointConfidenceFloor
                    || metric.attemptConfidence >= config.jointConfidenceFloor {
                    reliable.insert(metric.kind)
                }
            }
        }
        return measured.subtracting(reliable)
    }

    private func unique(_ metrics: [MetricDelta]) -> [MetricDelta] {
        var seen: Set<MetricKind> = []
        return metrics.filter { seen.insert($0.kind).inserted }
    }

    private func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func sentencePart(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
    }

    private func causePart(_ text: String) -> String {
        let part = sentencePart(text)
        guard let first = part.first else { return part }
        return first.lowercased() + String(part.dropFirst())
    }
}

private extension MetricKind {
    /// Values whose sequence meaning is a total rather than a typical level.
    var isSequenceAdditive: Bool {
        self == .comPathLength || self == .comDisplacement || self == .footPlacementCount
    }
}
