import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, used **only to phrase claims that Swift already
/// decided**.
///
/// The division of labour is the whole design. `FindingComposer` decides what is
/// true, which direction is good, and what to suggest — all in code, from
/// `MetricKind.lowerIsBetter`. The model receives finished claims in plain
/// English and rewrites them so they sound like a person rather than a report.
/// It never sees a raw delta, never picks a polarity, and never sees a figure.
///
/// That split came out of a real failure: given bare labelled numbers, the model
/// wrote "Attempt Lagging Behind Reference" for a move where the attempt was
/// *better*, and "Try: Increase attempt's hip twist by 3.00" as advice. Both are
/// impossible now — it cannot get a direction wrong when it isn't choosing one,
/// and it cannot quote a number when its output is rejected for containing one.
struct FoundationModelsProvider: AnalysisProvider {
    let name = "Foundation Models"
    var config: TuningConfig
    private let fallback: TemplateAnalysisProvider
    private let composer: FindingComposer

    init(config: TuningConfig = TuningConfig()) {
        self.config = config
        self.fallback = TemplateAnalysisProvider(config: config)
        self.composer = FindingComposer(config: config)
    }

    var isAvailable: Bool {
        get async {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return SystemLanguageModel.default.isAvailable
            }
            #endif
            return false
        }
    }

    /// Everything the model is ever shown. Claims, not measurements.
    static func prompt(for delta: SectionDelta, findings: [Finding]) -> String {
        var lines: [String] = []
        lines.append("You are a bouldering coach talking to a climber who has just watched their attempt next to a stronger climber's.")
        lines.append("")
        lines.append("Here is what was measured on move \(delta.sectionIndex + 1). These conclusions are already correct — your job is only to say them well.")
        lines.append("")
        for finding in findings {
            lines.append("- \(finding.text)")
            if let drill = finding.drill { lines.append("  suggested: \(drill)")}
        }
        lines.append("")
        lines.append("""
        Rules:
        - Never write a number, a percentage, or a unit. Not one. The figures are shown separately.
        - Do not reverse, soften or strengthen the conclusions above. If they say the climber did something well, say so.
        - Talk like a person at the wall, not like a report. No headings such as "Move Efficiency" and no phrases like "the attempt" or "the reference" — say "you" and "they".
        - Advice must be something a climber can try. Never "increase X" or "reduce Y".
        - Never guess at how they felt: no fear, confidence, hesitation, commitment or intent. You cannot see that in a video.
        - If nothing is wrong, say that plainly and give no drill.
        """)
        lines.append("")
        lines.append("""
        Examples of the voice:

        claim: "You were holding yourself on with your arms more than they were. Your hips sat further off the wall, so your weight had nowhere to go but onto your hands."
        good: headline "your arms did the work"; observation "You were hanging off your arms here where they were standing on their feet — your hips were out from the wall, so there was nowhere else for your weight to go."; drill "Turn a hip in and let it touch the wall before you reach."

        claim: "You did this move more directly than they did, and with less on your arms."
        good: headline "nothing to fix here"; observation "You went straight to it and kept the weight off your arms. This one was clean."; drill omitted.
        """)
        return lines.joined(separator: "\n")
    }

    func analyze(_ delta: SectionDelta) async throws -> SectionAnalysis {
        // Code decides everything that can be wrong. If there is nothing to
        // say, there is nothing for the model to do.
        let findings = composer.compose(delta)
        let template = try await fallback.analyze(delta)
        guard !findings.isEmpty, delta.divergence == nil, delta.attemptReached else {
            return template
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(
                    to: Self.prompt(for: delta, findings: findings),
                    generating: GeneratedSectionAnalysis.self
                )
                // The model rewrote the claims; the evidence stays code-generated
                // and is zipped back on so nothing loses its measurement.
                let observations = zip(response.content.observations, findings).map { text, finding in
                    AnalysisNote(
                        text: text,
                        evidence: finding.metrics.map(AnalysisNote.evidence(for:)).joined(separator: "\n"),
                        metric: finding.primaryMetric
                    )
                }
                let candidate = SectionAnalysis(
                    sectionIndex: delta.sectionIndex,
                    headline: "\(delta.sectionName): \(response.content.headline)",
                    observations: observations.isEmpty ? template.observations : observations,
                    drill: response.content.drill,
                    source: name
                )
                if let rejected = Self.guardFailure(candidate, delta: delta, findings: findings) {
                    var safe = template
                    safe.warnings.append("On-device model output was discarded: \(rejected). Showing the written analysis instead.")
                    return safe
                }
                return candidate
            } catch {
                var safe = template
                safe.warnings.append("On-device model failed (\(error.localizedDescription)). Showing the written analysis instead.")
                return safe
            }
        }
        #endif
        return template
    }

    // MARK: Sequence narration

    /// The example pairs shown in the headline prompt.
    ///
    /// Kept as data rather than inlined prose because the guard has to reject
    /// them, and a copy of the list that drifted from the prompt would guard
    /// nothing. Measuring on device found the model returning
    /// "Pulled in with arms" / "Pushed through right leg" — the examples,
    /// verbatim — for every sequence with no metric difference to phrase. A
    /// right leg was never measured; that is an invented finding, and it is
    /// short, digit-free and unspeculative, so nothing else catches it.
    static let headlineExamples: [(reference: String, attempt: String)] = [
        ("Pulled in with arms", "Pushed through right leg"),
        ("Hips close to wall", "Hips away from wall"),
        ("Feet set before reaching", "Reached before feet landed")
    ]

    static let bannedHeadlines: Set<String> = Set(
        headlineExamples.flatMap { [$0.reference, $0.attempt] }.map { $0.lowercased() }
    )

    /// Call 1 of the pair. Both climbers in one request, because a model that
    /// writes the two phrases independently writes the same phrase twice —
    /// "Pulled in with arms" above "Pulled in with arms" is a legitimate
    /// reading of a difference in degree and looks exactly like a bug.
    static func headlinePrompt(for request: SequenceNarrationRequest) -> String {
        var lines: [String] = []
        lines.append("Two climbers crossed the same short stretch of a boulder problem. Here is what was measured about each of them. These conclusions are already correct — your job is only to name each one in a few words.")
        lines.append("")
        lines.append("THE OTHER CLIMBER: \(request.referenceSentence)")
        lines.append("THE CLIMBER READING THIS: \(request.attemptSentence)")
        if let fallContext = request.fallContext {
            lines.append("ALSO TRUE: \(fallContext)")
        }
        lines.append("")
        lines.append("""
        Write one phrase for each of them, for a card the size of a business card.

        Rules:
        - Three to five words. Never more than six.
        - No subject. Not "You", not "They", not "The climber" — a badge beside the phrase already says whose it is.
        - No full stop.
        - Never a number, a percentage or a unit.
        - Plain body words a climber who has never read a coaching article would use: arms, hips, feet, weight, wall. No coaching terms and no gym slang — not "flagged", not "barn-doored", not "arm load", not "centre of mass".
        - The two phrases must say which way round the difference went. "More weight on arms" against "Less weight on arms", not the same phrase twice.
        - Never guess at how either of them felt.

        Good pairs, as shapes to copy — never as answers to reuse:
        """)
        for example in headlineExamples {
            lines.append("  \"\(example.reference)\" / \"\(example.attempt)\"")
        }
        return lines.joined(separator: "\n")
    }

    /// Call 2 of the pair, and the reason the two calls are ordered rather
    /// than merged: the headline is the narrative's **brief**. A card reading
    /// "More weight on arms" above a sheet that talks about hips is impossible
    /// when the sheet was asked to expand "More weight on arms".
    static func narrativePrompt(
        for request: SequenceNarrationRequest,
        headlines: (reference: String, attempt: String)
    ) -> String {
        var lines: [String] = []
        lines.append("These two findings have already been written for this move:")
        lines.append("  REFERENCE — \"\(headlines.reference)\"")
        lines.append("  YOU       — \"\(headlines.attempt)\"")
        lines.append("")
        lines.append("They come from these measurements, already interpreted:")
        lines.append("  REFERENCE — \(request.referenceSentence)")
        lines.append("  YOU       — \(request.attemptSentence)")
        if !request.measurements.isEmpty {
            // One block per climber, never one block per measurement.
            //
            // Interleaving them — metric name, then a line for each climber —
            // produced a paragraph that contradicted itself inside four
            // sentences: "They moved more directly. They took a longer
            // movement path." Both phrases belong to that measurement, and
            // with the two climbers listed a line apart the model attributed
            // both to whichever one it was writing about. Split into two
            // lists, there is nothing to mix up.
            lines.append("")
            lines.append("Everything measured across this stretch, already worded.")
            lines.append("")
            lines.append("WHAT THE OTHER CLIMBER DID:")
            for measurement in request.measurements {
                lines.append("  - \(measurement.referencePhrase) — \(measurement.name.lowercased()): \(measurement.meaning)")
            }
            lines.append("")
            lines.append("WHAT THE CLIMBER READING THIS DID:")
            for measurement in request.measurements {
                lines.append("  - \(measurement.attemptPhrase) — \(measurement.name.lowercased()): \(measurement.meaning)")
            }
        }
        lines.append("""
        Write three or four short sentences for each climber, in the words a
        climber who has been bouldering a few months would use. Open with that
        climber's finding, then work in the other things on **their own list** —
        what their body was doing across this stretch, and how those things fit
        together. Join them into a paragraph; do not list them back.

        Every phrase you need is already written above. You are joining them
        up in plain English, not working anything out: everything true about
        this stretch is in those lines, and anything you add is something the
        video did not show.

        Rules:
        - Never write a number, a percentage or a unit. Not one.
        - Add no detail that is not in the lines above. No shapes, no paths, no patterns, no speeds, no body parts, no holds that were not named. If a measurement is not listed, it was not taken.
        - Never say how much of something there was. The figures are shown elsewhere and you have not been given them.
        - Use only the lines under that climber's own heading. Never give one climber something from the other's list, and never say a climber did both sides of the same thing.
        - Keep "because" pointing the same way round. If the line says A happened because of B, never write that B happened because of A.
        - Describe the same difference from both sides. They are two views of one thing, not two unrelated observations.
        - Say "you" for the climber reading this and "they" for the other climber.
        - Do not reverse or soften the findings. If the measurements say the climber did something well, say so.
        - Never say whether it helped, hurt, was safer or was more stable. Those were not measured. Say what each climber's body did and where the weight went, and stop there.
        - Do not end both paragraphs with the same clause. They describe two different climbers.
        - Never guess at how they felt: no fear, confidence, hesitation or intent. That is not in a video.
        """)
        return lines.joined(separator: "\n")
    }

    func narrate(_ request: SequenceNarrationRequest) async throws -> SequenceNarration {
        // The deterministic narration is the floor. Everything below either
        // improves on it or is discarded in favour of it.
        let written = try await fallback.narrate(request)

        // Code decides everything that can be wrong, so the model is only
        // asked where there is a measured difference to phrase. A fall, a
        // different hold order and a sequence the climber matched are already
        // stated exactly right in code, and on device the model given one of
        // them had nothing to work from and returned the prompt's own examples
        // — a finding about a leg nothing had measured.
        //
        // This also keeps D3 intact: a fall's proximate/distal split is
        // written by the fall analyser, not paraphrased by a model.
        guard request.kind == .coaching, request.comparisonIsValid else { return written }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let headlines = try await generateHeadlines(request, fallback: written)
                let narratives = try await generateNarratives(
                    request,
                    headlines: headlines,
                    fallback: written
                )
                return SequenceNarration(
                    referenceHeadline: headlines.reference,
                    attemptHeadline: headlines.attempt,
                    referenceNarrative: narratives.reference,
                    attemptNarrative: narratives.attempt,
                    source: name
                )
            } catch {
                return written
            }
        }
        #endif
        return written
    }

    #if canImport(FoundationModels)
    /// Two token budgets and greedy sampling, for three separate reasons.
    ///
    /// **The ceiling is load-bearing.** A `String` field with no budget can run
    /// away: measuring this on device produced
    /// `exceededContextWindowSize — 4089 tokens of 4096` on a prompt of a few
    /// hundred, because the model kept writing. A phrase of five words and two
    /// short sentences have known sizes, so they get budgets and the failure
    /// stops being possible.
    ///
    /// **Greedy sampling because this text is written once and cached
    /// forever.** There is no reason to sample for variety in a sentence the
    /// climber will reread; the same measurements should produce the same
    /// words, and the guards then have one output to reason about rather than
    /// a distribution.
    @available(iOS 26.0, macOS 26.0, *)
    static var headlineOptions: GenerationOptions {
        GenerationOptions(sampling: .greedy, maximumResponseTokens: 80)
    }

    /// Room for four sentences over four measurements.
    ///
    /// Length was what the model embroidered with when it had only the one
    /// finding to say — asked for a third sentence about a single claim it
    /// invented a zigzag, a sway and a rhythm. Given four already-worded
    /// measurements it has four true things to say instead, which is the
    /// difference between room to expand and room to make something up.
    @available(iOS 26.0, macOS 26.0, *)
    static var narrativeOptions: GenerationOptions {
        GenerationOptions(sampling: .greedy, maximumResponseTokens: 400)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func generateHeadlines(
        _ request: SequenceNarrationRequest,
        fallback written: SequenceNarration
    ) async throws -> (reference: String, attempt: String) {
        let session = LanguageModelSession()
        let response = try await session.respond(
            to: Self.headlinePrompt(for: request),
            generating: GeneratedSequenceHeadlines.self,
            options: Self.headlineOptions
        )
        // Per side, not per pair. One phrase running long is no reason to
        // throw away a good one for the other climber.
        return (
            Self.acceptedHeadline(response.content.referenceHeadline, else: written.referenceHeadline),
            Self.acceptedHeadline(response.content.attemptHeadline, else: written.attemptHeadline)
        )
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func generateNarratives(
        _ request: SequenceNarrationRequest,
        headlines: (reference: String, attempt: String),
        fallback written: SequenceNarration
    ) async throws -> (reference: String, attempt: String) {
        let session = LanguageModelSession()
        let response = try await session.respond(
            to: Self.narrativePrompt(for: request, headlines: headlines),
            generating: GeneratedSequenceNarratives.self,
            options: Self.narrativeOptions
        )
        return (
            Self.acceptedNarrative(
                response.content.referenceNarrative,
                request: request,
                claim: request.referenceSentence,
                isAttempt: false,
                else: written.referenceNarrative
            ),
            Self.acceptedNarrative(
                response.content.attemptNarrative,
                request: request,
                claim: request.attemptSentence,
                isAttempt: true,
                else: written.attemptNarrative
            )
        )
    }
    #endif

    /// Enforces in code what the prompt asked for. A model asked for four
    /// words will sometimes write twelve.
    static func acceptedHeadline(_ candidate: String, else written: String) -> String {
        let tidied = HeadlineGuard.tidied(candidate)
        guard HeadlineGuard.failure(tidied) == nil,
              !bannedHeadlines.contains(tidied.lowercased())
        else { return written }
        return tidied
    }

    static func acceptedNarrative(
        _ candidate: String,
        request: SequenceNarrationRequest,
        claim: String,
        isAttempt: Bool,
        else written: String
    ) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return NarrativeGuard.failure(
            trimmed, request: request, claim: claim, isAttempt: isAttempt
        ) == nil ? trimmed : written
    }

    func analyzeFall(_ report: FallReport, sections: [SectionDelta]) async throws -> SectionAnalysis? {
        // Fall copy stays templated regardless of model availability. The
        // mechanical-fact versus fatigue-hypothesis split is the whole point of
        // that text, and a paraphrase can blur it.
        try await fallback.analyzeFall(report, sections: sections)
    }

    /// Returns a reason when the output must be rejected.
    static func guardFailure(_ analysis: SectionAnalysis, delta: SectionDelta, findings: [Finding]) -> String? {
        let text = analysis.allText
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "it came back empty" }

        // Absolute, not tolerance-based: the figures live in the evidence lines,
        // so any digit in the prose is unsupported by construction.
        let strays = NumberGuard.straySignificantDigits(
            in: text,
            allowingMoveOrdinals: Set(findings.isEmpty ? [] : [delta.sectionIndex + 1])
        )
        if !strays.isEmpty {
            return "it quoted numbers, which belong in the measurement line, not the advice"
        }
        let units = NumberGuard.forbiddenUnitsPresent(in: text)
        if !units.isEmpty { return "it used units this app does not have (\(units.joined(separator: ", ")))" }
        let speculation = SpeculationGuard.violations(in: text)
        if !speculation.isEmpty { return "it speculated about the climber's state of mind (\(speculation.joined(separator: ", ")))" }
        if let primary = findings.first,
           let direction = DirectionGuard.violation(in: text, attemptIsWorse: primary.attemptIsWorse) {
            return direction
        }
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedSectionAnalysis {
    @Guide(description: "A short lower-case phrase naming what happened on this move. No numbers. Example: 'your arms did the work'.")
    var headline: String

    @Guide(description: "Rewrite each claim you were given as one or two sentences a coach would say at the wall. Same meaning, same direction, no numbers.", .count(1...2))
    var observations: [String]

    @Guide(description: "One thing to try next go, in plain words. Omit if the climber did nothing wrong.")
    var drill: String?
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedSequenceHeadlines {
    @Guide(description: "Three to five plain words naming what the other climber did on this stretch. No subject, no number, no full stop. Example: 'Hips close to wall'.")
    var referenceHeadline: String

    @Guide(description: "Three to five plain words naming what the climber reading this did, worded so it contrasts with the other phrase. No subject, no number, no full stop. Example: 'More weight on arms'.")
    var attemptHeadline: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedSequenceNarratives {
    @Guide(description: "Three or four short sentences about the other climber: the REFERENCE finding first, then the other measurements listed for them. Say 'they'. No numbers. Add nothing the lines do not already say.")
    var referenceNarrative: String

    @Guide(description: "Three or four short sentences about the climber reading this: the YOU finding first, then the other measurements listed for them. Say 'you'. No numbers. Add nothing the lines do not already say.")
    var attemptNarrative: String
}
#endif
