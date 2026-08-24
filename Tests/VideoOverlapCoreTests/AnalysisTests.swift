import Testing
import Foundation
@testable import VideoOverlapCore

@Suite("Analysis")
struct AnalysisTests {

    static func delta(_ kind: MetricKind, reference: Double, attempt: Double) -> SectionDelta {
        SectionDelta(
            sectionIndex: 2,
            sectionName: "Move 3",
            deltas: [MetricDelta(kind: kind, reference: reference, attempt: attempt, confidence: 1)],
            divergence: nil,
            attemptReached: true,
            alignmentCost: 0.4
        )
    }

    /// Task 4.2 — every metric has at least one template.
    @Test("Every metric produces a sentence")
    func everyMetricHasATemplate() async throws {
        let provider = TemplateAnalysisProvider()
        for kind in MetricKind.allCases {
            // A difference large enough to clear the significance threshold for
            // this metric's own scale.
            let d = Self.delta(kind, reference: 1.0, attempt: 3.0)
            let analysis = try await provider.analyze(d)
            #expect(!analysis.headline.isEmpty, "\(kind.rawValue) has no headline")
            #expect(!analysis.observations.isEmpty, "\(kind.rawValue) has no observation")
            #expect(analysis.observations.allSatisfy { !$0.text.isEmpty && !$0.evidence.isEmpty })
        }
    }

    @Test("The top two deltas drive the output")
    func topTwoDeltas() async throws {
        let big = MetricDelta(kind: .hipDistanceMean, reference: 0.2, attempt: 0.9, confidence: 1)
        let medium = MetricDelta(kind: .straightArmRatio, reference: 0.8, attempt: 0.2, confidence: 1)
        let tiny = MetricDelta(kind: .hipTwist, reference: 10, attempt: 10.4, confidence: 1)
        let d = SectionDelta(
            sectionIndex: 0, sectionName: "Move 1",
            deltas: [tiny, medium, big], divergence: nil, attemptReached: true, alignmentCost: nil
        )
        let analysis = try await TemplateAnalysisProvider().analyze(d)
        #expect(analysis.observations.count == 2)
        // Ranking is on each metric's own scale, so a 0.6 swing in straight-arm
        // time outranks a 0.7 swing in hip distance.
        #expect(analysis.headline.contains("bent-armed"))
        #expect(analysis.allText.lowercased().contains("arm"))
        #expect(!analysis.allText.contains("body position"), "the tiny delta should not be reported")
    }

    /// Task 1.11 — a different sequence is a finding, not a bogus comparison.
    ///
    /// What is forbidden is the *comparison*: no delta, no reference value, no
    /// "further out than they were". The attempt's own numbers are facts about
    /// one climb and are reported, because a move the climber did differently
    /// is still a move they did, and going silent there was throwing away the
    /// only measurements that survive divergence.
    @Test("Beta divergence reports your own numbers and no comparison")
    func divergenceReported() async throws {
        var d = Self.delta(.hipDistanceMean, reference: 0.2, attempt: 0.9)
        d.divergence = BetaDivergence(kind: .offRouteHold, detail: "You used 1 hold here that the reference climber did not.", positions: [])
        let analysis = try await TemplateAnalysisProvider().analyze(d)
        #expect(analysis.headline.contains("climbed this differently"))
        // The attempt's own value, stated as its own.
        #expect(analysis.allText.contains("0.90"))
        #expect(analysis.observations.contains { $0.evidence.contains("your number only") })
        // The reference's value and the delta must not appear anywhere.
        #expect(!analysis.allText.contains("0.20"))
        #expect(!analysis.allText.contains("0.70"))
        #expect(!analysis.allText.lowercased().contains("than they"))
        #expect(!analysis.allText.lowercased().contains("reference climber spent"))
    }

    @Test("An unreached move says so rather than showing nothing")
    func unreachedMove() async throws {
        var d = Self.delta(.hipDistanceMean, reference: 0.2, attempt: 0.9)
        d.attemptReached = false
        let analysis = try await TemplateAnalysisProvider().analyze(d)
        #expect(analysis.headline.contains("didn't get this far"))
        #expect(!analysis.observations.isEmpty)
    }

    /// Task 4.5 — generated text may contain no number absent from the input.
    @Test("Template output never contains an unsupported number")
    func templateNumbersAreSupported() async throws {
        let provider = TemplateAnalysisProvider()
        for kind in MetricKind.allCases {
            let d = Self.delta(kind, reference: 0.234, attempt: 0.871)
            let analysis = try await provider.analyze(d)
            // Task 6.7 — figures live in `evidence`, never in the prose.
            let strays = NumberGuard.straySignificantDigits(
                in: analysis.allText, allowingMoveOrdinals: [d.sectionIndex + 1]
            )
            #expect(strays.isEmpty, "\(kind.rawValue) put \(strays) in the prose")
            #expect(NumberGuard.forbiddenUnitsPresent(in: analysis.allText).isEmpty, "\(kind.rawValue) used a forbidden unit")
            // …but the evidence must still carry them, or the claim is unauditable.
            #expect(analysis.observations.allSatisfy { !$0.evidence.isEmpty })
        }
    }

    /// Task 4.5 again, from the other side: a deliberately leading output is
    /// caught. This is the case the guard exists for.
    @Test("An invented number is caught")
    func inventedNumberCaught() {
        let d = Self.delta(.hipDistanceMean, reference: 0.2, attempt: 0.5)
        let allowed = NumberGuard.allowedValues(for: d)
        let hallucinated = "Your hips were about 15 cm further from the wall, roughly 8 kg more on your arms."
        let unsupported = NumberGuard.unsupportedNumbers(in: hallucinated, allowed: allowed)
        #expect(!unsupported.isEmpty)
        #expect(!NumberGuard.forbiddenUnitsPresent(in: hallucinated).isEmpty)
    }

    /// Task 4.6 — fall copy states mechanics as fact and fatigue as hypothesis,
    /// and never speculates about the climber's mental state.
    @Test("Fall analysis never speculates about the climber's state of mind")
    func fallCopyIsNotSpeculative() async throws {
        let provider = TemplateAnalysisProvider()
        // Adversarial set: every combination of signals the analyzer can emit.
        let mechanicalKinds: [FallSignal.Kind] = [.comOutsideBaseOfSupport, .barnDoor, .footSlip, .hipPeel]
        let fatigueKinds: [FallSignal.Kind] = [.bentArmAccumulation, .sectionDwellRatio, .loadAsymmetryTrend, .reachMarginDecay]

        for mechanical in mechanicalKinds {
            for fatigueKind in fatigueKinds {
                let report = FallReport(
                    occurred: true, fallFrame: 300, fallSectionIndex: 6, confidence: 0.9,
                    mechanical: [FallSignal(kind: mechanical, status: .mechanical, sectionIndex: 6, frameIndex: 290, detail: "Measured mechanical detail.", value: 0.4)],
                    fatigue: [FallSignal(kind: fatigueKind, status: .fatigueProxy, sectionIndex: 3, frameIndex: nil, detail: "Measured trend; not demonstrated.", value: 0.1)],
                    proximateSectionIndex: 6, distalSectionIndex: 3
                )
                let analysis = try #require(try await provider.analyzeFall(report, sections: []))
                let violations = SpeculationGuard.violations(in: analysis.allText)
                #expect(violations.isEmpty, "\(mechanical)/\(fatigueKind) produced \(violations)")
                // Cross-section attribution must survive into the copy.
                #expect(analysis.allText.contains("move 4"), "distal cause missing from the copy")
            }
        }
    }

    @Test("The speculation guard catches a mental-state claim")
    func speculationGuardCatches() {
        #expect(!SpeculationGuard.violations(in: "You looked hesitant and lost confidence on that move.").isEmpty)
        #expect(SpeculationGuard.violations(in: "Your centre of mass left the base of support.").isEmpty)
    }

    @Test("No fall means no fall analysis")
    func noFallNoAnalysis() async throws {
        let analysis = try await TemplateAnalysisProvider().analyzeFall(.none, sections: [])
        #expect(analysis == nil)
    }
}

/// Task 4.3 — the model's prompt is built from `SectionDelta` and nothing else.
///
/// The prompt builder lives in the app target (it needs `FoundationModels`), so
/// this reproduces its contract against the type it is given: a `SectionDelta`
/// carries no image, no pose and no coordinate, and therefore no code path
/// exists by which one could reach a prompt.
@Suite("Model input")
struct ModelInputTests {

    @Test("SectionDelta carries no image, pose or pixel data")
    func deltaCarriesOnlyNumbers() throws {
        let delta = SectionDelta(
            sectionIndex: 3,
            sectionName: "Move 4",
            deltas: MetricKind.allCases.map {
                MetricDelta(kind: $0, reference: 0.3, attempt: 0.7, confidence: 0.9)
            },
            divergence: BetaDivergence(kind: .offRouteHold, detail: "one stray hold", positions: [Point2D(x: 0.4, y: 0.6)]),
            attemptReached: true,
            alignmentCost: 0.5
        )
        // Encoding it is the exhaustive check: whatever a prompt builder can
        // read is exactly what serialises here.
        let json = try #require(String(data: try JSONEncoder().encode(delta), encoding: .utf8))
        for forbidden in ["pixel", "image", "frame", "joint", "wrist", "ankle", "shoulder", "cgimage", "buffer"] {
            #expect(!json.lowercased().contains(forbidden), "SectionDelta leaks \(forbidden)")
        }
    }

    @Test("Every metric delta is a scalar, so nothing structural can leak")
    func deltasAreScalars() {
        let delta = MetricDelta(kind: .hipDistanceMean, reference: 0.3, attempt: 0.7, confidence: 1)
        #expect(delta.delta == 0.4000000000000001 || abs((delta.delta ?? 0) - 0.4) < 1e-9)
        #expect(delta.reference != nil && delta.attempt != nil)
    }
}

// MARK: - Phase 6

@Suite("Coaching voice")
struct FindingComposerTests {

    static func delta(_ pairs: [(MetricKind, reference: Double, attempt: Double)]) -> SectionDelta {
        SectionDelta(
            sectionIndex: 3,
            sectionName: "Move 4",
            deltas: pairs.map { MetricDelta(kind: $0.0, reference: $0.reference, attempt: $0.attempt, confidence: 1) },
            divergence: nil,
            attemptReached: true,
            alignmentCost: 0.3
        )
    }

    /// Task 6.5 — the rule that produces the sentence this phase was requested
    /// for: arms doing the work *because* the hips are off the wall.
    @Test("Arms-and-hips composes one causal finding, not two readings")
    func armsBecauseHips() {
        let d = Self.delta([
            (.armLoadShare, reference: 0.35, attempt: 0.80),
            (.hipDistanceMean, reference: 0.20, attempt: 0.75)
        ])
        let findings = FindingComposer().compose(d)
        let first = findings.first
        #expect(first != nil)
        #expect(first?.because != nil, "a causal rule must state a cause")
        #expect(first?.metrics.count == 2, "one finding should absorb both metrics")
        #expect(first?.attemptIsWorse == true)
        #expect(first?.text.lowercased().contains("arms") == true)
        #expect(first?.text.lowercased().contains("hips") == true)
        // The two metrics are spoken once, not twice.
        #expect(findings.count == 1)
    }

    @Test("Every causal rule orders the observed outcome before its cause")
    func causalMetricRoles() throws {
        let cases: [(outcome: MetricKind, cause: MetricKind, metrics: [(MetricKind, reference: Double, attempt: Double)])] = [
            (.armLoadShare, .hipDistanceMean, [
                (.armLoadShare, 0.25, 0.80), (.hipDistanceMean, 0.18, 0.70)
            ]),
            (.armLoadShare, .unweightedFootTime, [
                (.armLoadShare, 0.25, 0.80), (.unweightedFootTime, 0.05, 0.70)
            ]),
            (.armLoadShare, .feetSetBeforeReach, [
                (.armLoadShare, 0.25, 0.80), (.feetSetBeforeReach, 0.90, 0.20)
            ]),
            (.sectionDwellRatio, .footCommitmentSeconds, [
                (.sectionDwellRatio, 1.0, 1.70), (.footCommitmentSeconds, 0.10, 1.10)
            ]),
            (.comPathLength, .footPlacementCount, [
                (.comPathLength, 0.8, 1.8), (.footPlacementCount, 1, 5)
            ]),
            (.armLoadShare, .reachMargin, [
                (.armLoadShare, 0.25, 0.80), (.reachMargin, 0.20, 0.80)
            ]),
            (.pullingArmTime, .pelvisTurn, [
                (.pullingArmTime, 0.10, 0.75), (.pelvisTurn, 32, 5)
            ]),
            (.loadAsymmetry, .torsoLean, [
                (.loadAsymmetry, 0.10, 0.70), (.torsoLean, 2, 25)
            ]),
            (.armLoadShare, .pelvisTilt, [
                (.armLoadShare, 0.25, 0.80), (.pelvisTilt, 2, 24)
            ])
        ]

        for item in cases {
            let finding = try #require(FindingComposer().compose(Self.delta(item.metrics)).first)
            #expect(finding.because != nil)
            #expect(finding.observationMetric?.kind == item.outcome)
            #expect(finding.causeMetric?.kind == item.cause)
        }
    }

    @Test("Legacy straight-arm coaching does not claim the skeleton does the work")
    func straightArmTradeoffAvoidsMisleadingCause() {
        let findings = FindingComposer().compose(Self.delta([
            (.armLoadShare, 0.25, 0.80),
            (.straightArmRatio, 0.85, 0.20)
        ]))

        #expect(findings.allSatisfy { !$0.text.lowercased().contains("skeleton") })
    }

    @Test("Feet on but unweighted is its own finding")
    func unweightedFeet() {
        let d = Self.delta([
            (.armLoadShare, reference: 0.35, attempt: 0.85),
            (.unweightedFootTime, reference: 0.05, attempt: 0.70)
        ])
        let findings = FindingComposer().compose(d)
        #expect(findings.first?.text.lowercased().contains("feet") == true)
        #expect(findings.first?.attemptIsWorse == true)
    }

    /// A rule must not fire on one of its metrics alone, or it would be
    /// inventing the causal link instead of measuring it.
    @Test("A causal rule stays silent when only half of it is present")
    func ruleNeedsBothHalves() {
        let d = Self.delta([(.armLoadShare, reference: 0.35, attempt: 0.80)])
        let findings = FindingComposer().compose(d)
        #expect(findings.count == 1)
        #expect(findings.first?.because == nil, "no cause is available from one metric")
    }

    /// Doing well has to be sayable. An app that only ever finds fault is one
    /// people stop reading.
    @Test("A better attempt is reported as better")
    func creditsAGoodMove() {
        let d = Self.delta([
            (.comPathLength, reference: 11.13, attempt: 6.94),
            (.armLoadShare, reference: 0.80, attempt: 0.40)
        ])
        let findings = FindingComposer().compose(d)
        #expect(findings.first?.attemptIsWorse == false)
        #expect(findings.first?.drill == nil, "nothing to fix means no drill")
    }

    /// Task 6.6 — the exact failure that prompted this phase.
    @Test("DirectionGuard catches a backwards conclusion")
    func directionGuard() {
        // The observed model output, on a move where the attempt was better.
        let backwards = "Move Efficiency: Attempt Lagging Behind Reference"
        #expect(DirectionGuard.violation(in: backwards, attemptIsWorse: false) != nil)
        // The same text is fine when the attempt really was worse.
        #expect(DirectionGuard.violation(in: backwards, attemptIsWorse: true) == nil)
        // And crediting a climber who did worse is caught too.
        #expect(DirectionGuard.violation(in: "You were more efficient than them.", attemptIsWorse: true) != nil)
    }

    /// Task 6.6 — figures belong in the evidence line, not the prose.
    @Test("No composed finding puts a figure in its prose")
    func noDigitsInProse() {
        let kinds = MetricKind.allCases
        for kind in kinds {
            let d = Self.delta([(kind, reference: 0.234, attempt: 0.871)])
            for finding in FindingComposer().compose(d) {
                let strays = NumberGuard.straySignificantDigits(in: finding.text, allowingMoveOrdinals: [4])
                #expect(strays.isEmpty, "\(kind.rawValue) leaked \(strays) into the prose")
                if let drill = finding.drill {
                    #expect(NumberGuard.straySignificantDigits(in: drill, allowingMoveOrdinals: [4]).isEmpty)
                }
                // …and the measurement is still there for anyone who wants it.
                #expect(!finding.metrics.map(AnalysisNote.evidence(for:)).joined().isEmpty)
            }
        }
    }

    /// Task 6.3 — bands have to be reachable, or the wording never varies.
    @Test("Magnitude bands are all reachable")
    func magnitudeBands() {
        let config = TuningConfig()
        var seen: Set<Magnitude> = []
        for attempt in [0.235, 0.30, 0.45, 0.95] {
            let d = Self.delta([(.hipDistanceMean, reference: 0.234, attempt: attempt)])
            seen.insert(d.magnitude(of: d.deltas[0], config: config))
        }
        #expect(seen.contains(.negligible))
        #expect(seen.contains(.large))
        #expect(seen.count >= 3, "saw \(seen)")
    }
}
