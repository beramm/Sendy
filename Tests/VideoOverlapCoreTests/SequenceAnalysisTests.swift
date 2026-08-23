import Testing
@testable import VideoOverlapCore

@Suite("Sequence analysis")
struct SequenceAnalysisTests {
    private func sequence(referenceMoves: Range<Int> = 0 ..< 2, attemptMoves: Range<Int> = 0 ..< 2) -> ClimbSequence {
        ClimbSequence(
            index: 0,
            fromAnchorID: 1,
            toAnchorID: 4,
            referenceRange: 0 ..< 60,
            attemptRange: 0 ..< 72,
            referenceMoves: referenceMoves,
            attemptMoves: attemptMoves
        )
    }

    private func delta(index: Int, metrics: [MetricDelta], divergence: BetaDivergence? = nil) -> SectionDelta {
        SectionDelta(
            sectionIndex: index,
            sectionName: "Move \(index + 1)",
            deltas: metrics,
            divergence: divergence,
            attemptReached: true,
            alignmentCost: 0.2
        )
    }

    @Test("Metrics from different moves compose one whole-sequence cause")
    func composesAcrossMoves() {
        // Neither move alone has both halves of the causal rule. The sequence
        // aggregate does, which proves this is not just selecting move prose.
        let moves = [
            delta(index: 0, metrics: [
                MetricDelta(kind: .armLoadShare, reference: 0.30, attempt: 0.82, confidence: 1)
            ]),
            delta(index: 1, metrics: [
                MetricDelta(kind: .hipDistanceMean, reference: 0.20, attempt: 0.78, confidence: 1)
            ])
        ]

        #expect(FindingComposer().compose(moves[0]).first?.because == nil)
        #expect(FindingComposer().compose(moves[1]).first?.because == nil)

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(),
            sectionDeltas: moves,
            fallReport: .none,
            fallAnalysis: nil
        )

        #expect(result.kind == .coaching)
        #expect(result.cause?.contains("hips") == true)
        #expect(Set(result.metrics.map(\.kind)) == Set([.armLoadShare, .hipDistanceMean]))
        #expect(result.sourceSectionIndices == [0, 1])
        #expect(result.sentence.filter { $0 == "." }.count == 1)
    }

    @Test("Move-count differences become a sequence structural finding")
    func reportsSequenceStructure() {
        let moves = [delta(index: 0, metrics: [
            MetricDelta(kind: .hipDistanceMean, reference: 0.30, attempt: 0.30, confidence: 1)
        ])]

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(referenceMoves: 0 ..< 1, attemptMoves: 0 ..< 3),
            sectionDeltas: moves,
            fallReport: .none,
            fallAnalysis: nil
        )

        #expect(result.kind == .structural)
        #expect(result.observation.contains("more moves"))
        #expect(result.cause == nil, "the pipeline must not invent a biomechanical cause for a move-count difference")
    }

    @Test("Different order keeps attempt numbers but suppresses comparison")
    func differentOrderIsNotCompared() {
        let moves = [delta(
            index: 0,
            metrics: [MetricDelta(
                kind: .armLoadShare,
                reference: 0.30,
                attempt: 0.75,
                confidence: 0,
                referenceConfidence: 0.9,
                attemptConfidence: 0.9
            )],
            divergence: BetaDivergence(
                kind: .differentHandOrder,
                detail: "The shared holds were taken in another order."
            )
        )]

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(referenceMoves: 0 ..< 1, attemptMoves: 0 ..< 1),
            sectionDeltas: moves,
            fallReport: .none,
            fallAnalysis: nil
        )

        #expect(result.kind == .structural)
        #expect(result.comparisonIsValid == false)
        #expect(result.metrics.first?.attempt == 0.75)
        #expect(result.metrics.first?.reference == nil)
    }

    @Test("Shared sequence anchors override internal move divergence")
    func anchorBoundedSequenceRemainsComparable() {
        let move = delta(
            index: 0,
            metrics: [MetricDelta(kind: .armLoadShare, reference: 0.30, attempt: 0.75, confidence: 1)],
            divergence: BetaDivergence(
                kind: .skippedHold,
                detail: "The attempt used a different intermediate hold."
            )
        )
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .armLoadShare, reference: 0.30, attempt: 0.75, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(referenceMoves: 0 ..< 1, attemptMoves: 0 ..< 2),
            sectionDeltas: [move],
            sequenceDelta: wholeSequence,
            fallReport: .none,
            fallAnalysis: nil
        )

        #expect(result.comparisonIsValid)
        #expect(result.metrics.first?.reference == 0.30)
        #expect(result.metrics.first?.attempt == 0.75)
    }

    @Test("An open-ended sequence never falls back to a false comparison")
    func openEndedSequenceIsNotCompared() {
        let openEnded = ClimbSequence(
            index: 0,
            fromAnchorID: 1,
            toAnchorID: -1,
            referenceRange: 0 ..< 60,
            attemptRange: 0 ..< 72,
            referenceMoves: 0 ..< 1,
            attemptMoves: 0 ..< 1
        )
        let move = delta(index: 0, metrics: [
            MetricDelta(kind: .armLoadShare, reference: 0.30, attempt: 0.75, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: openEnded,
            sectionDeltas: [move],
            fallReport: .none,
            fallAnalysis: nil
        )

        #expect(!result.comparisonIsValid)
        #expect(result.metrics.first?.reference == nil)
        #expect(result.cause?.contains("two reliably matched") == true)
    }
}
