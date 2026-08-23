import Foundation

/// Exactly one pipeline-produced result for one comparison sequence.
///
/// `SectionAnalysis` remains detailed per-move pipeline output for provider
/// compatibility and instrumentation. This type is the Results screen's
/// contract: one primary observation for the whole anchor-to-anchor sequence,
/// an optional measured cause, and only the supporting numbers.
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
    public var metrics: [MetricDelta]
    public var comparisonIsValid: Bool
    public var numbersUnavailableReason: String?
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
        sourceSectionIndices: [Int]
    ) {
        self.sequenceIndex = sequenceIndex
        self.kind = kind
        self.observation = observation
        self.cause = cause
        self.metrics = metrics
        self.comparisonIsValid = comparisonIsValid
        self.numbersUnavailableReason = numbersUnavailableReason
        self.sourceSectionIndices = sourceSectionIndices
    }

    /// One grammatical sentence for non-styled surfaces. `ResultsView`
    /// renders the same parts separately so only the cause receives the accent.
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

        if let finding = primaryFinding(in: aggregateDelta) {
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
        self == .comPathLength || self == .footPlacementCount
    }
}
