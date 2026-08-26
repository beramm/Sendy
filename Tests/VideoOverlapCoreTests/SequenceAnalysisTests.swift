import Testing
import Foundation
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

    @Test("Move-count differences stay out of the insight when a causal finding exists")
    func moveCountIsNotTheInsight() {
        let moves = [delta(index: 0, metrics: [
            MetricDelta(kind: .armLoadShare, reference: 0.25, attempt: 0.80, confidence: 1),
            MetricDelta(kind: .hipDistanceMean, reference: 0.18, attempt: 0.70, confidence: 1)
        ])]

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(referenceMoves: 0 ..< 1, attemptMoves: 0 ..< 3),
            sectionDeltas: moves,
            fallReport: .none,
            fallAnalysis: nil
        )

        #expect(result.referenceFinding?.observation == "Kept more weight off the arms")
        #expect(result.referenceFinding?.cause == "Stayed closer to the wall")
        #expect(result.attemptFinding?.observation == "Put more weight through the arms")
        #expect(result.attemptFinding?.cause == "Stayed farther from the wall")
        #expect(result.referenceFinding?.text.contains("moves") == false)
        #expect(result.attemptFinding?.text.contains("moves") == false)
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
        #expect(result.referenceFinding?.text == "Used the reference hold order")
        #expect(result.attemptFinding?.text == "Used a different hold order")
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

    @Test("Reference and attempt describe both sides of one causal main difference")
    func pairedMainDifference() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(
                kind: .pullingArmTime,
                reference: 0.08,
                attempt: 0.72,
                confidence: 0.9,
                referenceConfidence: 0.9,
                attemptConfidence: 0.9
            ),
            MetricDelta(
                kind: .pelvisTurn,
                reference: 32,
                attempt: 5,
                confidence: 0.9,
                referenceConfidence: 0.9,
                attemptConfidence: 0.9
            )
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(),
            sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence,
            fallReport: .none,
            fallAnalysis: nil
        )

        #expect(result.referenceFinding?.observation == "Relied less on the arms")
        #expect(result.referenceFinding?.cause == "Turned the hips more into the wall")
        #expect(result.referenceFinding?.metricKind == .pullingArmTime)
        #expect(result.attemptFinding?.observation == "Pulled longer with the arms")
        #expect(result.attemptFinding?.cause == "Stayed squarer to the wall")
        #expect(result.attemptFinding?.metricKind == .pullingArmTime)
        #expect(result.referenceFinding?.sentence(
            subject: "The reference",
            causeSubject: "they"
        ) == "The reference relied less on the arms because they turned the hips more into the wall.")
        #expect(result.attemptFinding?.sentence(
            subject: "You",
            causeSubject: "you"
        ) == "You pulled longer with the arms because you stayed squarer to the wall.")
    }

    @Test("A licensed cause is expressed from both sides of the main difference")
    func pairedObservationAndCause() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .armLoadShare, reference: 0.25, attempt: 0.80, confidence: 1),
            MetricDelta(kind: .hipDistanceMean, reference: 0.18, attempt: 0.70, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(),
            sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence,
            fallReport: .none,
            fallAnalysis: nil
        )

        #expect(result.referenceFinding?.observation == "Kept more weight off the arms")
        #expect(result.referenceFinding?.cause == "Stayed closer to the wall")
        #expect(result.attemptFinding?.observation == "Put more weight through the arms")
        #expect(result.attemptFinding?.cause == "Stayed farther from the wall")
        #expect(result.referenceFinding?.metricKind == .armLoadShare)
        #expect(result.attemptFinding?.metricKind == .armLoadShare)
    }

    @Test("Straight-arm use is the cause of lower arm load, not the outcome")
    func straightArmsCauseLowerArmLoad() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .armLoadShare, reference: 0.25, attempt: 0.78, confidence: 1),
            MetricDelta(kind: .straightArmRatio, reference: 0.82, attempt: 0.20, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(),
            sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence,
            fallReport: .none,
            fallAnalysis: nil
        )

        #expect(result.referenceFinding?.sentence(
            subject: "The reference",
            causeSubject: "they"
        ) == "The reference kept more weight off the arms because they used straighter arms.")
        #expect(result.attemptFinding?.sentence(
            subject: "You",
            causeSubject: "you"
        ) == "You put more weight through the arms because you climbed with more bent arms.")
    }

    @Test("A lone reliable difference remains an honest observation")
    func standaloneDifferenceIsStillVisible() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .sectionDwellRatio, reference: 1.0, attempt: 1.60, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(),
            sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence,
            fallReport: .none,
            fallAnalysis: nil
        )

        #expect(result.referenceFinding?.isAvailable == true)
        #expect(result.attemptFinding?.isAvailable == true)
        #expect(result.referenceFinding?.metricKind == .sectionDwellRatio)
        #expect(result.attemptFinding?.metricKind == .sectionDwellRatio)
        #expect(result.referenceFinding?.cause == nil)
        #expect(result.attemptFinding?.cause == nil)
        #expect(result.referenceFinding?.sentence(subject: "The reference", causeSubject: "they") == "The reference moved through faster.")
        #expect(result.attemptFinding?.sentence(subject: "You", causeSubject: "you") == "You took longer.")
        #expect(result.metrics.first?.kind == .sectionDwellRatio)
    }

    @Test("Differences below significance produce a measured-similarity insight")
    func insignificantDifference() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .hipDistanceMean, reference: 0.30, attempt: 0.31, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(),
            sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence,
            fallReport: .none,
            fallAnalysis: nil
        )

        #expect(result.referenceFinding?.observation.contains("Matched") == true)
        #expect(result.attemptFinding?.observation.contains("Matched") == true)
        #expect(result.referenceFinding?.metricKind == nil)
        #expect(result.attemptFinding?.metricKind == nil)
        #expect(result.referenceFinding?.isAvailable == true)
        #expect(result.attemptFinding?.isAvailable == true)
    }

    @Test("Hip finish position can be explained by finish pelvis turn")
    func hipPlacementInsight() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .hipDistanceEnd, reference: 0.18, attempt: 0.76, confidence: 1),
            MetricDelta(kind: .pelvisTurnEnd, reference: 38, attempt: 6, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(), sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence, fallReport: .none, fallAnalysis: nil
        )

        #expect(result.referenceFinding?.sentence(
            subject: "The reference", causeSubject: "they"
        ) == "The reference finished closer to the wall because they finished with the hips more turned into the wall.")
        #expect(result.attemptFinding?.sentence(
            subject: "You", causeSubject: "you"
        ) == "You finished farther from the wall because you finished squarer to the wall.")
        #expect(result.referenceFinding?.metricKind == .hipDistanceEnd)
    }

    @Test("Centre-of-mass directness can be explained by foot placements")
    func centerOfMassInsight() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .comPathEfficiency, reference: 0.86, attempt: 0.31, confidence: 1),
            MetricDelta(kind: .footPlacementCount, reference: 1, attempt: 5, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(), sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence, fallReport: .none, fallAnalysis: nil
        )

        #expect(result.referenceFinding?.sentence(
            subject: "The reference", causeSubject: "they"
        ) == "The reference took a more direct body path because they used fewer foot placements.")
        #expect(result.attemptFinding?.sentence(
            subject: "You", causeSubject: "you"
        ) == "You took a less direct body path because you used more foot placements.")
        #expect(result.referenceFinding?.metricKind == .comPathEfficiency)
    }

    @Test("Back and shoulder loading can drive the sequence insight")
    func backAndShoulderInsight() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .latLoadTime, reference: 0.10, attempt: 0.72, confidence: 1),
            MetricDelta(kind: .armLoadShare, reference: 0.24, attempt: 0.82, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(), sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence, fallReport: .none, fallAnalysis: nil
        )

        #expect(result.referenceFinding?.sentence(
            subject: "The reference", causeSubject: "they"
        ) == "The reference relied less on the back and shoulders because they kept more weight off the arms.")
        #expect(result.attemptFinding?.sentence(
            subject: "You", causeSubject: "you"
        ) == "You pulled in with the back and shoulders longer because you put more weight through the arms.")
        #expect(result.referenceFinding?.metricKind == .latLoadTime)
        #expect(result.metrics.prefix(2).map(\.kind) == [.latLoadTime, .armLoadShare])
    }

    @Test("A clear hip-supported insight outranks a larger upper-body-only difference")
    func clearHipInsightHasPriority() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .hipDistanceEnd, reference: 0.18, attempt: 0.38, confidence: 1),
            MetricDelta(kind: .pelvisTurnEnd, reference: 34, attempt: 24, confidence: 1),
            MetricDelta(kind: .latLoadTime, reference: 0.08, attempt: 0.88, confidence: 1),
            MetricDelta(kind: .armLoadShare, reference: 0.18, attempt: 0.82, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(), sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence, fallReport: .none, fallAnalysis: nil
        )

        #expect(result.attemptFinding?.sentence(
            subject: "You", causeSubject: "you"
        ) == "You finished farther from the wall because you finished squarer to the wall.")
        #expect(result.attemptFinding?.metricKind == .hipDistanceEnd)
        #expect(result.metrics.prefix(2).map(\.kind) == [.hipDistanceEnd, .pelvisTurnEnd])
    }

    @Test("A slight hip difference does not suppress a stronger upper-body insight")
    func slightHipInsightDoesNotHavePriority() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .hipDistanceEnd, reference: 0.20, attempt: 0.25, confidence: 1),
            MetricDelta(kind: .pelvisTurnEnd, reference: 30, attempt: 27.5, confidence: 1),
            MetricDelta(kind: .latLoadTime, reference: 0.10, attempt: 0.72, confidence: 1),
            MetricDelta(kind: .armLoadShare, reference: 0.24, attempt: 0.82, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(), sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence, fallReport: .none, fallAnalysis: nil
        )

        #expect(result.attemptFinding?.sentence(
            subject: "You", causeSubject: "you"
        ) == "You pulled in with the back and shoulders longer because you put more weight through the arms.")
        #expect(result.attemptFinding?.metricKind == .latLoadTime)
        #expect(result.metrics.prefix(2).map(\.kind) == [.latLoadTime, .armLoadShare])
    }

    @Test("Hip distance explains back and shoulder loading before arm load does")
    func hipsExplainBackAndShoulderLoading() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .latLoadTime, reference: 0.10, attempt: 0.72, confidence: 1),
            MetricDelta(kind: .hipDistanceMean, reference: 0.18, attempt: 0.58, confidence: 1),
            MetricDelta(kind: .armLoadShare, reference: 0.24, attempt: 0.30, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(), sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence, fallReport: .none, fallAnalysis: nil
        )

        #expect(result.attemptFinding?.sentence(
            subject: "You", causeSubject: "you"
        ) == "You pulled in with the back and shoulders longer because you stayed farther from the wall.")
        #expect(result.attemptFinding?.metricKind == .latLoadTime)
        #expect(result.metrics.prefix(2).map(\.kind) == [.latLoadTime, .hipDistanceMean])
    }

    @Test("Bent loaded arms can drive the sequence insight")
    func bentLoadedArmInsight() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .elbowFlexTime, reference: 0.08, attempt: 0.68, confidence: 1),
            MetricDelta(kind: .armLoadShare, reference: 0.22, attempt: 0.78, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(), sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence, fallReport: .none, fallAnalysis: nil
        )

        #expect(result.referenceFinding?.sentence(
            subject: "The reference", causeSubject: "they"
        ) == "The reference spent less time on bent, loaded arms because they kept more weight off the arms.")
        #expect(result.attemptFinding?.sentence(
            subject: "You", causeSubject: "you"
        ) == "You held bent, loaded arms longer because you put more weight through the arms.")
        #expect(result.referenceFinding?.metricKind == .elbowFlexTime)
        #expect(result.metrics.prefix(2).map(\.kind) == [.elbowFlexTime, .armLoadShare])
    }

    @Test("Unlicensed start and finish differences remain contextual, not unavailable or falsely causal")
    func contextualBodyPositionInsight() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(kind: .torsoLeanStart, reference: 2, attempt: 22, confidence: 1),
            MetricDelta(kind: .torsoLeanEnd, reference: 3, attempt: 28, confidence: 1)
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(), sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence, fallReport: .none, fallAnalysis: nil
        )

        #expect(result.referenceFinding?.isAvailable == true)
        #expect(result.attemptFinding?.isAvailable == true)
        #expect(result.referenceFinding?.relationship == .whileContext)
        #expect(result.attemptFinding?.relationship == .whileContext)
        #expect(result.referenceFinding?.sentence(
            subject: "The reference", causeSubject: "they"
        ).contains(" while ") == true)
        #expect(result.referenceFinding?.text.contains("Causal insight unavailable") == false)
    }

    @Test("Saved findings from before relationship wording still decode as causal")
    func legacyRelationshipDecoding() throws {
        let json = Data("""
        {
          "observation": "Kept more weight off the arms",
          "cause": "Stayed closer to the wall",
          "metricKind": "armLoadShare",
          "confidence": 0.9
        }
        """.utf8)
        let finding = try JSONDecoder().decode(SequenceDifferenceFinding.self, from: json)
        #expect(finding.relationship == .because)
        #expect(finding.sentence(
            subject: "The reference", causeSubject: "they"
        ) == "The reference kept more weight off the arms because they stayed closer to the wall.")
    }

    @Test("Low-confidence differences produce explicit unavailable cards")
    func unavailableDifferences() {
        let wholeSequence = delta(index: 0, metrics: [
            MetricDelta(
                kind: .armLoadShare,
                reference: 0.70,
                attempt: 0.70,
                confidence: 0.1,
                referenceConfidence: 0.1,
                attemptConfidence: 0.1
            )
        ])

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(),
            sectionDeltas: [wholeSequence],
            sequenceDelta: wholeSequence,
            fallReport: .none,
            fallAnalysis: nil
        )

        #expect(result.referenceFinding?.isAvailable == false)
        #expect(result.attemptFinding?.isAvailable == false)
        #expect(result.referenceFinding?.unavailableReason != nil)
        #expect(result.attemptFinding?.unavailableReason != nil)
    }

    @Test("A fall outranks measured technique differences")
    func fallIsMainDifference() {
        let move = delta(index: 0, metrics: [
            MetricDelta(kind: .armLoadShare, reference: 0.25, attempt: 0.80, confidence: 1)
        ])
        let fall = FallReport(
            occurred: true,
            fallSectionIndex: 0,
            confidence: 1,
            proximateSectionIndex: 0
        )
        let analysis = SectionAnalysis(
            sectionIndex: 0,
            headline: "You fell on this move.",
            observations: [],
            drill: nil,
            source: "test"
        )

        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(),
            sectionDeltas: [move],
            fallReport: fall,
            fallAnalysis: analysis
        )

        #expect(result.kind == .fall)
        // The fall still outranks the technique difference — it is the
        // observation on both cards. What changed is that the measured
        // contrast now rides along as context, because "you fell here" on its
        // own is the one thing the climber already knew.
        #expect(result.referenceFinding?.observation == "Stayed on through this sequence")
        #expect(result.attemptFinding?.observation == "Fell during this sequence")
        #expect(result.referenceFinding?.cause == "Kept more weight off the arms")
        #expect(result.attemptFinding?.cause == "Put more weight through the arms")
        // `while`, never `because`. No measurement established that arm load
        // is why this climber came off; the fall analyser found no mechanical
        // signal here at all.
        #expect(result.referenceFinding?.relationship == .whileContext)
        #expect(result.attemptFinding?.relationship == .whileContext)
        #expect(result.referenceFinding?.metricKind == .armLoadShare)
        #expect(result.attemptFinding?.metricKind == .armLoadShare)
    }

    @Test("A mechanical fall signal reaches the card as a cause")
    func mechanicalSignalBecomesTheCause() {
        let move = delta(index: 0, metrics: [
            MetricDelta(kind: .hipDistanceMean, reference: 0.18, attempt: 0.72, confidence: 1)
        ])
        let fall = FallReport(
            occurred: true,
            fallSectionIndex: 0,
            confidence: 1,
            mechanical: [FallSignal(
                kind: .hipPeel,
                status: .mechanical,
                sectionIndex: 0,
                frameIndex: 40,
                detail: "Hips moved away from the wall through the seconds before release.",
                value: 0.5
            )],
            proximateSectionIndex: 0
        )
        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(),
            sectionDeltas: [move],
            fallReport: fall,
            fallAnalysis: SectionAnalysis(
                sectionIndex: 0, headline: "You fell on this move.",
                observations: [], drill: nil, source: "test"
            )
        )

        // Mechanical means demonstrable from the geometry, so it earns
        // `because` — the epistemic split rides on the relationship rather
        // than on hedging words in the copy.
        #expect(result.attemptFinding?.cause == "had been drifting away from the wall")
        #expect(result.attemptFinding?.relationship == .because)
        #expect(result.attemptFinding?.cardSentence(causeSubject: "you")
            == "Came off here because you had been drifting away from the wall.")

        // The reference side is about the metric the signal implicates, so
        // both cards are about the same thing — and stays `while`, because
        // nothing established that their hip position is why they stayed on.
        #expect(result.referenceFinding?.metricKind == .hipDistanceMean)
        #expect(result.referenceFinding?.relationship == .whileContext)
    }

    @Test("A fatigue proxy is context, never a cause")
    func fatigueSignalStaysCorrelational() {
        let move = delta(index: 0, metrics: [
            MetricDelta(kind: .reachMargin, reference: 0.20, attempt: 0.75, confidence: 1)
        ])
        let fall = FallReport(
            occurred: true,
            fallSectionIndex: 0,
            confidence: 1,
            fatigue: [FallSignal(
                kind: .reachMarginDecay,
                status: .fatigueProxy,
                sectionIndex: 0,
                frameIndex: nil,
                detail: "Latch extension grew across the climb.",
                value: 0.3
            )],
            proximateSectionIndex: 0
        )
        let result = SequenceAnalysisComposer().compose(
            sequence: sequence(),
            sectionDeltas: [move],
            fallReport: fall,
            fallAnalysis: SectionAnalysis(
                sectionIndex: 0, headline: "You fell on this move.",
                observations: [], drill: nil, source: "test"
            )
        )

        #expect(result.attemptFinding?.cause == "had been latching each hold from further out")
        // The whole point: a correlational signal may be shown, and may not
        // be called the reason.
        #expect(result.attemptFinding?.relationship == .whileContext)
    }

    @Test("Every fall mechanism reads as a clause the climber is the subject of")
    func fallMechanismsAreVerbPhrases() {
        for kind in [
            FallSignal.Kind.comOutsideBaseOfSupport, .barnDoor, .footSlip, .hipPeel,
            .bentArmAccumulation, .armLoadAccumulation, .sectionDwellRatio,
            .loadAsymmetryTrend, .reachMarginDecay
        ] {
            let mechanism = SequenceAnalysisComposer.fallMechanism(for: kind)
            let finding = SequenceDifferenceFinding(
                observation: "Came off here",
                cause: mechanism,
                metricKind: nil,
                confidence: 1
            )
            // It lands after "because you", so it has to be a verb phrase and
            // must not carry its own subject.
            let sentence = finding.cardSentence(causeSubject: "you")
            #expect(sentence.hasPrefix("Came off here because you "))
            #expect(sentence.hasSuffix("."))
            #expect(NumberGuard.numbers(in: mechanism).isEmpty)
            #expect(SpeculationGuard.violations(in: mechanism).isEmpty)
            #expect(NumberGuard.forbiddenUnitsPresent(in: mechanism).isEmpty)
        }
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
        #expect(result.referenceFinding?.isAvailable == false)
        #expect(result.attemptFinding?.isAvailable == false)
    }
}
