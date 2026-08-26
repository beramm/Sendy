import Testing
import Foundation
@testable import VideoOverlapCore

/// Iteration 12: the cards carry a headline instead of a sentence, and the
/// Differences sheet carries the prose. `TemplateAnalysisProvider` is what
/// runs here, so all of it is testable without a model.
@Suite("Sequence narration")
struct SequenceNarrationTests {

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

    private func delta(index: Int, metrics: [MetricDelta]) -> SectionDelta {
        SectionDelta(
            sectionIndex: index,
            sectionName: "Move \(index + 1)",
            deltas: metrics,
            divergence: nil,
            attemptReached: true,
            alignmentCost: 0.2
        )
    }

    private func coachingAnalysis() -> SequenceAnalysis {
        SequenceAnalysisComposer().compose(
            sequence: sequence(),
            sectionDeltas: [delta(index: 0, metrics: [
                MetricDelta(kind: .armLoadShare, reference: 0.25, attempt: 0.80, confidence: 1),
                MetricDelta(kind: .hipDistanceMean, reference: 0.18, attempt: 0.70, confidence: 1)
            ])],
            fallReport: .none,
            fallAnalysis: nil
        )
    }

    // MARK: Item 1 — the card is a phrase, not a sentence

    @Test("Every metric has a card phrase that fits a card")
    func headlinesFitTheCard() {
        for kind in MetricKind.allCases {
            let phrases = SequenceAnalysisComposer.headlinePhrases(for: kind)
            for phrase in [phrases.higher, phrases.lower] {
                #expect(
                    HeadlineGuard.failure(phrase) == nil,
                    "\(kind.rawValue) — \(phrase): \(HeadlineGuard.failure(phrase) ?? "")"
                )
            }
            // Two cards showing the same words when the difference is one of
            // degree looks exactly like a bug. Each direction has to say which
            // way round it went.
            #expect(
                phrases.higher != phrases.lower,
                "\(kind.rawValue) words both directions identically"
            )
        }
    }

    @Test("A composed comparison puts a phrase on both cards, one per direction")
    func composerWritesHeadlines() {
        let result = coachingAnalysis()

        let reference = try! #require(result.referenceFinding?.headline)
        let attempt = try! #require(result.attemptFinding?.headline)
        #expect(reference == "Less weight on arms")
        #expect(attempt == "More weight on arms")
        #expect(reference != attempt)
        #expect(HeadlineGuard.failure(reference) == nil)
        #expect(HeadlineGuard.failure(attempt) == nil)
    }

    @Test("Structural and unavailable states get a phrase too, never a blank card")
    func everyStateHasAHeadline() {
        // Unavailable.
        let unavailable = SequenceDifferenceFinding.unavailable("No shared anchors.")
        #expect(unavailable.headline == "Not comparable here")

        // Attempt never reached this sequence.
        let notReached = SequenceAnalysisComposer().compose(
            sequence: ClimbSequence(
                index: 0, fromAnchorID: 1, toAnchorID: 4,
                referenceRange: 0 ..< 60, attemptRange: 0 ..< 0,
                referenceMoves: 0 ..< 2, attemptMoves: 0 ..< 0
            ),
            sectionDeltas: [SectionDelta(
                sectionIndex: 0, sectionName: "Move 1", deltas: [],
                divergence: nil, attemptReached: false, alignmentCost: nil
            )],
            fallReport: .none,
            fallAnalysis: nil
        )
        let phrase = try! #require(notReached.attemptFinding?.headline)
        #expect(HeadlineGuard.failure(phrase) == nil)
        #expect(phrase != notReached.referenceFinding?.headline)
    }

    @Test("A headline is never punctuated as a sentence and never quotes a figure")
    func headlineGuardRejectsWhatThePromptAskedFor() {
        #expect(HeadlineGuard.failure("More weight on arms") == nil)
        #expect(HeadlineGuard.failure("") != nil)
        #expect(HeadlineGuard.failure("More weight on arms.") != nil)
        #expect(HeadlineGuard.failure("About 42% of the weight went onto the arms") != nil)
        #expect(HeadlineGuard.failure("You put more weight on your arms") != nil)
        #expect(HeadlineGuard.failure("The climber put more weight onto both arms") != nil)
        #expect(HeadlineGuard.failure("Weight moved onto the arms through the whole move") != nil)
        #expect(HeadlineGuard.failure("Hips sat 15 cm off the wall") != nil)

        // Tidying strips the punctuation a model adds out of habit; it does
        // not rescue a phrase that is genuinely too long.
        #expect(HeadlineGuard.tidied("  More weight on arms.  ") == "More weight on arms")
        #expect(HeadlineGuard.failure(HeadlineGuard.tidied("More weight on arms.")) == nil)
    }

    @Test("The card carries one sentence, with the cause and without a subject")
    func cardSentenceIsInformativeAndSubjectless() {
        let result = coachingAnalysis()
        let attempt = try! #require(result.attemptFinding)
        let reference = try! #require(result.referenceFinding)

        let you = attempt.cardSentence(causeSubject: "you")
        let them = reference.cardSentence(causeSubject: "they")

        // The cause is the half that makes it informative. A card that says
        // only "More weight on arms" leaves the reason one tap away, which is
        // the reason the phrase was tried and rejected on a phone at a wall.
        #expect(you == "Put more weight through the arms because you stayed farther from the wall.")
        #expect(them == "Kept more weight off the arms because they stayed closer to the wall.")

        // The badge above the card is the subject, so the sentence must not
        // open with one — but the cause clause keeps its own, or it stops
        // being English.
        for sentence in [you, them] {
            #expect(sentence.hasSuffix("."))
            let lead = sentence.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            #expect(!["you", "your", "the", "they", "their"].contains(lead))
        }
    }

    @Test("A finding with no cause still ends up a whole sentence")
    func cardSentenceWithoutACause() {
        let standalone = SequenceDifferenceFinding(
            observation: "Fell during this sequence",
            headline: "Came off here",
            metricKind: nil,
            confidence: 1
        )
        #expect(standalone.cardSentence(causeSubject: "you") == "Fell during this sequence.")

        let unavailable = SequenceDifferenceFinding.unavailable("No shared anchors.")
        #expect(unavailable.cardSentence(causeSubject: "you").hasSuffix("."))
    }

    // MARK: Item 2 — the sheet's prose

    @Test("The written provider narrates every sequence it is given")
    func templateNarratesWithoutAModel() async throws {
        let analysis = coachingAnalysis()
        let request = try #require(SequenceNarrationRequest(analysis: analysis))
        let narration = try await TemplateAnalysisProvider().narrate(request)

        // The written provider is the final text on a device without
        // Foundation Models, so it must be complete on its own.
        #expect(narration.referenceHeadline == analysis.referenceFinding?.headline)
        #expect(narration.attemptHeadline == analysis.attemptFinding?.headline)
        #expect(narration.referenceNarrative.contains("The other climber"))
        #expect(narration.attemptNarrative.contains("You"))
        #expect(narration.source == "Template")

        var narrated = analysis
        narrated.apply(narration)
        #expect(narrated.referenceNarrative == narration.referenceNarrative)
        #expect(narrated.attemptNarrative == narration.attemptNarrative)
        #expect(narrated.narrationSource == "Template")
    }

    @Test("A paragraph may not carry a number the metrics did not produce")
    func narrativeGuardIsAbsolute() throws {
        let request = try #require(SequenceNarrationRequest(analysis: coachingAnalysis()))

        #expect(NarrativeGuard.failure(
            "You hung off your arms here where they stood on their feet.",
            request: request
        ) == nil)
        #expect(NarrativeGuard.failure("", request: request) != nil)
        #expect(NarrativeGuard.failure(
            "About 42% of your weight went onto your arms.",
            request: request
        ) != nil)
        #expect(NarrativeGuard.failure(
            "Your hips sat 15 cm off the wall.",
            request: request
        ) != nil)
        #expect(NarrativeGuard.failure(
            "You looked nervous about committing to the foot.",
            request: request
        ) != nil)
        // Observed on device: the model turned the worse side of a finding
        // into a benefit, under both climbers, in a sentence with no
        // comparative for `DirectionGuard` to catch.
        #expect(NarrativeGuard.failure(
            "You put more weight through your arms, which helped you maintain a stable position on the wall.",
            request: request
        ) != nil)
        #expect(NarrativeGuard.failure(
            "They kept their hips level, which helped them stay secure.",
            request: request
        ) != nil)

        // Also observed on device: an extra body part smuggled into a
        // sentence about the arms. Shoulders were never measured here.
        #expect(NarrativeGuard.failure(
            "You put more weight through your arms and shoulders.",
            request: request
        ) != nil)
        // The anatomy the claim itself names stays allowed, and so does a
        // closely related joint within the same family.
        #expect(NarrativeGuard.failure(
            "You hung off bent elbows here where they kept their hips in.",
            request: request
        ) == nil)

        // The measurement says the attempt did worse here, so prose crediting
        // the climber contradicts it.
        #expect(request.attemptIsWorse == true)
        #expect(NarrativeGuard.failure(
            "You were more efficient through this one than they were.",
            request: request
        ) != nil)
    }

    @Test("A unit is a word, not a run of letters inside one")
    func unitGuardDoesNotEatClimbingWords() {
        // Both were rejected as units before: "lb" inside elbows, "inch"
        // inside pinch. Both words are ordinary in this app's own copy.
        #expect(NumberGuard.forbiddenUnitsPresent(in: "You held it on bent elbows.").isEmpty)
        #expect(NumberGuard.forbiddenUnitsPresent(in: "They matched hands on the pinch.").isEmpty)
        #expect(NumberGuard.forbiddenUnitsPresent(in: "Your hips sat 15 cm off the wall.") == ["cm"])
        #expect(NumberGuard.forbiddenUnitsPresent(in: "About 3 inches of reach.") == ["inch"])
        #expect(NumberGuard.forbiddenUnitsPresent(in: "Around 70 kg through the arms.") == ["kg"])
    }

    @Test("Prose may not reverse which measurement caused which")
    func causalOrderIsPreserved() throws {
        let analysis = coachingAnalysis()
        let request = try #require(SequenceNarrationRequest(analysis: analysis))
        let claim = request.attemptSentence
        #expect(claim == "You put more weight through the arms because you stayed farther from the wall.")

        // The observed device failure. Both clauses survive, in the same
        // order, and "so" turns the arrow round.
        #expect(NarrativeGuard.failure(
            "You put more weight on your arms, so you stayed farther from the wall.",
            request: request,
            claim: claim
        ) != nil)

        // The same meaning said the other way round is fine: `A because B`
        // and `B so A` are the same claim.
        #expect(NarrativeGuard.failure(
            "You stayed farther from the wall, so you put more weight on your arms.",
            request: request,
            claim: claim
        ) == nil)

        // And the straight rewrite is fine.
        #expect(NarrativeGuard.failure(
            "You put more weight on your arms because you stayed farther from the wall.",
            request: request,
            claim: claim
        ) == nil)

        // Prose that makes no causal claim is not this guard's business.
        #expect(NarrativeGuard.failure(
            "You hung off your arms here where they stood on their feet.",
            request: request,
            claim: claim
        ) == nil)
    }

    @Test("A paragraph may not give one climber the other's half of a measurement")
    func crossTalkIsRejected() throws {
        let request = SequenceNarrationRequest(
            sequenceIndex: 0,
            kind: .coaching,
            referenceHeadline: "Shorter way round",
            attemptHeadline: "Longer way round",
            referenceSentence: "The other climber moved more directly because they used fewer foot placements.",
            attemptSentence: "You took a longer movement path because you used more foot placements.",
            measurements: [
                MeasurementBrief(
                    name: MetricKind.comPathLength.displayName,
                    meaning: MetricKind.comPathLength.plainMeaning,
                    referencePhrase: "moved more directly",
                    attemptPhrase: "took a longer movement path"
                )
            ],
            metricKinds: [.comPathLength],
            comparisonIsValid: true
        )

        // Observed on device, with four near-synonymous measurements: both
        // sides of one measurement said about one climber.
        #expect(NarrativeGuard.failure(
            "They moved more directly here. They took a longer movement path than you did.",
            request: request,
            isAttempt: false
        ) != nil)

        // Their own side is fine.
        #expect(NarrativeGuard.failure(
            "They moved more directly here, straight to the hold.",
            request: request,
            isAttempt: false
        ) == nil)

        // And so is the attempt's own side under the attempt's heading.
        #expect(NarrativeGuard.failure(
            "You took a longer movement path across this bit.",
            request: request,
            isAttempt: true
        ) == nil)
    }

    @Test("A paragraph may not say the same sentence twice")
    func repetitionIsRejected() throws {
        let request = try #require(SequenceNarrationRequest(analysis: coachingAnalysis()))
        #expect(NarrativeGuard.failure(
            "You hung off your arms here. You hung off your arms here.",
            request: request
        ) != nil)
        #expect(NarrativeGuard.failure(
            "You hung off your arms here. Your hips were out from the wall.",
            request: request
        ) == nil)
    }

    // MARK: Reopening a saved climb

    @Test("A climb saved before this iteration still opens")
    func oldAnalysesDecodeWithoutHeadlineOrNarrative() throws {
        // Exactly the shape written by the previous version: no `headline`,
        // no `referenceNarrative`, no `attemptNarrative`.
        let json = """
        {
          "sequenceIndex": 2,
          "kind": "coaching",
          "observation": "You put more weight through the arms",
          "cause": "you stayed farther from the wall",
          "metrics": [],
          "additionalMetrics": [],
          "suppressedMetricCount": 0,
          "comparisonIsValid": true,
          "sourceSectionIndices": [3],
          "referenceFinding": {
            "observation": "Kept more weight off the arms",
            "relationship": "because",
            "confidence": 0.9
          },
          "attemptFinding": {
            "observation": "Put more weight through the arms",
            "relationship": "because",
            "confidence": 0.9
          }
        }
        """
        let decoded = try JSONDecoder().decode(SequenceAnalysis.self, from: Data(json.utf8))

        #expect(decoded.referenceFinding?.headline == nil)
        #expect(decoded.attemptFinding?.headline == nil)
        #expect(decoded.referenceNarrative == nil)
        #expect(decoded.attemptNarrative == nil)
        // The card falls back to the sentence it was saved with rather than
        // showing nothing.
        #expect(decoded.referenceFinding?.sentence(subject: "The reference", causeSubject: "they")
            == "The reference kept more weight off the arms.")
    }

    @Test("Generated text survives an encode and decode unchanged")
    func narrationRoundTrips() async throws {
        var analysis = coachingAnalysis()
        let request = try #require(SequenceNarrationRequest(analysis: analysis))
        analysis.apply(try await TemplateAnalysisProvider().narrate(request))

        let data = try JSONEncoder().encode(analysis)
        let restored = try JSONDecoder().decode(SequenceAnalysis.self, from: data)

        #expect(restored.referenceFinding?.headline == analysis.referenceFinding?.headline)
        #expect(restored.attemptFinding?.headline == analysis.attemptFinding?.headline)
        #expect(restored.referenceNarrative == analysis.referenceNarrative)
        #expect(restored.attemptNarrative == analysis.attemptNarrative)
        #expect(restored.narrationSource == "Template")
    }
}
